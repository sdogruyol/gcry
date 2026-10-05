require "c/fcntl"
require "c/unistd"

lib LibC
  # Variadic as in glibc: the destination is read only with `MREMAP_FIXED`.
  fun mremap(old_address : Void*, old_size : SizeT, new_size : SizeT, flags : Int, ...) : Void*
end

module Gcry
  # Linux soft-dirty page tracking for nursery old→young edges without
  # compiler write barriers. See `/proc/pid/clear_refs` (4) and pagemap bit 55.
  module Platform
    # Asked, not assumed. This indexes `/proc/self/pagemap` — `(addr //
    # PAGE_SIZE) * 8` is a virtual page number, so on a host whose pages are not
    # 4 KiB it reads entries belonging to some other address entirely. That was
    # fail-safe rather than unsound, because `soft_dirty_tracks_writes?` writes a
    # page and requires the bit back, so a wrong stride makes the probe fail and
    # the backend is never selected — but it fails silently, and the Darwin side
    # of this module has always called `sysconf`. Linux x86_64 and Ubuntu arm64
    # both return 4096, so this changes nothing on either.
    PAGE_SIZE = begin
      sz = LibC.sysconf(LibC::SC_PAGESIZE)
      sz > 0 ? sz.to_u64 : 4096_u64
    end
    PAGEMAP_SOFT_DIRTY = 1_u64 << 55
    PAGEMAP_BATCH      = 64

    # Clear soft-dirty bits for the whole address space. Allocation-free.
    # Returns false if `/proc/self/clear_refs` is unavailable.
    def self.clear_soft_dirty : Bool
      {% if flag?(:linux) %}
        fd = LibC.open("/proc/self/clear_refs", LibC::O_WRONLY)
        return false if fd < 0
        n = LibC.write(fd, "4".to_unsafe, LibC::SizeT.new(1))
        LibC.close(fd)
        n == 1
      {% else %}
        false
      {% end %}
    end

    # Yield start address of each soft-dirty page in [low, high).
    # Returns false if pagemap cannot be read (caller should full-scan).
    # Allocation-free; uses a stack buffer for pagemap batches.
    def self.each_dirty_page(low : UInt64, high : UInt64, & : UInt64 ->) : Bool
      walk_pagemap(low, high) do |addr, entry|
        yield addr if (entry & PAGEMAP_SOFT_DIRTY) != 0
      end
    end

    # Count soft-dirty pages in [low, high). Returns {dirty, total} or nil on error.
    def self.count_soft_dirty_pages(low : UInt64, high : UInt64) : {UInt64, UInt64}?
      dirty = 0_u64
      total = 0_u64
      ok = walk_pagemap(low, high) do |_addr, entry|
        total += 1
        dirty += 1 if (entry & PAGEMAP_SOFT_DIRTY) != 0
      end
      ok ? {dirty, total} : nil
    end

    # Soft-dirty helpers are only meaningful on Linux; keep a shared predicate.
    def self.soft_dirty_supported? : Bool
      {% if flag?(:linux) %}
        fd = LibC.open("/proc/self/clear_refs", LibC::O_WRONLY)
        return false if fd < 0
        LibC.close(fd)
        fd = LibC.open("/proc/self/pagemap", LibC::O_RDONLY)
        return false if fd < 0
        LibC.close(fd)
        true
      {% else %}
        false
      {% end %}
    end

    # Shared pagemap walk. Yields (page_addr, pagemap_entry). Returns false on I/O error.
    private def self.walk_pagemap(low : UInt64, high : UInt64, & : UInt64, UInt64 ->) : Bool
      {% if flag?(:linux) %}
        return true if high <= low

        fd = LibC.open("/proc/self/pagemap", LibC::O_RDONLY)
        return false if fd < 0

        begin
          page_low = low & ~(PAGE_SIZE - 1)
          page_high = (high + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)

          buf = uninitialized StaticArray(UInt64, PAGEMAP_BATCH)
          addr = page_low
          while addr < page_high
            remaining = (page_high - addr) // PAGE_SIZE
            count = remaining < PAGEMAP_BATCH ? remaining.to_i32 : PAGEMAP_BATCH
            offset = LibC::OffT.new((addr // PAGE_SIZE) * 8)
            if LibC.lseek(fd, offset, 0) < 0
              return false
            end
            want = LibC::SizeT.new(count * 8)
            got = LibC.read(fd, buf.to_unsafe.as(Void*), want)
            return false if got < 0
            return false if got.to_u64 != want.to_u64

            i = 0
            while i < count
              yield addr + i.to_u64 * PAGE_SIZE, buf.to_unsafe[i]
              i += 1
            end
            addr += count.to_u64 * PAGE_SIZE
          end
          true
        ensure
          LibC.close(fd)
        end
      {% else %}
        false
      {% end %}
    end

    # madvise advice constants (Linux <asm/mman.h>).
    MADV_HUGEPAGE   = 14
    MADV_NOHUGEPAGE = 15
    MADV_FREE       =  8
    MADV_COLD       = 20
    # Linux 5.14+: fault the range in, writable, in one call.
    MADV_POPULATE_WRITE = 23

    # Drop physical pages while keeping the VMA (MADV_DONTNEED on Linux).
    def self.host_page_size : UInt64
      PAGE_SIZE
    end

    def self.release_physical_pages(addr : UInt64, len : UInt64) : Bool
      {% if flag?(:linux) %}
        return false if len == 0
        return false if (addr & (PAGE_SIZE - 1)) != 0
        return false if (len & (PAGE_SIZE - 1)) != 0
        ThreadListWatch.check(addr, len, ThreadListWatch::SITE_DONTNEED)
        LibC.madvise(Pointer(Void).new(addr), LibC::SizeT.new(len), LibC::MADV_DONTNEED) == 0
      {% else %}
        false
      {% end %}
    end

    # The Darwin pair (`MADV_FREE_REUSABLE` / `MADV_FREE_REUSE`) needs its
    # reuse announced; here the release is `MADV_DONTNEED` and the next touch
    # simply faults a zero page in.
    def self.release_reusable_pages(addr : UInt64, len : UInt64) : Bool
      release_physical_pages(addr, len)
    end

    def self.reuse_released_pages(addr : UInt64, len : UInt64) : Nil
    end

    # Lightweight hint: mark pages as cold so the kernel reclaims them first
    # under memory pressure, but keep content valid.  Cheaper than DONTNEED for
    # dormant chunks that may be revived soon — no page-zeroing on revive.
    # Unlike MADV_DONTNEED, MADV_COLD does not clear pages, so the first access
    # after revive hits a minor fault (not major + zero-fill).
    def self.release_physical_pages_cold(addr : UInt64, len : UInt64) : Bool
      {% if flag?(:linux) %}
        return false if len == 0
        return false if (addr & (PAGE_SIZE - 1)) != 0
        return false if (len & (PAGE_SIZE - 1)) != 0
        ThreadListWatch.check(addr, len, ThreadListWatch::SITE_MADV_COLD)
        LibC.madvise(Pointer(Void).new(addr), LibC::SizeT.new(len), MADV_COLD) == 0
      {% else %}
        false
      {% end %}
    end

    # MADV_FREE: hint that pages contain freeable data.  Kernel may defer
    # reclaiming them until memory pressure rises; page content is preserved
    # until reclaimed.  Caller must not rely on content staying valid.
    # Suitable for large freelist pages that are cached for reuse but whose
    # physical pages can be returned to the system under pressure.
    def self.release_physical_pages_free(addr : UInt64, len : UInt64) : Bool
      {% if flag?(:linux) %}
        return false if len == 0
        return false if (addr & (PAGE_SIZE - 1)) != 0
        return false if (len & (PAGE_SIZE - 1)) != 0
        ThreadListWatch.check(addr, len, ThreadListWatch::SITE_MADV_FREE)
        LibC.madvise(Pointer(Void).new(addr), LibC::SizeT.new(len), MADV_FREE) == 0
      {% else %}
        false
      {% end %}
    end

    # mremap(2) flags (<linux/mman.h>), the mmap flag that maps only where
    # nothing is mapped yet (Linux 4.17+), and `SIG_BLOCK`, which Crystal's
    # `LibC` leaves out.
    MREMAP_MAYMOVE      =        1
    MREMAP_FIXED        =        2
    MREMAP_DONTUNMAP    =        4
    MAP_FIXED_NOREPLACE = 0x100000
    SIG_BLOCK           =        0

    # 0 not asked yet, 1 yes, 2 no. Two first callers both ask and store the
    # same answer.
    @@page_moves = 0_u8

    # `GCRY_REALLOC_MOVE_TEST_UNBLOCKED_US=N`, research only: `move_pages`
    # leaves the stop signal unblocked and holds the window between its two
    # calls open N µs. The control arm of `make realloc-move-stress`.
    class_property move_test_unblocked_us : UInt64 = 0_u64

    # Whether `move_pages` may be tried at all. Not under strict overcommit
    # (`vm.overcommit_memory = 2`): there the kernel charges a move's growth
    # after it has unmapped the destination, and a charge that loses a race
    # for the commit limit leaves the destination unmapped. Under the
    # heuristic and always modes that charge cannot fail for memory the
    # destination already held. A kernel without `MREMAP_DONTUNMAP` (before
    # 5.7) refuses the first move with `EINVAL`, which turns this off too.
    def self.page_moves? : Bool
      {% if flag?(:linux) %}
        s = @@page_moves
        return s == 1_u8 unless s == 0_u8
        ok = overcommit_mode != '2'.ord
        @@page_moves = ok ? 1_u8 : 2_u8
        ok
      {% else %}
        false
      {% end %}
    end

    # Hand the pages of `[src, src + len)` to `[dst, dst + dst_len)` by page
    # table, `dst_len >= len`: no byte is copied and no page faulted. `src`
    # stays mapped with no pages behind it, so its next touch reads a zero
    # page; `dst` past `len` reads zeroes as a fresh mapping does. Both
    # ranges stay mapped from start to end, and `dst`'s data ends up as one
    # kernel mapping, however many times a block is grown this way.
    #
    # Two calls. `MREMAP_DONTUNMAP` leaves `src` mapped but cannot change the
    # size, and moving into the middle of `dst` would leave the destination
    # as two mappings, then three on the next growth, until
    # `vm.max_map_count` stops every `mmap` in the process. So the pages go
    # first to an address the kernel picks, then from there into `dst` with
    # the growth, as one mapping. The second call unmaps what it moves from,
    # which is the kernel's pick and nobody's memory.
    #
    # Between the calls the contents are in neither range, and a collection
    # that stopped this thread there would mark through neither. The stop
    # signal is blocked across both calls: a stop that asks then waits two
    # system calls for this thread, which takes no lock in between.
    #
    # False when nothing moved: `src` and `dst` are as they were. When the
    # second call is refused the contents are copied from the kernel's pick
    # into `dst` instead, and the answer is still true. That call unmaps
    # `dst` before it validates its source, so a refusal can leave a hole
    # where `dst` was; `MAP_FIXED_NOREPLACE` maps it again, and fails with
    # `EEXIST` when `dst` is still there. A hole that cannot be mapped again
    # is fatal: the heap would hold a chunk that points at nothing.
    def self.move_pages(src : UInt64, len : UInt64, dst : UInt64, dst_len : UInt64, hugepages : Bool) : Bool
      {% if flag?(:linux) %}
        unblocked_us = @@move_test_unblocked_us
        block = uninitialized LibC::SigsetT
        saved = uninitialized LibC::SigsetT
        LibC.sigemptyset(pointerof(block))
        LibC.sigaddset(pointerof(block), STW_SIG_SUSPEND)
        LibC.pthread_sigmask(SIG_BLOCK, pointerof(block), pointerof(saved)) if unblocked_us == 0
        staged = LibC.mremap(Pointer(Void).new(src), LibC::SizeT.new(len), LibC::SizeT.new(len),
          MREMAP_MAYMOVE | MREMAP_DONTUNMAP)
        if Gcry.mmap_failed?(staged)
          # No destination was named, so nothing changed. `EINVAL` is a
          # kernel without `MREMAP_DONTUNMAP`, which refuses every move.
          @@page_moves = 2_u8 if Errno.value == Errno::EINVAL
          LibC.pthread_sigmask(LibC::SIG_SETMASK, pointerof(saved), Pointer(LibC::SigsetT).null) if unblocked_us == 0
          return false
        end
        if unblocked_us > 0
          deadline = Gcry::Clock.monotonic_ns &+ unblocked_us &* 1000_u64
          while Gcry::Clock.monotonic_ns < deadline
            Intrinsics.pause
          end
        end
        moved = LibC.mremap(staged, LibC::SizeT.new(len), LibC::SizeT.new(dst_len),
          MREMAP_MAYMOVE | MREMAP_FIXED, Pointer(Void).new(dst))
        unless moved.address == dst
          back = LibC.mmap(Pointer(Void).new(dst), LibC::SizeT.new(dst_len), LibC::PROT_READ | LibC::PROT_WRITE,
            LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0)
          if back.address == dst
            LibC.madvise(back, LibC::SizeT.new(dst_len), hugepages ? MADV_HUGEPAGE : MADV_NOHUGEPAGE)
          elsif !(Gcry.mmap_failed?(back) && Errno.value == Errno::EEXIST)
            buf = uninitialized UInt8[RawOut::LIMIT]
            n = RawOut.append(buf.to_unsafe, 0, "gcry: FATAL a refused page move left its destination 0x")
            n = RawOut.append_hex(buf.to_unsafe, n, dst)
            n = RawOut.append(buf.to_unsafe, n, " (")
            n = RawOut.append_u64(buf.to_unsafe, n, dst_len)
            n = RawOut.append(buf.to_unsafe, n, " bytes) unmapped, and it could not be mapped again\n")
            RawOut.flush(buf.to_unsafe, n)
            LibC.abort
          end
          Pointer(UInt8).new(dst).copy_from(staged.as(UInt8*), len)
          LibC.munmap(staged, LibC::SizeT.new(len))
        end
        LibC.pthread_sigmask(LibC::SIG_SETMASK, pointerof(saved), Pointer(LibC::SigsetT).null) if unblocked_us == 0
        true
      {% else %}
        false
      {% end %}
    end

    # The first byte of `/proc/sys/vm/overcommit_memory`; 0 when unreadable.
    private def self.overcommit_mode : Int32
      fd = LibC.open("/proc/sys/vm/overcommit_memory", LibC::O_RDONLY)
      return 0 if fd < 0
      c = 0_u8
      n = LibC.read(fd, pointerof(c), LibC::SizeT.new(1))
      LibC.close(fd)
      n == 1 ? c.to_i32 : 0
    end
  end
end
