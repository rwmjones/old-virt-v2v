# Sys::VirtConvert::Converter::Windows
# Copyright (C) 2009-2012 Red Hat Inc.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

package Sys::VirtConvert::Converter::Windows;

use strict;
use warnings;

use File::Spec;
use File::Spec::Win32;
use File::Temp qw(tempdir);
use Encode qw(encode decode);
use IO::String;
use XML::DOM;
use XML::DOM::XPath;

use Sys::Guestfs;
use Win::Hivex;
use Win::Hivex::Regedit qw(reg_import);

use Locale::TextDomain 'virt-v2v';
use Sys::VirtConvert::Util;


=pod

=head1 NAME

Sys::VirtConvert::Converter::Windows - Pre-convert a Windows guest to run on KVM

=head1 SYNOPSIS

 use Sys::VirtConvert::Converter;

 Sys::VirtConvert::Converter->convert($g, $root, $config, $meta, $options);

=head1 DESCRIPTION

Sys::VirtConvert::Converter::Windows does the "pre-conversion" steps
required to get a Windows guest to boot on KVM.  Unlike the associated
L<Sys::VirtConvert::Converter::Linux(3)> module, this doesn't do a full
conversion of Windows.  Instead it just installs the viostor (Windows
virtio block) driver, so that the Windows guest will be able to boot
on the target.  A "RunOnce" script is also added to the VM which does
all the rest of the conversion the first time the Windows VM is booted
on KVM.

=head1 METHODS

=over

=item Sys::VirtConvert::Converter::Windows->can_handle(g, root)

Return 1 if Sys::VirtConvert::Converter::Windows can convert the given guest.

=cut

sub can_handle
{
    my $class = shift;
    my ($g, $root) = @_;

    return ($g->inspect_get_type($root) eq 'windows');
}

=item Sys::VirtConvert::Converter::Windows->convert(g, root, config, meta, options)

(Pre-)convert a Windows guest. Assume that can_handle has previously
returned 1.

=over

=item g

A libguestfs handle to the target.

=item root

The root device of this operating system.

=item config

An initialised Sys::VirtConvert::Config object.

=item meta

Not used by the Windows converter

=item options

Not used by the Windows converter

=back

=cut

sub convert
{
    my $class = shift;

    my ($g, $root, $config, undef, undef) = @_;

    my $tmpdir = tempdir (CLEANUP => 1);

    # Find the Windows system root
    my $windir = $g->inspect_get_windows_systemroot($root);

    # Open the system and software hives
    my ($sys_guest, $sys_local) = _download_hive($g, $windir,
                                                 $tmpdir, 'system');
    my ($soft_guest, $soft_local) = _download_hive($g, $windir,
                                                   $tmpdir, 'software');

    my $h_sys = Win::Hivex->open ($sys_local, write => 1)
        or v2vdie __x('Failed to open {hive} hive: {error}',
                      hive => 'system', error => $!);
    my $h_soft = Win::Hivex->open ($soft_local, write => 1)
        or v2vdie __x('Failed to open {hive} hive: {error}',
                      hive => 'software', error => $!);

    # Get the 'Current' ControlSet. This is normally 001, but not always.
    my $select = $h_sys->node_get_child($h_sys->root(), 'Select');
    my $current_cs = $h_sys->node_get_value($select, 'Current');
    $current_cs = sprintf("ControlSet%03i", $h_sys->value_dword($current_cs));

    # Initialise firstboot
    # N.B. This may fail, and $firstboot will be undef
    my ($firstboot, $firstboot_tmp, $firstboot_dir) =
        _configure_firstboot($g, $root, $config, $tmpdir, $h_sys, $current_cs);

    _configure_rhev_apt($g, $root, $config, $firstboot, $firstboot_dir);
    _unconfigure_xenpv($g, $h_soft, $firstboot);

    _close_firstboot($g, $firstboot, $firstboot_tmp, $firstboot_dir);

    _disable_services($h_sys, $current_cs);

    my ($block, $net) =
        _prepare_virtio_drivers($g, $root, $windir, $config,
                                $h_sys, $h_soft, $current_cs);

    # Commit and upload the modified registry hives
    $h_sys->commit(undef); undef $h_sys;
    $h_soft->commit(undef); undef $h_soft;

    $g->upload($sys_local, $sys_guest);
    $g->upload($soft_local, $soft_guest);

    _fix_ntfs_heads($g, $root);

    # Return guest capabilities.
    my %guestcaps;

    $guestcaps{block} = $block;
    $guestcaps{net}   = $net;
    $guestcaps{arch}  = $g->inspect_get_arch($root);
    $guestcaps{acpi}  = 1; # XXX

    # We want an i686 guest for i[345]86
    $guestcaps{arch} =~ s/^i[345]86/i686/;

    return \%guestcaps;
}

sub _download_hive
{
    my $g = shift;
    my $windir = shift;
    my $tmpdir = shift;
    my $hive = lc(shift);

    my $local = File::Spec->catfile($tmpdir, $hive . '.hive');

    my $guest;
    eval {
        $guest = "$windir/system32/config/$hive";
        $guest = $g->case_sensitive_path ($guest);

        # Retrieve the hive file unless we've already got it
        $g->download ($guest, $local) unless -e $local;
    };
    v2vdie __x('Could not download the {hive} registry from this Windows '.
               'guest. The exact error message was: {errmsg}',
               hive => uc($hive), errmsg => $@)
        if $@;

    return ($guest, $local);
}

# See http://rwmj.wordpress.com/2010/04/30/tip-install-a-device-driver-in-a-windows-vm/
sub _add_viostor_to_registry
{
    my ($g, $root, $h, $current_cs) = @_;

    # Make the changes.
    my $regedits = <<REGEDITS;
; Edits to be made to a Windows guest to have
; it boot from viostor.

[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\Control\\CriticalDeviceDatabase\\pci#ven_1af4&dev_1001&subsys_00000000]
"Service"="viostor"
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"

[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\Control\\CriticalDeviceDatabase\\pci#ven_1af4&dev_1001&subsys_00020000]
"Service"="viostor"
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"

[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\Control\\CriticalDeviceDatabase\\pci#ven_1af4&dev_1001&subsys_00021af4]
"Service"="viostor"
"ClassGUID"="{4D36E97B-E325-11CE-BFC1-08002BE10318}"

[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\Services\\viostor]
"Type"=dword:00000001
"Start"=dword:00000000
"Group"="SCSI miniport"
"ErrorControl"=dword:00000001
"ImagePath"="system32\\\\drivers\\\\viostor.sys"
"Tag"=dword:00000021

[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\Services\\viostor\\Parameters]
"BusType"=dword:00000001

[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\Services\\viostor\\Parameters\\MaxTransferSize]
"ParamDesc"="Maximum Transfer Size"
"type"="enum"
"default"="0"

[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\Services\\viostor\\Parameters\\MaxTransferSize\\enum]
"0"="64  KB"
"1"="128 KB"
"2"="256 KB"

[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\Services\\viostor\\Parameters\\PnpInterface]
"5"=dword:00000001

[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\Services\\viostor\\Enum]
"0"="PCI\\\\VEN_1AF4&DEV_1001&SUBSYS_00021AF4&REV_00\\\\3&13c0b0c5&0&20"
"Count"=dword:00000001
"NextInstance"=dword:00000001
REGEDITS

    my $io;
    my $major_version = $g->inspect_get_major_version($root);
    if ($major_version == 5 || $major_version == 6) {
        $io = IO::String->new ($regedits);
    } else {
        v2vdie __x('Guest is not a supported version of Windows '.
                   '({major}.{minor})',
                   major => $major_version,
                   minor => $g->inspect_get_minor_version($root));
    }

    local *_map = sub {
        if ($_[0] =~ /^HKEY_LOCAL_MACHINE\\SYSTEM(.*)/i) {
            return ($h, $1);
        } else {
            die "can only make updates to the SYSTEM hive (key was: $_[0])\n"
        }
    };

    reg_import ($io, \&_map);
}

# We copy the VirtIO drivers to a directory on the guest and add this directory
# to HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DevicePath so that it will
# be searched automatically when automatically installing drivers.
sub _prepare_virtio_drivers
{
    my ($g, $root, $windir, $config, $h_sys, $h_soft, $current_cs) = @_;

    # Copy the target VirtIO drivers to the guest
    my $driverdir = File::Spec->catdir($g->case_sensitive_path($windir),
                                       'Drivers', 'VirtIO');

    $g->mkdir_p($driverdir);

    # Check for a virtio entry in the config file for this OS
    my $virtio_host;
    eval {
        ($virtio_host) = $config->match_app($g, $root, 'virtio',
                                            $g->inspect_get_arch($root));
    };
    if ($@) {
        my $block = 'ide';
        my $net   = 'rtl8139';

        logmsg WARN, __x('There are no virtio drivers available '.
                         'for this version of Windows. The guest will be '.
                         'configured with a {block} block storage '.
                         'adapter and a {net} network adapter, but no '.
                         'drivers will be installed for them. If the '.
                         '{block} driver is not already installed in '.
                         'the guest, it will fail to boot. If the {net} '.
                         'driver is not already installed in the guest, '.
                         'you must install it manually after '.
                         'conversion.',
                         block => $block, net => $net);
        return ($block, $net);
    }

    # We can't install any drivers if the defined virtio path is missing
    my $virtio_guest = $config->get_transfer_path($virtio_host);
    if (!(defined($virtio_host) && $g->exists($virtio_guest))) {
        my $block = 'ide';
        my $net   = 'rtl8139';

        logmsg WARN, __x('The installation of virtio drivers failed because '.
               'the driver path referenced in the configuration file '.
               '({path}) is required, but missing. The guest will be '.
               'configured with a {block} block storage adapter and a {net} '.
               'network adapter, but no drivers will be installed for them. '.
               'If the {block} driver is not already installed in the guest,'.
               ' it will fail to boot. If the {net} driver is not already '.
               'installed in the guest, you must install it manually after '.
               'conversion.', path => $virtio_host, block => $block,
               net => $net);
        return ($block, $net);
    }

    my ($block, $net);
    my $viostor_guest = File::Spec->catfile($virtio_guest, 'viostor.sys');
    if ($g->exists($viostor_guest)) {
        $block = 'virtio';

        # Copy viostor directly into place as it's a critical boot device
        $g->cp($viostor_guest,
               $g->case_sensitive_path("$windir/system32/drivers"));

        _add_viostor_to_registry($g, $root, $h_sys, $current_cs);
    } else {
        $block = 'ide';
        logmsg WARN, __x('There is no virtio block driver '.
                         'available in the directory specified for '.
                         'this version of Windows. The guest will be '.
                         'configured with a {block} block storage '.
                         'adapter, but no driver will be installed for '.
                         'it. If the {block} driver is not already '.
                         'installed in the guest, it will fail to boot.',
                         block => $block);
    }

    if ($g->exists(File::Spec->catfile($virtio_guest, 'netkvm.inf'))) {
        $net = 'virtio';
    } else {
        $net = 'rtl8139';
        logmsg WARN, __x('There is no virtio net driver '.
                         'available in the directory specified for '.
                         'this version of Windows. The guest will be '.
                         'configured with a {net} network adapter, but '.
                         'no driver will be installed for it. If the '.
                         '{net} driver is not already installed in the '.
                         'guest, you must install it manually after '.
                         'conversion.', net => $net);
    }

    foreach my $file ($g->ls($virtio_guest)) {
        $g->cp(File::Spec->catfile($virtio_guest, $file), $driverdir);
    }

    # Find the node \Microsoft\Windows\CurrentVersion
    my $node = $h_soft->root();
    foreach ('Microsoft', 'Windows', 'CurrentVersion') {
        $node = $h_soft->node_get_child($node, $_);
    }

    # Update DevicePath, but leave everything else as is
    my @new;
    my $append = ';%SystemRoot%\Drivers\VirtIO';
    foreach my $v ($h_soft->node_values($node)) {
        my $key = $h_soft->value_key($v);
        my ($type, $data) = $h_soft->value_value($v);

        # Decode the string from utf16le to perl native
        my $value = decode('UTF-16LE', $data);

        # Append the driver location if it's not there already
        if ($key eq 'DevicePath' && index($value, $append) == -1) {
            # Remove the explicit trailing NULL
            chop($value);

            # Append the new path and a new explicit trailing NULL
            $value .= $append."\0";

            # Re-encode the string back to utf16le
            $data = encode('UTF-16LE', $value);
        }

        push (@new, { key => $key, t => $type, value => $data });
    }
    $h_soft->node_set_values($node, \@new);

    return ($block, $net);
}

# Configure the guest to run a batch file on first boot
sub _configure_firstboot
{
    my ($g, $root, $config, $tmpdir, $h_sys, $current_cs) = @_;

    # Ensure we have rhsrvany
    my ($rhsrvany_host) = $config->match_app($g, $root, 'rhsrvany',
                                             $g->inspect_get_arch($root));
    if (!defined($rhsrvany_host)) {
        logmsg WARN, __x('Unable to configure firstboot service because '.
                         'rhsrvany is not defined in the configuration file');
        return undef;
    }

    my $rhsrvany_guest = $config->get_transfer_path($rhsrvany_host);
    unless (defined($rhsrvany_guest) && $g->exists($rhsrvany_guest)) {
        logmsg WARN, __x('Unable to configure firstboot service because '.
                         '{path} is required, but missing',
                         path => $rhsrvany_host);
        return undef;
    }

    # Create a temporary local file to hold the firstboot batch file
    my $firstboot_tmp = File::Spec->catfile($tmpdir, 'firstboot.bat');
    my $firstboot;
    unless (open($firstboot, '>', $firstboot_tmp)) {
        logmsg WARN, __x('Unable to open local file ({path}) for writing: '.
                         '{error}',
                         path => $firstboot_tmp, error => $!);
        return undef;
    }

    # Initialise the firstboot batch file
    print $firstboot <<'FIRSTBOOT';
@echo off

rem firstboot.bat
rem Copyright (C) 2013 Red Hat Inc.
rem
rem This program is free software; you can redistribute it and/or
rem modify it under the terms of the GNU Lesser General Public
rem License as published by the Free Software Foundation; either
rem version 2 of the License, or (at your option) any later version.
rem
rem This library is distributed in the hope that it will be useful,
rem but WITHOUT ANY WARRANTY; without even the implied warranty of
rem MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
rem Lesser General Public License for more details.
rem
rem You should have received a copy of the GNU Lesser General Public
rem License along with this library; if not, write to the Free Software
rem Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

echo V2V first boot script started > log.txt
FIRSTBOOT

    # Create a directory for firstboot files in the guest
    my $firstboot_dir = ''; # global
    my $firstboot_dir_win = 'C:';
    foreach my $d ('Program Files', 'RedHat', 'V2V Firstboot') {
        $firstboot_dir .= '/'.$d;
        $firstboot_dir_win .= '\\\\'.$d;

        $firstboot_dir = $g->case_sensitive_path($firstboot_dir);
        $g->mkdir_p($firstboot_dir);
    }

    # Copy rhsrvany to guest
    $g->cp($rhsrvany_guest, $firstboot_dir);

    # Add a new rhsrvany service to the system registry to execute firstboot
    my $rhsrvany_win = $firstboot_dir_win.'\\\\rhsrvany.exe';
    my $firstboot_win = $firstboot_dir_win.'\\\\firstboot.bat';

    my $regedits = <<REGEDITS;
[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\services\\v2v-firstboot]
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ImagePath"="$rhsrvany_win -s v2v-firstboot"
"DisplayName"="V2V first boot actions"
"ObjectName"="LocalSystem"

[HKEY_LOCAL_MACHINE\\SYSTEM\\$current_cs\\services\\v2v-firstboot\\Parameters]
"CommandLine"="cmd /c \\"$firstboot_win\\""
"PWD"="$firstboot_dir_win"
REGEDITS

    my $io = IO::String->new ($regedits);

    local *_map = sub {
        if ($_[0] =~ /^HKEY_LOCAL_MACHINE\\SYSTEM(.*)/i) {
            return ($h_sys, $1);
        } else {
            die "can only make updates to the SYSTEM hive (key was: $_[0])\n"
        }
    };

    reg_import ($io, \&_map);

    return ($firstboot, $firstboot_tmp, $firstboot_dir);
}

sub _close_firstboot
{
    my ($g, $firstboot, $firstboot_tmp, $firstboot_dir) = @_;

    return unless defined($firstboot);

    print $firstboot <<'FIRSTBOOT';

echo uninstalling v2v-firstboot service >>log.txt
rhsrvany.exe -s v2v-firstboot uninstall >>log.txt
FIRSTBOOT

    # Write the completed firstboot script into the guest
    if (defined($firstboot)) {
        close($firstboot); undef $firstboot;
        $g->upload($firstboot_tmp, $firstboot_dir.'/firstboot.bat');
    }
}

sub _configure_rhev_apt
{
    my ($g, $root, $config, $firstboot, $firstboot_dir) = @_;

    # Ensure we have rhev-apt
    my ($rhevapt_host) = $config->match_app($g, $root, 'rhev-apt',
                                            $g->inspect_get_arch($root));
    if (!defined($rhevapt_host)) {
        logmsg WARN, __x('Unable to configure rhev-apt service because '.
                         'rhev-apt is not defined in the configuration file');
        return;
    }

    my $rhevapt_guest = $config->get_transfer_path($rhevapt_host);
    unless (defined($rhevapt_guest) && $g->exists($rhevapt_guest)) {
        logmsg WARN, __x('Unable to configure rhev-apt service because '.
                         '{path} is required, but missing',
                         path => $rhevapt_host);
        return;
    }

    # We can't install rhev-apt without firstboot
    # N.B. It may seem more efficient to check this first, but by checking it
    # here the user gets error messages for all missing files in a single
    # conversion
    if (!defined($firstboot)) {
        logmsg WARN, __x('Unable to configure rhev-apt service without '.
                         'firstboot');
        return;
    }

    $g->cp($rhevapt_guest, $firstboot_dir);

    print $firstboot <<'RHEVAPT';

echo installing rhev-apt >>log.txt
"rhev-apt.exe" /S /v /qn >>log.txt

echo starting rhev-apt >>log.txt
net start rhev-apt >>log.txt
RHEVAPT
}

sub _unconfigure_xenpv
{
    my ($g, $h_soft, $firstboot) = @_;

    if (!defined($firstboot)) {
        logmsg WARN, __x('Unable to uninstall Xen PV drivers without '.
                         'firstboot');
        return;
    }

    my @regkey = ('Microsoft', 'Windows', 'CurrentVersion', 'Uninstall',
                  'Red Hat Paravirtualized Xen Drivers for Windows(R)');

    # Find the node \Microsoft\Windows\CurrentVersion\Uninstall
    #               \Red Hat Paravirtualized Xen Drivers for Windows(R)
    my $node = $h_soft->root();
    foreach (@regkey) {
        $node = $h_soft->node_get_child($node, $_);
        return unless defined($node);
    }

    my $uninst;
    foreach my $v ($h_soft->node_values($node)) {
        my $key = $h_soft->value_key($v);

        if ($key eq 'UninstallString') {
            $uninst = $h_soft->value_value($v);
            $uninst = decode('UTF-16LE', $uninst);
            last;
        }
    }

    logmsg WARN, __x("Can't uninstall Xen PV: {regkey} doesn't contain {value}",
                     regkey => '\HKLM\SOFTWARE\\'.join(@regkey, '\\'),
                     value => 'UninstallString');

    # The uninstall program will be uninst.exe. This is a wrapper around
    # _uninst.exe which prompts the user. As we don't want the user to be
    # prompted, we run _uninst.ex explicitly.
    my ($vol, $dir, $file) = File::Spec::Win32->splitpath($uninst);
    $uninst = File::Spec::Win32->catfile($vol, $dir, '_uninst.exe');

    print $firstboot <<XENPV;

echo Uninstalling Xen PV driver >>log.txt
"$uninst" >>log.txt
XENPV
}

sub _disable_services
{
    my $h = shift;
    my $current_cs = shift;

    # Find the node \CurrentControlSet\Services
    my $services = $h->root();
    foreach ($current_cs, 'Services') {
        $services = $h->node_get_child($services, $_);
    }

    # Disable the Processor and Intelppm services
    # http://blogs.msdn.com/b/virtual_pc_guy/archive/2005/10/24/484461.aspx

    # Disable the rhelscsi service
    # https://bugzilla.redhat.com/show_bug.cgi?id=809273

    foreach ('Processor', 'Intelppm', 'rhelscsi') {
        my $node = $h->node_get_child($services, $_);
        next unless defined($node);

        # It seems that disabling these services doesn't always work. Deleting
        # them is more effective. See RHBZ#737600
        $h->node_delete_child($node);
    }
}

# NTFS hardcodes the number of heads on the drive which created it in the
# filesystem header. Modern versions of Windows ignore it, but both Windows XP
# and Windows 2000 require it to be correct in order to boot from the drive. If
# it isn't you get:
#   'A disk read error occurred. Press Ctrl+Alt+Del to restart'
#
# QEMU has some code in block.c:guess_disk_lchs() which on the face of it
# appears to infer the drive geometry from the MBR if it's valid. However, my
# tests have shown that a Windows XP guest hosted on both RHEL 5 and F14
# requires the heads field in NTFS to be the following, based solely on drive
# size:
#
# Range                             Heads
# size < 2114445312                 0x40
# 2114445312 <= size < 4228374780   0x80
# 4228374780 <= size                0xFF
#
# I have not tested drive sizes less than 1G, which require fewer heads, as this
# limitation applies only to the boot device and it is not possible to install
# XP on a drive this size.
#
# The following page has good information on the layout of NTFS in Windows
# XP/2000:
#   http://mirror.href.com/thestarman/asm/mbr/NTFSBR.htm
#
# Technet has this:
#   http://technet.microsoft.com/en-us/library/cc781134(WS.10).aspx#w2k3tr_ntfs_how_dhao
# however, as this is specific to Windows 2003 it lists location 0x1A as unused.
sub _fix_ntfs_heads
{
    my $g = shift;
    my $root = shift;

    # Check that the root device contains NTFS magic
    my $magic = $g->pread_device($root, 8, 3);
    next unless ($magic eq "NTFS    ");

    # Get the size of the disk containing the root partition
    $root =~ /^(.*?)\d+$/ or die "Unexpected partition: $root";
    my $disk = $1;
    my $size = $g->blockdev_getsize64($disk);

    my $heads;
    if ($size < 2114445312) {
        $heads = 0x40;
    } elsif ($size < 4228374780) {
        $heads = 0x80;
    } else {
        $heads = 0xFF;
    }

    # Update NTFS's idea of the number of disk heads. This is an unsigned 16 bit
    # big-endian integer offset 0x1A from the beginning of the partition.
    $g->pwrite_device($root, pack("v", $heads), 0x1A);
}

=back

=head1 COPYRIGHT

Copyright (C) 2009-2012 Red Hat Inc.

=head1 LICENSE

Please see the file COPYING.LIB for the full license.

=head1 SEE ALSO

L<Sys::VirtConvert::Converter(3pm)>,
L<Sys::VirtConvert(3pm)>,
L<virt-v2v(1)>,
L<http://libguestfs.org/>.

=cut

1;
