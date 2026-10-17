# Crystal stdlib `Process` builds argv with `Pointer.malloc(args.size)` and no
# trailing NULL. POSIX `execve` requires `argv[argc] == NULL`.
#
# Boehm masks this: `GC_malloc(16)` often returns a 32-byte zeroed granule, so
# the word after the last arg is accidentally NULL. gcry size classes are
# exact (16 → 16), so the next word is freelist/other data → EFAULT / Bad address.
#
# Shard-only workaround for compilers before 1.22.0, which allocates
# `args.size + 1` itself (crystal-lang/crystal#17184). There the reopen would
# only replace the fixed stdlib method with a copy of it, and keep shadowing
# whatever the stdlib does to it next, so it is left out. A nightly reports
# `1.23.0-dev` and so counts as fixed; a `1.22.0-dev` nightly from before the
# fix keeps the reopen. `process_spec/regression/73_execve_argv_terminator_spec.cr`
# checks the terminator slot on either side of the line.
# See https://github.com/sdogruyol/gcry/issues/14

{% if flag?(:unix) && compare_versions(Crystal::VERSION, "1.22.0") < 0 %}
  struct Crystal::System::Process
    def self.prepare_args(args : Enumerable(String)) : {String, LibC::Char**}
      pathname = args.first
      argv = Pointer(Pointer(UInt8)).malloc(args.size + 1)
      args.each_with_index do |arg, i|
        argv[i] = arg.check_no_null_byte.to_unsafe
      end
      {pathname, argv}
    end
  end
{% end %}
