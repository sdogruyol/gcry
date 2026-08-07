# Lowest page of a stack that can hold anything — the low-water mark.
#
# Under multi-mutator STW with `stw_multi_stack_lag = 0`, every parked fiber is
# scanned `guard → bottom`. Crystal fiber stacks are 8 MiB of *reserved* address
# space, and almost none of it is ever written: measured on Kemal-shaped work,
# 69 parked stacks held 552 MiB of virtual stack and **284 KiB** of touched
# pages — 0.05%. The other 99.95% is scanned to read zeros, at the cost of a
# minor fault per page.
#
# A page that has never been written holds no pointer, so skipping it changes
# nothing about what the scan can find. That makes this a pure cost removal, not
# a precision trade: `guard → bottom` and `low_water → bottom` see exactly the
# same words, because everything below the low-water mark is provably zero.
#
# `mincore(2)` is the obvious tool and is wrong here: it answers "resident",
# so a page that was written and later swapped out reads as absent, and skipping
# it *would* lose a pointer. `/proc/self/pagemap` distinguishes the two —
# bit 63 present, bit 62 swapped — and a page with neither was never faulted.
# That is the test used here, so memory pressure cannot turn this into a missed
# root.
#
# Callable under STW: no allocation, fixed buffer, `pread` into it.
{% skip_file unless flag?(:linux) %}

lib LibC
  fun pread(fd : Int, buf : Void*, count : SizeT, offset : OffT) : SSizeT
end

module Gcry
  module Platform
    PAGEMAP_ENTRY_BYTES =    8
    PAGEMAP_CHUNK       = 1024 # entries per pread → 8 KiB, covers 4 MiB of stack
    PAGEMAP_PRESENT     = 1_u64 << 63
    PAGEMAP_SWAPPED     = 1_u64 << 62

    @@pagemap_fd = -1
    @@pagemap_pid = 0
    @@pagemap_buf = uninitialized StaticArray(UInt64, PAGEMAP_CHUNK)
    @@pagemap_failed = false

    # Reopened when the pid changes: an fd on /proc/self/pagemap keeps pointing
    # at the *parent's* map across fork, which would report another process's
    # residency for our stacks.
    private def self.pagemap_fd : Int32
      pid = LibC.getpid
      if @@pagemap_fd >= 0 && @@pagemap_pid == pid
        return @@pagemap_fd
      end
      LibC.close(@@pagemap_fd) if @@pagemap_fd >= 0
      @@pagemap_fd = LibC.open("/proc/self/pagemap", 0) # O_RDONLY
      @@pagemap_pid = pid
      @@pagemap_fd
    end

    def self.pagemap_available? : Bool
      !@@pagemap_failed && pagemap_fd >= 0
    end

    # Address of the lowest page in [low, high) that is present or swapped, i.e.
    # the lowest address that can hold a written word. Returns `high` when the
    # whole range is untouched, and `low` if pagemap cannot be read — falling
    # back to scanning everything, which is the pre-existing behaviour.
    def self.stack_low_water(low : UInt64, high : UInt64) : UInt64
      return low if @@pagemap_failed
      # Empty or inverted: answer `low`, never `high`. Every other return here
      # is a start-of-scan address, and the one thing this must never do is hand
      # back something below its own range that a caller might scan from.
      return low if high <= low

      fd = pagemap_fd
      if fd < 0
        @@pagemap_failed = true
        return low
      end

      page = Roots::PAGE_SIZE
      first = low // page
      last = (high + page - 1) // page # exclusive
      idx = first

      while idx < last
        want = last - idx
        want = PAGEMAP_CHUNK.to_u64 if want > PAGEMAP_CHUNK
        bytes = want * PAGEMAP_ENTRY_BYTES
        n = LibC.pread(fd,
          @@pagemap_buf.to_unsafe.as(Void*),
          LibC::SizeT.new(bytes),
          LibC::OffT.new(idx * PAGEMAP_ENTRY_BYTES))
        if n <= 0
          # Kernel refused the read (hardened /proc, for one). Never silently
          # narrow the scan on a failure — fall back to the full range.
          @@pagemap_failed = true
          return low
        end

        got = (n // PAGEMAP_ENTRY_BYTES).to_u64
        i = 0_u64
        while i < got
          entry = @@pagemap_buf[i]
          if (entry & (PAGEMAP_PRESENT | PAGEMAP_SWAPPED)) != 0
            addr = (idx + i) * page
            return addr < low ? low : addr
          end
          i += 1
        end
        idx += got
      end

      high
    end
  end
end
