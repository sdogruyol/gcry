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
    end

    # <mach/vm_region.h>, VM_PAGE_QUERY_PAGE_*.
    PAGE_QUERY_PRESENT   = 0x001
    PAGE_QUERY_PAGED_OUT = 0x010
    PAGE_QUERY_CHUNK     =  1024

    @@page_query_buf = uninitialized StaticArray(Int32, 1024)
    @@page_query_errors = 0_u64

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
