# Sys::VirtV2V::GuestOS::RedHat
# Copyright (C) 2009 Red Hat Inc.
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

package Sys::VirtV2V::GuestOS::RedHat;

use strict;
use warnings;

use Sys::Guestfs::Lib qw(inspect_linux_kernel);

use Carp;
use Locale::TextDomain 'libguestfs';

=pod

=head1 NAME

Sys::VirtV2V::GuestOS::RedHat - Manipulate and query a Red Hat guest

=head1 SYNOPSIS

 use Sys::VirtV2V::GuestOS;

 $guestos = Sys::VirtV2V::GuestOS->instantiate($g, $desc, $files, $deps)

=head1 DESCRIPTION

Sys::VirtV2V::GuestOS::RedHat provides an interface for manipulating and
querying a Red Hat based guest. Specifically it handles any Guest OS which
Sys::Guestfs::Lib has identified as 'linux', which uses rpm as a package format.

=head1 METHODS

See L<Sys::VirtV2V::GuestOS>.

=over

=cut

sub can_handle
{
    my $class = shift;

    my $desc = shift;

    return ($desc->{os} eq 'linux') && ($desc->{package_format} eq 'rpm');
}

sub new
{
    my $class = shift;

    my $self = {};

    # Guest handle
    my $g = $self->{g} = shift;
    carp("new called without guest handle") unless defined($g);

    # Guest description
    $self->{desc} = shift;
    carp("new called without guest description") unless defined($self->{desc});

    # Guest file map
    $self->{files} = shift;
    carp("new called without files description") unless defined($self->{files});

    # Guest dependency map
    $self->{deps} = shift;
    carp("new called without dependencies") unless defined($self->{deps});

    # Guest alias map
    $self->{aliases} = shift;
    carp("new called without aliases") unless defined($self->{aliases});

    bless($self, $class);

    $self->_init_selinux();
    $self->_init_augeas_modprobe();

    return $self;
}

# Attempt to the guest's default SELinux policy
sub _init_selinux
{
    my $self = shift;

    my $g = $self->{g};

    # Only possible if SELinux is enabled in the appliance
    return if(!$g->get_selinux());

    # Assume SELinux isn't in use if load_policy isn't available
    return if(!$g->exists('/usr/sbin/load_policy'));

    # Try just running 'load_policy'. This won't work on older distros.
    eval {
        $g->command(['/usr/sbin/load_policy']);
    };

    # If that didn't work, try running load_policy <policy file>
    if($@) {
        eval {
            my $policy;

            die(__"/etc/selinux/config does not exist")
                unless($g->exists('/etc/selinux/config'));

            # Parse out the SELinux policy in use
            my $selinux_conf = $g->cat('/etc/selinux/config');
            foreach my $line (split(/\n/, $selinux_conf)) {
                if($line =~ /^SELINUXTYPE=(.*)$/) {
                    $policy = $1;
                    last;
                }
            }

            die(__"Didn't find SELINUXTYPE n /etc/syslinux/config")
                unless(defined($policy));

            # Find files in the policy directory called policy.*
            my @paths;
            eval {
                @paths = $g->glob_expand("/etc/selinux/$policy/policy/policy.*");
            };

            die(__x("Unable to find an SELinux policy file matching {path}",
                    path => "/etc/selinux/$policy/policy/policy.*").": $!")
                if($@);

            # Check that the policy ends with a number
            my $success = 0;
            foreach my $path (@paths) {
                if($path =~ /\.\d+$/) {
                    # Try loading it if it looks right 
                    eval {
                        $g->command(['/usr/sbin/load_policy', $path]);
                    };

                    # Stop if it worked
                    unless($@) {
                        $success = 1;
                        last;
                    }
                }
            }

            die(__"Unable to successfully load an SELinux policy")
                unless($success);
        };

        if($@) {
            print STDERR "virt-v2v: ".
                         __"WARNING unable to configure SELinux: "."$!\n";
        }
    }
}

sub _init_augeas_modprobe
{
    my $self = shift;

    my $g = $self->{g};

    # Check how new modules should be configured. Possibilities, in descending
    # order of preference, are:
    #   modprobe.d/
    #   modprobe.conf
    #   modules.conf
    #   conf.modules

    # Note that we're checking in ascending order of preference so that the last
    # discovered method will be chosen

    # Files which the augeas Modprobe lens doesn't look for by default
    my @modprobe_add = ();
    foreach my $file qw(/etc/conf.modules /etc/modules.conf) {
        if($g->exists($file)) {
            push(@modprobe_add, $file);
            $self->{modules} = $file;
        }
    }

    if($g->exists("/etc/modprobe.conf")) {
        $self->{modules} = "modprobe.conf";
    }

    # If the modprobe.d directory exists, create new entries in
    # modprobe.d/virtv2v-added.conf
    if($g->exists("/etc/modprobe.d")) {
        $self->{modules} = "modprobe.d/virtv2v-added.conf";
    }

    die(__"Unable to find any valid modprobe configuration")
        unless(defined($self->{modules}));

    # Initialise augeas
    eval {
        $g->aug_close();
        $g->aug_init("/", 1);

        # Add files which exist, but the augeas Modprobe lens doesn't look for
        # by default
        if(scalar(@modprobe_add) > 0) {
            foreach (@modprobe_add) {
                $g->aug_set("/augeas/load/Modprobe/incl[last()+1]", $_);
            }
        }

        # Remove all includes for the Grub lens, and add only
        # /boot/grub/menu.lst
        foreach my $incl ($g->aug_match("/augeas/load/Grub/incl")) {
            $g->aug_rm($incl);
        }
        $g->aug_set("/augeas/load/Grub/incl[last()+1]", "/boot/grub/menu.lst");

        # Make augeas pick up the new configuration
        $g->aug_load();
    };

    # The augeas calls will die() on any error.
    die($@) if($@);
}

sub enable_kernel_module
{
    my $self = shift;
    my ($device, $module) = @_;

    my $g = $self->{g};

    eval {
        $g->aug_set("/files/".$self->{modules}."/alias[last()+1]", $device);
        $g->aug_set("/files/".$self->{modules}."/alias[last()]/modulename",
                    $module)
    };

    # Propagate augeas errors
    die($@) if($@);
}

sub update_kernel_module
{
    my $self = shift;
    my ($device, $module) = @_;

    # We expect the module to have been discovered during inspection
    my $desc = $self->{desc};
    my $augeas = $desc->{modprobe_aliases}->{$device}->{augeas};

    # Error if the module isn't defined
    die("$augeas isn't defined") unless defined($augeas);

    my $g = $self->{g};
    $augeas = $self->_check_augeas_device($augeas, $device);

    eval {
        $g->aug_set($augeas."/modulename", $module);
        $g->aug_save();
    };

    # Propagate augeas errors
    die($@) if($@);
}

sub disable_kernel_module
{
    my $self = shift;
    my $device = shift;

    # We expect the module to have been discovered during inspection
    my $desc = $self->{desc};
    my $augeas = $desc->{modprobe_aliases}->{$device}->{augeas};

    # Nothing to do if the module isn't defined
    return if(!defined($augeas));

    my $g = $self->{g};

    $augeas = $self->_check_augeas_device($augeas, $device);
    eval {
        $g->aug_rm($augeas);
    };

    # Propagate augeas errors
    die($@) if($@);
}

sub update_display_driver
{
    my $self = shift;
    my $driver = shift;

    my $g = $self->{g};

    # Update the display driver if it exists
    eval {
        foreach my $path
            ($g->aug_match('/files/etc/X11/xorg.conf/Device/Driver'))
        {
            $g->aug_set($path, $driver);
        }

        $g->aug_save();
    };

    # Propagate augeas errors
    die($@) if($@);
}

# We can't rely on the index in the augeas path because it will change if
# something has been inserted or removed before it.
# Look for the alias again in the same file which contained it on the first
# pass.
sub _check_augeas_device
{
    my $self = shift;
    my ($path, $device) = @_;

    my $g = $self->{g};

    $path =~ m{^(.*)/alias(?:\[\d+\])?$}
        or die("Unexpected augeas modprobe alias path: $path");

    my $augeas;
    eval {
        my @aliases = $g->aug_match($1."/alias");

        foreach my $alias (@aliases) {
            if($g->aug_get($alias) eq $device) {
                $augeas = $alias;
                last;
            }
        }
    };

    # Propagate augeas errors
    die($@) if($@);

    return $augeas if(defined($augeas));
    die("Unable to find augeas path similar to $path for $device");
}

sub get_default_kernel
{
    my $self = shift;

    my $g = $self->{g};

    # Get the default kernel from grub if it's set
    my $default;
    eval {
        $default = $g->aug_get('/files/boot/grub/menu.lst/default');
    };

    my $kernel;
    if(defined($default)) {
        # Grub's default is zero-based, but augeas arrays are 1-based.
        $default += 1;

        # Check it's got a kernel entry
        eval {
            $kernel =
                $g->aug_get("/files/boot/grub/menu.lst/title[$default]/kernel");
        };
    }

    # If we didn't find a default, find the first listed kernel
    if(!defined($kernel)) {
        eval {
            my @paths = $g->aug_match('/files/boot/grub/menu.lst/title/kernel');

            $kernel = $g->aug_get($paths[0]) if(@paths > 0);
        };
    }

    # If we got here, grub doesn't contain any kernels. Give up.
    die(__"Unable to find a default kernel") unless(defined($kernel));

    my $desc = $self->{desc};

    # Get the grub filesystem
    my $grub = $desc->{boot}->{grub_fs};

    # Prepend the grub filesystem to the kernel path to get an absolute path
    $kernel = "$grub$kernel" if(defined($grub));

    # Work out it's version number
    my $kernel_desc = inspect_linux_kernel ($g, $kernel, 'rpm');

    return $kernel_desc->{version};
}

sub add_kernel
{
    my $self = shift;

    my ($kernel_pkg, $kernel_arch) = $self->_discover_kernel();

    # Install the kernel's dependencies
    $self->_install_rpms(1, $self->_resolve_deps($kernel_pkg));

    my $filename;
    eval {
        # Get a matching rpm
        $filename = $self->_match_file($kernel_pkg, $kernel_arch);
    };

    # Return undef if we didn't find a kernel
    return undef if($@);

    # Inspect the rpm to work out what kernel version it contains
    my $version;
    my $g = $self->{g};
    foreach my $file ($g->command_lines(["rpm", "-qlp", $filename])) {
        if($file =~ m{^/boot/vmlinuz-(.*)$}) {
            $version = $1;
            last;
        }
    }

    die(__x"{filename} doesn't contain a valid kernel\n",
            filename => $filename) if(!defined($version));

    $self->_install_rpms(0, ($filename));

    # Make augeas reload so it'll find the new kernel
    $g->aug_load();

    return $version;
}

# Inspect the guest description to work out what kernel should be installed.
# Returns ($kernel_pkg, $kernel_arch)
sub _discover_kernel
{
    my $self = shift;

    my $desc = $self->{desc};
    my $boot = $desc->{boot};

    # Check the default first
    my @configs;
    push(@configs, $boot->{default}) if(defined($boot->{default}));

    # Then check the rest. Default will get checked twice. Shouldn't be a
    # problem, though.
    push(@configs, (0..$#{$boot->{configs}}));

    # Get a current bootable kernel, preferrably the default
    my $kernel_pkg;
    my $kernel_arch;

    foreach my $i (@configs) {
        my $config = $boot->{configs}->[$i];

        # Check the entry has a kernel
        my $kernel = $config->{kernel};
        next unless(defined($kernel));

        # Check its architecture is known
        $kernel_arch = $kernel->{arch};
        next unless(defined($kernel_arch));

        # Get the kernel package name
        $kernel_pkg = $kernel->{package};

        # Default to 'kernel' if package name wasn't discovered
        $kernel_pkg = "kernel" if(!defined($kernel_pkg));
    }

    # Default the kernel architecture to the userspace architecture if it wasn't
    # directly detected
    $kernel_arch = $desc->{arch} if(!defined($kernel_arch));

    die(__x("Unable to determine a kernel architecture"))
        unless(defined($kernel_arch));

    # We haven't supported anything other than i686 for the kernel on 32 bit for
    # a very long time.
    $kernel_arch = 'i686' if('i386' eq $kernel_arch);

    return ($kernel_pkg, $kernel_arch);
}

sub remove_kernel
{
    my $self = shift;
    my ($version) = @_;
    carp("remove_kernel called without version argument")
        unless(defined($version));

    my $g = $self->{g};
    eval {
        # Work out which rpm contains the kernel
        my @output =
            $g->command_lines(['rpm', '-qf', "/boot/vmlinuz-$version"]);
        $g->command(['rpm', '-e', $output[0]]);
    };

    die($@) if($@);

    # Make augeas reload so it knows the kernel's gone
    $g->aug_load();
}

sub add_application
{
    my $self = shift;
    my $label = shift;

    my $user_arch = $self->{desc}->{arch};

    # Get the rpm for this label
    my $rpm = $self->_match_file($label, $user_arch);

    # Nothing to do if it's already installed
    return if(_is_installed($rpm));

    my @install = ($rpm);

    # Add the dependencies to the install set
    push(@install, $self->_resolve_deps($label));

    $self->_install_rpms(1, @install);
}

# Return a list of dependencies which must be installed before $label can be
# installed. The list contains paths of rpm files. It does not contain the rpm
# for $label itself. This is so _resolve_deps can be used to install kernel
# dependencies with -U before the kernel itself is installed with -i.
sub _resolve_deps
{
    my $self = shift;

    my ($label, @path) = @_;

    my $user_arch = $self->{desc}->{arch};

    # Check for an alias for $label
    $label = $self->_resolve_alias($label, $user_arch);

    # Check that the dependency path doesn't include the given label. If it
    # does, that's a dependency loop.
    if(grep(/\Q$label\E/, @path) > 0) {
        die(__x("Found dependency loop installing {label}: {path}",
                label => $label, path => join(' ', @path))."\n");
    }
    push(@path, $label);

    my $g = $self->{g};

    my @depfiles = ();

    # Find dependencies for $label
    foreach my $dep ($self->_match_deps($label, $user_arch)) {
        my $rpm = $self->_match_file($dep, $user_arch);

        # Don't add the dependency if it's already installed
        next if($self->_is_installed($rpm));

        # Add the dependency
        push(@depfiles, $rpm);

        # Recursively add dependencies
        push(@depfiles, $self->_resolve_deps($dep, @path));
    }

    return @depfiles;
}

# Return 1 if the requested rpm, or a newer version, is installed
# Return 0 otherwise
sub _is_installed
{
    my $self = shift;
    my ($rpm) = @_;

    my $g = $self->{g};

    # Get NEVRA for the rpm to be installed
    my $nevra = $g->command(['rpm', '-qp', '--qf',
                             '%{NAME} %{EPOCH} %{VERSION} %{RELEASE} %{ARCH}',
                             $rpm]);

    $nevra =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/
        or die("Unexpected return from rpm command: $nevra");
    my ($name, $epoch, $version, $release, $arch) = ($1, $2, $3, $4, $5);

    # Ensure epoch is always numeric
    $epoch = 0 if('(none)' eq $epoch);

    # Search installed rpms matching <name>.<arch>
    my $found = 0;
    foreach my $installed ($g->command_lines(['rpm', '-q', '--qf',
                           '%{EPOCH} %{VERSION} %{RELEASE}', "$name.$arch"])) {
        $installed =~ /^(\S+)\s+(\S+)\s+(\S+)$/
            or die("Unexpected return from rpm command: $installed");
        my ($iepoch, $iversion, $irelease) = ($1, $2, $3);

        # Ensure iepoch is always numeric
        $iepoch = 0 if('(none)' eq $iepoch);

        # Skip if installed epoch less than requested version
        next if($iepoch < $epoch);

        if($iepoch eq $epoch) {
            # Skip if installed version less than requested version
            next if(_rpmvercmp($iversion, $version) < 0);

            # Skip if install version == requested version, but release less
            # than requested release
            if($iversion eq $version) {
                next if(_rpmvercmp($irelease,$release) < 0);
            }
        }
        
        $found = 1;
    }

    return $found;
}

# An implementation of rpmvercmp. Compares two rpm version/release numbers and
# returns -1/0/1 as appropriate.
# Note that this is intended to have the exact same behaviour as the real
# rpmvercmp, not be in any way sane.
sub _rpmvercmp
{
    my ($a, $b) = @_;

    # Simple equality test
    return 0 if($a eq $b);

    my @aparts;
    my @bparts;

    # [t]ransformation
    # [s]tring
    # [l]ist
    foreach my $t ([$a => \@aparts],
                   [$b => \@bparts]) {
        my $s = $t->[0];
        my $l = $t->[1];

        # We split not only on non-alphanumeric characters, but also on the
        # boundary of digits and letters. This corresponds to the behaviour of
        # rpmvercmp because it does 2 types of iteration over a string. The
        # first iteration skips non-alphanumeric characters. The second skips
        # over either digits or letters only, according to the first character
        # of $a.
        @$l = split(/(?<=[[:digit:]])(?=[[:alpha:]]) | # digit<>alpha
                     (?<=[[:alpha:]])(?=[[:digit:]]) | # alpha<>digit
                     [^[:alnum:]]+                # sequence of non-alphanumeric
                    /x, $s);
    }

    # Find the minimun of the number of parts of $a and $b
    my $parts = scalar(@aparts) < scalar(@bparts) ?
                scalar(@aparts) : scalar(@bparts);

    for(my $i = 0; $i < $parts; $i++) {
        my $acmp = $aparts[$i];
        my $bcmp = $bparts[$i];

        # Return 1 if $a is numeric and $b is not
        if($acmp =~ /^[[:digit:]]/) {
            return 1 if($bcmp !~ /^[[:digit:]]/);

            # Drop leading zeroes
            $acmp =~ /^0*(.*)$/;
            $acmp = $1;
            $bcmp =~ /^0*(.*)$/;
            $bcmp = $1;

            # We do a string comparison of 2 numbers later. At this stage, if
            # they're of differing lengths, one is larger.
            return 1 if(length($acmp) > length($bcmp));
            return -1 if(length($bcmp) > length($acmp));
        }

        # Return -1 if $a is letters and $b is not
        else {
            return -1 if($bcmp !~ /^[[:alpha:]]/);
        }

        # Return only if they differ
        return -1 if($acmp lt $bcmp);
        return 1 if($acmp gt $bcmp);
    }

    # We got here because all the parts compared so far have been equal, and one
    # or both have run out of parts.

    # Whichever has the greatest number of parts is the largest
    return -1 if(scalar(@aparts) < scalar(@bparts));
    return 1  if(scalar(@aparts) > scalar(@bparts));

    # We can get here if the 2 strings differ only in non-alphanumeric
    # separators.
    return 0;
}

sub remove_application
{
    my $self = shift;
    my $name = shift;

    my $g = $self->{g};
    eval {
        $g->command(['rpm', '-e', $name]);
    };
    die($@) if($@);
}

# Lookup a guest specific match for the given label
sub _match
{
    my $self = shift;
    my ($object, $label, $arch, $hash) = @_;

    my $desc = $self->{desc};
    my $distro = $desc->{distro};
    my $major = $desc->{major_version};
    my $minor = $desc->{minor_version};

    if(values(%$hash) > 0) {
        # Search for a matching entry in the file map, in descending order of
        # specificity
        for my $name ("$distro.$major.$minor.$arch.$label",
                      "$distro.$major.$minor.$label",
                      "$distro.$major.$arch.$label",
                      "$distro.$major.$label",
                      "$distro.$arch.$label",
                      "$distro.$label") {
            return $name if(defined($hash->{$name}));
        }
    }

    die (__x("No {object} given matching {label}\n",
         object => $object,
         label => "$distro.$major.$minor.$arch.$label"));
}

# Return the path to an rpm for <label>.<arch>
# Dies if no match is found
sub _match_file
{
    my $self = shift;
    my ($label, $arch) = @_;

    # Check for an alias for $label
    $label = $self->_resolve_alias($label, $arch);

    my $files = $self->{files};

    my $name = $self->_match(__"file", $label, $arch, $files);

    # Ensure that whatever file is returned is accessible
    $self->_ensure_transfer_mounted();

    return $self->{transfer_mount}.'/'.$files->{$name};
}

# Look for an alias for this label
sub _resolve_alias
{
    my $self = shift;
    my ($label, $arch) = @_;

    my $aliases = $self->{aliases};

    my $alias;
    eval {
        $alias = $self->_match(__"alias", $label, $arch, $aliases);
    };

    return $aliases->{$alias} if(defined($alias));
    return $label;
}

# Return a list of labels listed as dependencies of the given label.
# Returns an empty list if no dependencies were specified.
sub _match_deps
{
    my $self = shift;
    my ($label, $arch) = @_;

    my $deps = $self->{deps};

    my $name;
    eval {
        $name = $self->_match(__"dependencies", $label, $arch, $deps);
    };

    # Return an empty list if there were no dependencies defined
    if($@) {
        return ();
    } else {
        return split(/\s+/, $deps->{$name});
    }
}

# Install a set of rpms
sub _install_rpms
{
    my $self = shift;

    my ($upgrade, @rpms) = @_;

    # Nothing to do if we got an empty set
    return if(scalar(@rpms) == 0);

    my $g = $self->{g};
    eval {
        $g->command(['rpm', $upgrade == 1 ? '-U' : '-i', @rpms]);
    };

    # Propagate command failure
    die($@) if($@);
}

# Ensure that the transfer device is mounted. If not, mount it.
sub _ensure_transfer_mounted
{
    my $self = shift;

    # Return immediately if it's already mounted
    return if(exists($self->{transfer_mount}));

    my $g = $self->{g};

    # Find the transfer device
    my @devices = $g->list_devices();
    my $transfer = $devices[$#devices];

    $self->{transfer_mount} = $g->mkdtemp("/tmp/transferXXXXXX");
    $g->mount_ro($transfer, $self->{transfer_mount});
}

sub remap_block_devices
{
    my $self = shift;
    my ($map) = @_;

    my $g = $self->{g};

    # Iterate over fstab. Any entries with a spec in the the map, replace them
    # with their mapped values
    eval {
        foreach my $spec ($g->aug_match('/files/etc/fstab/*/spec')) {
            my $device = $g->aug_get($spec);

            next unless($device =~ m{^/dev/((?:sd|hd|xvd)(?:[a-z]+))(\d*)});

            if(defined($map->{$1})) {
                my $target = '/dev/'.$map->{$1};
                $target .= $2 if(defined($2));
                $g->aug_set($spec, $target);
            } else {
                print STDERR __x("No mapping found for block device {device}",
                                 device => $device)."\n";
            }
        }
    };

    # Propagate augeas failure
    die($@) if($@);
}

sub prepare_bootable
{
    my $self = shift;

    my $version = shift;
    my @modules = @_;

    my $g = $self->{g};

    # Find the grub entry for the given kernel
    my $initrd;
    my $found = 0;
    eval {
        foreach my $kernel
                ($g->aug_match('/files/boot/grub/menu.lst/title/kernel')) {

            if($g->aug_get($kernel) eq "/vmlinuz-$version") {
                # Ensure it's the default
                $kernel =~ m{/files/boot/grub/menu.lst/title(?:\[(\d+)\])?/kernel}
                    or die($kernel);

                my $aug_index;
                if(defined($1)) {
                    $aug_index = $1;
                } else {
                    $aug_index = 1;
                }

                $g->aug_set('/files/boot/grub/menu.lst/default',
                            $aug_index - 1);

                # Get the initrd for this kernel
                $initrd = $g->aug_get("/files/boot/grub/menu.lst/title[$aug_index]/initrd");

                $found = 1;
                last;
            }
        }
    };

    # Propagate augeas failure
    die($@) if($@);

    if(!$found) {
        die(__x"Didn't find a grub entry for kernel version {version}",
               version => $version);
    }

    if(!defined($initrd)) {
        print STDERR __x("WARNING: Kernel version {version} doesn't have an ".
                         "initrd entry in grub", version => $version);
    } else {
        # Initrd as returned by grub is relative to /boot
        $initrd = "/boot$initrd";

        # Backup the original initrd
        $g->mv("$initrd", "$initrd.pre-v2v");

        # Create a new initrd which preloads the required kernel modules
        my @preload_args = ();
        foreach my $module (@modules) {
            push(@preload_args, "--preload=$module");
        }

        # mkinitrd reads configuration which we've probably changed
        eval {
            $g->aug_save();
        };

        if($@) {
            foreach my $error ($g->aug_match('/augeas//error/*')) {
                print STDERR "$error: ".$g->aug_get($error)."\n";
            }
            die($@);
        }

        # We explicitly modprobe ext2 here. This is required by mkinitrd on RHEL
        # 3, and shouldn't hurt on other OSs.
        $g->modprobe("ext2");

        $g->command(["/sbin/mkinitrd", @preload_args, $initrd, $version]);
    }

    # Disable kudzu in the guest
    # Kudzu will detect the changed network hardware at boot time and either:
    #   require manual intervention, or
    #   disable the network interface
    # Neither of these behaviours is desirable.
    $g->command(['/sbin/chkconfig', 'kudzu', 'off']);
}

sub supports_virtio
{
    my $self = shift;
    my ($kernel) = @_;

    my %checklist = (
        "virtio_net" => 0,
        "virtio_pci" => 0,
        "virtio_blk" => 0
    );

    my $g = $self->{g};

    # Search the installed kernel's modules for the virtio drivers
    foreach my $module ($g->find("/lib/modules/$kernel")) {
        foreach my $driver (keys(%checklist)) {
            if($module =~ m{/$driver\.(?:o|ko)$}) {
                $checklist{$driver} = 1;
            }
        }
    }

    # Check we've got all the drivers in the checklist
    foreach my $driver (keys(%checklist)) {
        if(!$checklist{$driver}) {
            return 0;
        }
    }

    return 1;
}

sub DESTROY
{
    my $self = shift;

    my $g = $self->{g};

    # Remove the transfer mount point if it was used
    if(defined($self->{transfer_mount})) {
        $g->umount($self->{transfer_mount});
        $g->rmdir($self->{transfer_mount});
    }
}

1;

=head1 COPYRIGHT

Copyright (C) 2009 Red Hat Inc.

=head1 LICENSE

Please see the file COPYING.LIB for the full license.

=head1 SEE ALSO

L<virt-inspector(1)>,
L<Sys::Guestfs(3)>,
L<guestfs(3)>,
L<http://libguestfs.org/>,
L<Sys::Virt(3)>,
L<http://libvirt.org/>,
L<guestfish(1)>.

=cut