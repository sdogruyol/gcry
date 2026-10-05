# Every mapping gcry takes from the OS, and the running total of what is still
# mapped.
#
# `GC.prof_stats.obtained_from_os_bytes` used to be `heap_size +
# unmapped_bytes`, and `unmapped_bytes` is a *cumulative* count of releases, so
# the sum only ever grew: a program that mapped 8 MiB for one large object,
# freed it and had the chunk unmapped still reported the 8 MiB as obtained,
# forever. It also left out everything that is not a heap chunk — the mark
# stack, the radix table, the bitmap pools, the parallel-mark push buffers, the
# out-of-memory reserve's unused tail. The total here is the bytes those calls
# currently hold, exactly, because every `mmap` and `munmap` gcry issues goes
# through these two functions and nothing else adds to or takes from it.
#
# Not counted, deliberately: collector side tables taken from libc `malloc`
# (finalizer entries, chunk index, layout tables). Those are libc's mappings,
# not gcry's, and libc decides when they go back.
#
# Process-wide rather than per heap: the field is a process statistic in Boehm
# (`GC_our_mem_bytes`), and a library heap's mappings are the process's too.
require "./platform/os"

module Gcry
  # A literal, so it is initialised statically: the first `os_map` runs inside
  # `GC.init`, before `once`-guarded initialisers can run (see `mmap_failed?`).
  @@os_mapped_bytes = 0_u64

  # Bytes gcry currently holds mapped from the OS.
  def self.os_mapped_bytes : UInt64
    Atomic::Ops.load(pointerof(@@os_mapped_bytes), LLVM::AtomicOrdering::Monotonic, false)
  end

  # Anonymous private read/write mapping of *bytes*; null or `MAP_FAILED` on
  # failure, exactly as `mmap` answers (check with `mmap_failed?`).
  def self.os_map(bytes : UInt64) : Void*
    ptr = Gcry::OS.mmap(Pointer(Void).null, LibC::SizeT.new(bytes),
      Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE,
      Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, 0)
    unless mmap_failed?(ptr)
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Add, pointerof(@@os_mapped_bytes), bytes,
        LLVM::AtomicOrdering::Monotonic, false)
    end
    ptr
  end

  {% if flag?(:linux) %}
    # Moves the pages of `[src, src + len)` onto `dst`, a mapping of *dst_len*
    # (`>= len`) bytes `os_map` returned, by page table: nothing is copied or
    # faulted, `dst` past `len` reads zeroes, and `src` is unmapped. Returns
    # `{moved, dst_kept}`. Refused, `src` is as it was; the call unmaps `dst`
    # before it validates the source, so `dst` is mapped again where it was
    # if nothing else took the hole (`dst_kept`, a fresh mapping still
    # counted), else left to whoever did and no longer counted.
    def self.os_move(src : Void*, len : UInt64, dst : Void*, dst_len : UInt64) : {Bool, Bool}
      moved = LibC.mremap(src, LibC::SizeT.new(len), LibC::SizeT.new(dst_len),
        Platform::MREMAP_MAYMOVE | Platform::MREMAP_FIXED, dst)
      if moved == dst
        Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Sub, pointerof(@@os_mapped_bytes), len,
          LLVM::AtomicOrdering::Monotonic, false)
        return {true, true}
      end
      back = Gcry::OS.mmap(dst, LibC::SizeT.new(dst_len), Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE,
        Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS | Platform::MAP_FIXED_NOREPLACE, -1, 0)
      return {false, true} if back == dst || (mmap_failed?(back) && Errno.value == Errno::EEXIST)
      # A kernel before 4.17 ignores the flag and may map elsewhere.
      Gcry::OS.munmap(back, LibC::SizeT.new(dst_len)) unless mmap_failed?(back)
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Sub, pointerof(@@os_mapped_bytes), dst_len,
        LLVM::AtomicOrdering::Monotonic, false)
      {false, false}
    end
  {% end %}

  # Gives back `[ptr, ptr + bytes)`. A failed `munmap` leaves the range mapped,
  # so it leaves the total alone too.
  def self.os_unmap(ptr : Void*, bytes : UInt64) : Nil
    return unless Gcry::OS.munmap(ptr, LibC::SizeT.new(bytes)) == 0
    Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Sub, pointerof(@@os_mapped_bytes), bytes,
      LLVM::AtomicOrdering::Monotonic, false)
  end
end
