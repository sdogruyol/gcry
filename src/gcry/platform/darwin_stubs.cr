# Darwin soft-dirty / mprotect stubs + capability flag.
# Real stack / roots / STW / atfork live in darwin_{stack,roots,stw}.cr + linux_fork.cr.

require "c/pthread"
require "c/sys/mman"
require "c/unistd"

module Gcry
  module Platform
    {% if flag?(:darwin) %}
      enum BarrierBackend
        None
        SoftDirty
        Mprotect
      end

      # Dead on this platform — the soft-dirty paths that read it are guarded on
      # the linux flag — but it was 4096 in a file whose own `host_page_size`
      # documents Apple Silicon as 16 KiB. A constant that is both wrong and
      # unused is one refactor away from being wrong and used.
      PAGE_SIZE = host_page_size

      def self.darwin_process_gc_supported? : Bool
        true
      end

      def self.clear_soft_dirty : Bool
        false
      end

      def self.each_dirty_page(low : UInt64, high : UInt64, & : UInt64 ->) : Bool
        false
      end

      def self.count_soft_dirty_pages(low : UInt64, high : UInt64) : {UInt64, UInt64}?
        nil
      end

      def self.soft_dirty_supported? : Bool
        false
      end

      def self.install_mprotect_barrier : Bool
        false
      end

      def self.disable_mprotect_barrier : Nil
      end

      def self.mprotect_barrier_enabled? : Bool
        false
      end

      def self.mprotect_hits : UInt64
        0_u64
      end

      def self.mprotect_set_heap_range(low : UInt64, high : UInt64) : Nil
      end

      def self.clear_mprotect_cards : Nil
      end

      def self.mprotect_protect_range(low : UInt64, high : UInt64) : Nil
      end

      def self.mprotect_unprotect_range(low : UInt64, high : UInt64) : Nil
      end

      def self.mprotect_fault(addr : UInt64) : Bool
        false
      end

      def self.each_mprotect_dirty_page(& : UInt64 ->) : Nil
      end

      def self.clear_mprotect_dirty_bits : Nil
      end

      def self.count_mprotect_dirty_pages : {UInt64, UInt64}
        {0_u64, 0_u64}
      end

      # Host page size (16 KiB on Apple Silicon, 4 KiB on Intel).
      def self.host_page_size : UInt64
        sz = LibC.sysconf(LibC::SC_PAGESIZE)
        sz > 0 ? sz.to_u64 : 16384_u64
      end

      # Drop physical pages while keeping the VA reserved.
      # On Darwin uses MADV_FREE_REUSABLE (one madvise syscall) which drops RSS
      # when the kernel reclaims; next fault zero-fills if reclaimed (content may
      # linger until pressure — do not rely on immediate zeroing).
      # Ranges must be host-page aligned (16 KiB on Apple Silicon).
      def self.release_physical_pages(addr : UInt64, len : UInt64) : Bool
        return false if len == 0
        page = host_page_size
        return false if (addr & (page - 1)) != 0
        return false if (len & (page - 1)) != 0
        LibC.madvise(Pointer(Void).new(addr), LibC::SizeT.new(len), 5) == 0
      end
    {% end %}
  end
end

module Gcry
  module Platform
    # No portable `/proc/self/status` here, and a number nobody measured is
    # worse than none — see `linux_thread_census.cr`. `nil` means "cannot
    # answer", which a caller must handle rather than compare against zero.
    def self.os_thread_count : Int32?
      nil
    end

    # Same contract as `linux_address_space.cr`: false means "could not look",
    # which is not the same answer as "walked everything and found nothing".
    # `mach_vm_region` could enumerate this, but nothing has needed it yet and
    # an unmeasured walk is worse than an honest refusal.
    def self.each_map_region(& : UInt64, UInt64, UInt8*, UInt8*, Int32 ->) : Bool
      false
    end
  end
end
