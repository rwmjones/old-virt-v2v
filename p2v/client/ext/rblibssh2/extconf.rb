require 'mkmf'

# Allow compiler to be overridden by the environment
RbConfig::MAKEFILE_CONFIG['CC'] = ENV['CC'] if ENV['CC']

extension_name = 'rblibssh2'

raise "libssh2 not found" unless pkg_config('libssh2')

dir_config(extension_name)

rubyio = if have_header('ruby/io.h')
    'ruby/io.h'
elsif have_header('rubyio.h')
    'rubyio.h'
else
    abort "Didn't find either ruby/io.h or rubyio.h"
end

if have_struct_member('struct rb_io_t', 'f', ['ruby.h', rubyio]) then
    $defs << '-DHAVE_STRUCT_RB_IO_T_F'
elsif have_struct_member('struct rb_io_t', 'fd', ['ruby.h', rubyio])
    $defs << '-DHAVE_STRUCT_RB_IO_T_FD'
else
    abort "Didn't find either f or fd in struct rb_io_t"
end

have_func('rb_thread_fd_select', 'ruby.h')

with_cflags("-Wall -Werror -g -O2") do
    create_makefile(extension_name)
end
