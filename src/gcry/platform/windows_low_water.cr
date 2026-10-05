# Windows' answer to `linux_pagemap.cr` and `darwin_low_water.cr`: the lowest
# address of a stack that can hold a word the scan reads — the low-water mark.
#
# Crystal 1.21 lays out every fiber stack on Windows the way the OS lays out a
# thread's (`src/crystal/system/win32/fiber.cr`, `commit_and_guard`): 8 MiB
# `MEM_RESERVE`, the top page `MEM_COMMIT`/`PAGE_READWRITE`, and under it one
# page plus `RESERVED_STACK_SIZE` (64 KiB) committed `PAGE_READWRITE |
# PAGE_GUARD`. A frame that reaches the guard band takes a guard-page fault, the
# OS clears that page's guard bit and commits the next one down as the new
# guard ("Thread Stack Size" and "Creating Guard Pages", Win32 docs). So the
# stack only ever reads, from its low end up: reserved, guard band, committed
# body.
#
# Unlike Linux and Darwin, that never-touched head was already *cheap* here:
# `Roots.scan_range(safe: true)` walks a Windows range by `VirtualQuery` region
# (`Platform.each_readable_region`) and reads only regions `memory_readable?`
# accepts — committed, not `PAGE_GUARD`, not `PAGE_NOACCESS`, some read right —
# so the 8 MiB reservation costs one query, not 2048 page reads, and no scan
# reads a reserved page (an access violation) or a guard page (which would
# fire the guard and move the stack's growth point under the running program).
# Every stack read in the collector goes through that path. What was missing
# is the mark itself: without it Windows started every whole-stack scan at
# `guard` and reported `low_water_skips = 0`, so `/gc-stats` and
# `GCRY_STACK_LOW_WATER=0` said nothing about this platform.
#
# The claim is the same as on the other two — the scan from the mark sees
# exactly the words the scan from `low` does — and here it holds by
# construction: the walk below stops at the first region the same
# `memory_readable?` accepts, and everything under it is a region
# `each_readable_region` would have stepped over unread. It is also true of the
# memory itself, independent of the scan:
# * `MEM_RESERVE` / `MEM_FREE` pages have no storage at all (`VirtualAlloc`
#   reserves "without allocating any actual physical storage in memory or in
#   the paging file on disk");
# * a page still `PAGE_GUARD` has not been accessed since the guard was set,
#   because the first access "turn[s] off the guard page status" (Memory
#   Protection Constants), and Crystal and the OS only ever set it on a page
#   they have just committed, which `VirtualAlloc` zero-fills ("Memory
#   allocated by this function is automatically initialized to zero").
# A committed read-write page that was never touched is *not* skipped — the
# region attributes cannot tell it from a written one, so it is scanned.
#
# `MEMORY_BASIC_INFORMATION.RegionSize` covers "the region beginning at the base
# address in which all pages have identical attributes", so one query per
# region, about three per stack. Callable under stop-the-world: no allocation,
# the record lives on this frame, and `VirtualQuery` is already called inside
# the stop by `each_readable_region`, `dead_stack_floor` and
# `unborn_stack_bounds`. On any failure the answer is `low`: a wider scan.
{% skip_file unless flag?(:win32) %}

module Gcry
  module Platform
    # Same question the call sites ask on Linux, where `/proc/self/pagemap`
    # can be refused for the whole process. `VirtualQuery` on this process's
    # own address space has no such mode — a failed query falls back for that
    # call alone — so the probe is always there.
    def self.pagemap_available? : Bool
      true
    end

    # Lowest address in [low, high) that lies in a readable committed region,
    # i.e. the first word a `safe` scan from *low* would read. `high` when no
    # region in the range is readable; `low` for an empty or inverted range or
    # when `VirtualQuery` will not answer, which scans everything.
    def self.stack_low_water(low : UInt64, high : UInt64) : UInt64
      # Empty or inverted: answer `low`, never `high` — see `linux_pagemap.cr`.
      return low if high <= low
      cursor = low
      while cursor < high
        # 0 means the address is outside what this process can describe (above
        # `lpMaximumApplicationAddress`, for one); nothing about the range is
        # known, so nothing is skipped.
        return low if LibC.VirtualQuery(Pointer(Void).new(cursor), out info, sizeof(LibC::MEMORY_BASIC_INFORMATION)) == 0
        # The first readable region: *cursor* is `low` itself or the base of a
        # region every byte below which was found unreadable, so it never sits
        # above a word the scan could have read.
        return cursor if memory_readable?(info)
        finish = info.baseAddress.address &+ info.regionSize
        # A region that does not end above the cursor would loop forever, and
        # a description this wrong vouches for nothing: scan it all.
        return low if finish <= cursor
        cursor = finish
      end
      high
    end
  end
end
