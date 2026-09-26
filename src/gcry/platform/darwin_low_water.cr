# Darwin's answer to `linux_pagemap.cr`: the lowest page of a stack that can
# hold anything — the low-water mark — so a parked fiber's 8 MiB of reserved,
# almost entirely unwritten stack is not scanned to read zeros.
#
# Same claim, same shape: a page that has never been written holds no pointer,
# so starting the scan at the first page that *has* been cannot change what the
# scan finds. The test is "neither resident nor paged out", and the second half
# is the whole point: residency alone would call a written page that macOS has
# compressed or swapped "untouched", and skipping it would drop a root.
#
# The disposition bits are not taken on faith. `bench/darwin_page_query.cr`
# verified them on a macOS runner: untouched pages carry neither bit, written
# ones read `PRESENT`, every page the predicate calls skippable reads back zero,
# an `MADV_FREE_REUSABLE` page reads zero whatever its bits say, and — under
# 8960 MiB of incompressible ballast, 1.25 × the host's memory — 256 of 256
# written pages left residency and every one read `PAGED_OUT`
# (`bench/log/macos/2026-09-25-page-query-eviction/FINDINGS.md`). The bulk
# `mach_vm_page_range_query` used here is cross-checked against the per-page
# `mach_vm_page_query` those arms verified, on the two bits read here.
#
# One trap per `PAGE_QUERY_CHUNK` pages, not per page — a per-page query would
# cost a trap for every untouched page of every parked stack. Callable under
# stop-the-world: no allocation, a fixed buffer, and a Mach trap on this task's
# own map (a thread suspended with `thread_suspend` stops at the user boundary,
# so none is frozen inside the kernel holding the map lock).
{% skip_file unless flag?(:darwin) %}

module Gcry
  module Platform
    lib LibMachVM
      fun mach_vm_page_range_query(target_map : Port, address : UInt64, size : UInt64,
                                   dispositions : UInt64, dispositions_count : UInt64*) : KernReturn
      # The same signature `bench/bench_rss.cr` binds (`UInt32*` info): a C
      # function bound twice must be bound identically, and the soak links both.
      fun task_info(target_task : Port, flavor : Int32, info : UInt32*, info_count : UInt32*) : KernReturn
    end

    # <mach/vm_region.h>, VM_PAGE_QUERY_PAGE_*.
    PAGE_QUERY_PRESENT   = 0x001
    PAGE_QUERY_PAGED_OUT = 0x010
    PAGE_QUERY_CHUNK     =  1024

    # <mach/vm_region.h>, <mach/task_info.h>: the resident-count path below.
    VM_REGION_TOP_INFO       =    12
    VM_REGION_TOP_INFO_COUNT = 5_u32
    SM_PRIVATE               = 2_u32
    SM_PRIVATE_ALIASED       = 6_u32
    TASK_VM_INFO             =    22
    TASK_VM_INFO_COMPRESSED  =   120 # byte offset of `compressed` (pack 4)
    RESIDENT_WINDOW_PAGES    =    16
    RESIDENT_MIN_RANGE_PAGES =    64

    @@page_query_buf = uninitialized StaticArray(Int32, 1024)
    @@page_query_errors = 0_u64
    @@resident_low_water = true
    @@resident_hits = 0_u64
    @@resident_fallbacks = 0_u64

    # `GCRY_DARWIN_RESIDENT_LOW_WATER=0`: every range takes the full per-page
    # query, as before 2026-09-26. For A/B and as the red arm of the check in
    # `bench/stw_lag_pause.cr` that the path engages.
    def self.resident_low_water=(value : Bool) : Bool
      @@resident_low_water = value
    end

    # Ranges the resident count answered, and ranges it declined (compressed
    # memory, an object it cannot vouch for, or touched pages it could not all
    # account for) that then took the full query.
    def self.resident_hits : UInt64
      @@resident_hits
    end

    def self.resident_fallbacks : UInt64
      @@resident_fallbacks
    end

    # The call site asks this before trusting a skip it did not see happen
    # (`warn_stw_lag_zero_once`). The query has no global failure mode here —
    # a refused range falls back for that call alone — so it is always there.
    def self.pagemap_available? : Bool
      true
    end

    # Ranges the kernel refused to describe, each scanned in full.
    def self.page_query_errors : UInt64
      @@page_query_errors
    end

    # Address of the lowest page in [low, high) that is resident or paged out,
    # i.e. the lowest address that can hold a written word. `high` when the
    # whole range is untouched; `low` when the kernel will not answer, which
    # scans everything — the behaviour without this file.
    def self.stack_low_water(low : UInt64, high : UInt64) : UInt64
      # Empty or inverted: answer `low`, never `high` — see `linux_pagemap.cr`.
      return low if high <= low
      page = host_page_size
      if @@resident_low_water && (high - low) // page > RESIDENT_MIN_RANGE_PAGES
        if lw = resident_low_water(low, high, page)
          @@resident_hits &+= 1
          return lw
        end
        @@resident_fallbacks &+= 1
      end
      full_low_water(low, high, page)
    end

    # The query below charges ~275 ns per page it describes (measured on the
    # macOS runner, `make darwin-page-query`), so proving a parked fiber's
    # untouched 8 MiB costs ~141 µs, every collection, and `GCRY_SOUND=1` asks
    # it of every parked fiber: 5.8× the tuned pause at Kemal EC4
    # (`bench/log/linux/2026-09-26-sound-matrix/FINDINGS.md`). Stacks are used
    # from the top, so the written pages are a short run under `high`, and what
    # costs is proving the rest untouched. The VM object's resident page count
    # proves it in one call: walk down from `high` in small queries until the
    # touched pages found equal that count, and nothing below can be resident.
    #
    # Why that is enough, and when it is not:
    # * nothing below is compressed or swapped either, because nothing in the
    #   whole task is — `compressed` read as 0 before the count and again after
    #   the walk. The compressor may run while the world is stopped, and a page
    #   it takes in between would be touched and uncounted; the second read
    #   sees it. Nothing decompresses a page meanwhile: every other thread is
    #   suspended and this one only asks the kernel about pages;
    # * the object has no shadow chain whose pages the count would miss:
    #   `SM_PRIVATE`, or `SM_PRIVATE_ALIASED` (one object under two entries of
    #   this map, which a guard `mprotect` can leave). A count that includes
    #   pages outside the range only makes `found` fall short, and short means
    #   fall back;
    # * the part of the range below the entry (the guard's own entry, if the
    #   `mprotect` split it) is asked about in full.
    # Anything else answers nil and the caller takes the full query. Verified
    # page-for-page against it on Crystal-shaped stacks, including a written
    # page below an untouched gap (`make darwin-page-query`), and each stack
    # there had an object of its own.
    private def self.resident_low_water(low : UInt64, high : UInt64, page : UInt64) : UInt64?
      return nil unless task_compressed == 0
      info = uninitialized UInt32[8]
      where = high - page
      size = 0_u64
      count = VM_REGION_TOP_INFO_COUNT
      name = 0_u32
      kr = LibMachVM.mach_vm_region(LibMachVM.mach_task_self_, pointerof(where), pointerof(size),
        VM_REGION_TOP_INFO, info.to_unsafe.as(Int32*), pointerof(count), pointerof(name))
      return nil unless kr == 0
      mode = info[4] & 0xff_u32
      return nil unless mode == SM_PRIVATE || mode == SM_PRIVATE_ALIASED
      return nil unless where <= high - page && where + size >= high
      resident = info[2].to_u64 + info[3].to_u64
      aligned = low & ~(page - 1)
      lo = where > aligned ? where : aligned
      found = 0_u64
      lowest = high
      addr = high
      while addr > lo && found < resident
        want = (addr - lo) // page
        want = RESIDENT_WINDOW_PAGES.to_u64 if want > RESIDENT_WINDOW_PAGES
        return nil if want == 0
        from = addr - want * page
        got = want
        kr = LibMachVM.mach_vm_page_range_query(LibMachVM.mach_task_self_, from, want * page,
          @@page_query_buf.to_unsafe.address, pointerof(got))
        return nil if kr != 0 || got != want
        i = want.to_i32 - 1
        while i >= 0
          if (@@page_query_buf[i] & (PAGE_QUERY_PRESENT | PAGE_QUERY_PAGED_OUT)) != 0
            found &+= 1
            lowest = from + i.to_u64 * page
          end
          i -= 1
        end
        addr = from
      end
      return nil unless found == resident
      return nil unless task_compressed == 0
      if lo > aligned
        below = full_low_water(low, lo, page)
        return below < lo ? below : lowest
      end
      lowest < low ? low : lowest
    end

    private def self.task_compressed : UInt64
      buf = uninitialized UInt64[128]
      count = 256_u32
      kr = LibMachVM.task_info(LibMachVM.mach_task_self_, TASK_VM_INFO, buf.to_unsafe.as(UInt32*), pointerof(count))
      return UInt64::MAX unless kr == 0 && count * 4 >= TASK_VM_INFO_COMPRESSED + 8
      (buf.to_unsafe.as(UInt8*) + TASK_VM_INFO_COMPRESSED).as(UInt64*).value
    end

    private def self.full_low_water(low : UInt64, high : UInt64, page : UInt64) : UInt64
      addr = low & ~(page - 1)
      last = (high + page - 1) & ~(page - 1)
      while addr < last
        want = (last - addr) // page
        want = PAGE_QUERY_CHUNK.to_u64 if want > PAGE_QUERY_CHUNK
        count = want
        kr = LibMachVM.mach_vm_page_range_query(LibMachVM.mach_task_self_, addr, want * page,
          @@page_query_buf.to_unsafe.address, pointerof(count))
        if kr != 0 || count == 0 || count > want
          @@page_query_errors &+= 1
          return low
        end
        i = 0_u64
        while i < count
          if (@@page_query_buf[i] & (PAGE_QUERY_PRESENT | PAGE_QUERY_PAGED_OUT)) != 0
            hit = addr + i * page
            return hit < low ? low : hit
          end
          i += 1
        end
        addr += count * page
      end
      high
    end
  end
end
