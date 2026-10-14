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

{% if flag?(:linux) %}
  lib LibC
    fun mincore(addr : Void*, length : SizeT, vec : UInt8*) : Int
  end
{% end %}

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

  # Address space for *extent* bytes, the first *commit* of them readable and
  # writable as `os_map` would leave them and the rest reserved: no access, no
  # page and no charge against the commit limit until `os_commit` makes it
  # usable, so a large block can grow where it stands (`Heap#grow_large`).
  # Only *commit* counts as mapped. Null or `MAP_FAILED` on failure, with
  # nothing kept.
  #
  # POSIX reserves with `PROT_NONE` and without `MAP_NORESERVE`: Linux
  # charges a private mapping against the commit limit only while it is
  # writable, so the reserve is free as it is, and each `os_commit` is
  # charged when it is made, where a refusal (`vm.overcommit_memory=2`)
  # fails the `mprotect` and the growth copies instead. `MAP_NORESERVE`
  # would add nothing, and under the default heuristic it would leave the
  # committed pages out of the count (`Committed_AS`). Windows reserves with
  # `MEM_RESERVE` and commits with `MEM_COMMIT`.
  def self.os_reserve(extent : UInt64, commit : UInt64) : Void*
    ptr = os_reserve_pages(extent, commit)
    unless ptr.null?
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Add, pointerof(@@os_mapped_bytes), commit,
        LLVM::AtomicOrdering::Monotonic, false)
    end
    ptr
  end

  # `os_reserve` without the count; null on failure.
  private def self.os_reserve_pages(extent : UInt64, commit : UInt64) : Void*
    {% if flag?(:win32) %}
      # 0x01 is `PAGE_NOACCESS`, which Crystal's bindings do not name.
      ptr = LibC.VirtualAlloc(Pointer(Void).null, LibC::SizeT.new(extent), LibC::MEM_RESERVE, 0x01_u32)
      return ptr if ptr.null?
      return ptr unless LibC.VirtualAlloc(ptr, LibC::SizeT.new(commit), LibC::MEM_COMMIT, LibC::PAGE_READWRITE).null?
      LibC.VirtualFree(ptr, LibC::SizeT.new(0), LibC::MEM_RELEASE)
      Pointer(Void).null
    {% else %}
      ptr = Gcry::OS.mmap(Pointer(Void).null, LibC::SizeT.new(extent), Gcry::OS::PROT_NONE,
        Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, 0)
      return Pointer(Void).null if mmap_failed?(ptr)
      return ptr if Gcry::OS.mprotect(ptr, LibC::SizeT.new(commit), Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE) == 0
      Gcry::OS.munmap(ptr, LibC::SizeT.new(extent))
      Pointer(Void).null
    {% end %}
  end

  # Makes `[ptr, ptr + bytes)`, reserved by `os_reserve` and not yet
  # committed, readable and writable; it reads zeroes, as a fresh mapping
  # does. False, and nothing changed, when the system refuses.
  def self.os_commit(ptr : Void*, bytes : UInt64) : Bool
    {% if flag?(:win32) %}
      return false if LibC.VirtualAlloc(ptr, LibC::SizeT.new(bytes), LibC::MEM_COMMIT, LibC::PAGE_READWRITE).null?
    {% else %}
      return false unless Gcry::OS.mprotect(ptr, LibC::SizeT.new(bytes), Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE) == 0
    {% end %}
    Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Add, pointerof(@@os_mapped_bytes), bytes,
      LLVM::AtomicOrdering::Monotonic, false)
    true
  end

  # Gives back `[ptr, ptr + bytes)`, the uncommitted end of an `os_reserve`
  # reservation, leaving its front mapped. False on Windows, which releases a
  # reservation only whole: there the end goes when `os_unmap` releases the
  # base.
  def self.os_release_reserved(ptr : Void*, bytes : UInt64) : Bool
    {% if flag?(:win32) %}
      false
    {% else %}
      Gcry::OS.munmap(ptr, LibC::SizeT.new(bytes)) == 0
    {% end %}
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

    # Pages `os_written_prefix` asks `mincore` about per call: a byte each, on
    # the stack, 4 MiB of a 4 KiB-page mapping.
    WRITTEN_PREFIX_BATCH = 1024

    # How many leading bytes of `[base, base + len)`, a page-aligned private
    # anonymous range, may hold anything but zeroes once this returns: the
    # range up to the end of its last resident page. Past that the range is
    # made to read zeroes, so a caller that must hand it out zeroed clears
    # only the prefix. A large block the program touched one byte of, or
    # never wrote past its first megabyte, keeps its untouched pages the
    # kernel's: clearing them faulted each one in to write zeroes over zeroes
    # (`Heap#large_written_bytes`). `len` when it cannot tell.
    #
    # `mincore` alone would be wrong: it answers "resident", and a written
    # page swapped out reads as absent once it leaves the swap cache (the trap
    # `Platform.stack_low_water` avoids with pagemap). So the tail it calls
    # absent goes through `MADV_DONTNEED`, which drops a swap entry as it
    # drops a page and costs a page-table walk where nothing is there. A page
    # that faults in between the two calls is one nobody may write: the range
    # is the caller's, off every list, under the allocation lock.
    def self.os_written_prefix(base : Void*, len : UInt64) : UInt64
      page = Platform.host_page_size
      vec = uninitialized StaticArray(UInt8, WRITTEN_PREFIX_BATCH)
      hi = len // page
      prefix = 0_u64
      while hi > 0 && prefix == 0_u64
        lo = hi > WRITTEN_PREFIX_BATCH ? hi &- WRITTEN_PREFIX_BATCH : 0_u64
        n = hi &- lo
        return len unless LibC.mincore(base + lo &* page, LibC::SizeT.new(n &* page), vec.to_unsafe) == 0
        i = n
        while i > 0
          i &-= 1
          if (vec[i] & 1_u8) != 0
            prefix = (lo &+ i &+ 1) &* page
            break
          end
        end
        hi = lo
      end
      return prefix if prefix >= len
      return len unless Platform.release_physical_pages(base.address &+ prefix, len &- prefix)
      prefix
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
