require "c/fcntl"
require "c/unistd"

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
    MADV_NOHUGEPAGE = 15
    MADV_FREE       =  8
    MADV_COLD       = 20

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
  end
end
