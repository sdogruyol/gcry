# Crystal stdlib `Process` builds argv with `Pointer.malloc(args.size)` and no
# trailing NULL. POSIX `execve` requires `argv[argc] == NULL`.
#
# Boehm masks this: `GC_malloc(16)` often returns a 32-byte zeroed granule, so
# the word after the last arg is accidentally NULL. gcry size classes are
# exact (16 → 16), so the next word is freelist/other data → EFAULT / Bad address.
#
# Shard-only workaround until Crystal allocates `args.size + 1`.
# See https://github.com/sdogruyol/gcry/issues/14

{% if flag?(:unix) %}
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
