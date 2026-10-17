# PROBE (attribution only): names Crystal's fiber stacks in /proc/<pid>/smaps
# so the sampler can tell them from pthread stacks. Required by the probe build
# of bench/kemal/src/server.cr, never by gcry.
lib LibVmaProbe
  fun prctl(option : Int32, arg2 : UInt64, arg3 : UInt64, arg4 : UInt64, arg5 : UInt64) : Int32
end

module Crystal::System::Fiber
  def self.allocate_stack(stack_size, protect) : Void*
    flags = LibC::MAP_PRIVATE | LibC::MAP_ANON
    pointer = LibC.mmap(nil, stack_size, LibC::PROT_READ | LibC::PROT_WRITE, flags, -1, 0)
    raise RuntimeError.from_errno("Cannot allocate new fiber stack") if pointer == LibC::MAP_FAILED
    LibC.madvise(pointer, stack_size, LibC::MADV_NOHUGEPAGE)
    LibC.mprotect(pointer, 4096, LibC::PROT_NONE) if protect
    LibVmaProbe.prctl(0x53564d41, 0_u64, pointer.address, stack_size.to_u64, "fiber-stack".to_unsafe.address)
    pointer
  end
end
