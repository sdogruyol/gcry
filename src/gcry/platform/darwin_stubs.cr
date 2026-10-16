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

      # `pthread_getspecific(key)` without the call: libpthread's own
      # `_pthread_getspecific_direct`. The thread's TSD array is at
      # TPIDRRO_EL0 on arm64, whose low three bits may carry the CPU number
      # and are masked, and at the %gs base on x86_64; a key is its index.
      # The asm is volatile so that two reads in one function are never
      # merged across a fiber switch that moved the fiber to another thread
      # (the reason Crystal reads `@[ThreadLocal]` through a `NoInline`
      # call). `Heap#cursor_set_under_lock` checks it against
      # `pthread_getspecific` before the hit path uses it.
      @[AlwaysInline]
      def self.tsd_read(key : UInt64) : Void*
        {% if flag?(:aarch64) %}
          base = 0_u64
          asm("mrs $0, tpidrro_el0" : "=r"(base) :: : "volatile")
          # Wrapping arithmetic: `Pointer#[]` would check `key` for Int64.
          Pointer(Pointer(Void)).new((base & ~7_u64) &+ key &* 8_u64).value
        {% else %}
          value = 0_u64
          asm("movq %gs:(,$1,8), $0" : "=r"(value) : "r"(key) : : "volatile")
          Pointer(Void).new(value)
        {% end %}
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

      # <sys/mman.h>
      MADV_FREE          = 5
      MADV_FREE_REUSABLE = 7
      MADV_FREE_REUSE    = 8

      # `GCRY_DARWIN_REUSABLE=0`: release with `MADV_FREE` everywhere, as
      # before 2026-09-27. The red arm of `make parallel-dormant` on Darwin.
      class_property reusable_release : Bool = true

      # Drop physical pages while keeping the VA reserved, with `MADV_FREE`:
      # the kernel takes the pages only under memory pressure, and until then
      # they count in both `ps` RSS and `phys_footprint`. Only the free-page
      # walk uses this, because a page there is used again by whichever
      # allocation lands in it, with no single place to announce the reuse.
      # Content may linger or read zero — do not rely on either.
      # Ranges must be host-page aligned (16 KiB on Apple Silicon).
      def self.release_physical_pages(addr : UInt64, len : UInt64) : Bool
        madvise_aligned(addr, len, MADV_FREE)
      end

      # `MADV_FREE_REUSABLE`: the pages leave `phys_footprint` at once. The
      # caller owes a `reuse_released_pages` over the same range before it
      # touches them again, or the task's footprint under-counts memory it is
      # using. Content may read zero afterwards.
      #
      # Until 2026-09-27 every release on Darwin was `MADV_FREE` although the
      # tree said `MADV_FREE_REUSABLE`: `make parallel-dormant` on the runner
      # made 44 MB dormant and the footprint stayed at 51 MB either way.
      def self.release_reusable_pages(addr : UInt64, len : UInt64) : Bool
        madvise_aligned(addr, len, @@reusable_release ? MADV_FREE_REUSABLE : MADV_FREE)
      end

      def self.reuse_released_pages(addr : UInt64, len : UInt64) : Nil
        madvise_aligned(addr, len, MADV_FREE_REUSE) if @@reusable_release
      end

      private def self.madvise_aligned(addr : UInt64, len : UInt64, advice : Int32) : Bool
        return false if len == 0
        page = host_page_size
        return false if (addr & (page - 1)) != 0
        return false if (len & (page - 1)) != 0
        LibC.madvise(Pointer(Void).new(addr), LibC::SizeT.new(len), advice) == 0
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

    # Same contract as `each_map_region`: false is "could not look", not
    # "walked everything and found nothing". `task_threads` could enumerate
    # this, but `os_thread_count` already answers `nil` here, so the census
    # never reaches the walk and an unmeasured implementation would be a claim
    # rather than a measurement.
    def self.each_os_thread(& : Int32, UInt8*, Int32 ->) : Bool
      false
    end

    def self.own_thread_comm?(name : UInt8*, len : Int32) : Bool
      false
    end

    # A no-op rather than `pthread_setname_np`: the name exists to be read back
    # out of `/proc/self/task/<tid>/comm` by the census, and there is no census
    # on this platform to read it.
    def self.name_own_thread(handle : Gcry::OS::PthreadT, name : String) : Nil
    end

    # No `/proc` here either. `thread_info` could answer the first and
    # `dladdr` the second; `os_thread_count` returns `nil`, so the census
    # never reaches them and an unmeasured implementation would be a claim.
    def self.current_tid : Int32
      0
    end

    def self.thread_syscall_site(tid : Int32) : {Int64, UInt64, UInt64}?
      nil
    end

    def self.pc_mapping(pc : UInt64, & : UInt8*, Int32, UInt64 ->) : Bool
      false
    end

    def self.read_self_memory(remote : UInt64, dst : Void*, bytes : Int32) : Int32
      0
    end

    def self.each_stack_code_address(sp : UInt64, max_hits : Int32, & : UInt64 ->) : Bool
      false
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
