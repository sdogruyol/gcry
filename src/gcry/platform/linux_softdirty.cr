require "c/fcntl"
require "c/unistd"

module Gcry
  # Linux soft-dirty page tracking for nursery old→young edges without
  # compiler write barriers. See `/proc/pid/clear_refs` (4) and pagemap bit 55.
  module Platform
    PAGE_SIZE          = 4096_u64
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
      {% if flag?(:linux) %}
        return true if high <= low

        fd = LibC.open("/proc/self/pagemap", LibC::O_RDONLY)
        return false if fd < 0

        begin
          page_low = low & ~(PAGE_SIZE - 1)
          # Round high up to page boundary exclusive.
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
              if (buf.to_unsafe[i] & PAGEMAP_SOFT_DIRTY) != 0
                yield addr + i.to_u64 * PAGE_SIZE
              end
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
  end
end
