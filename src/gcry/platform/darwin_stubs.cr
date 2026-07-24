# macOS / Darwin platform surface. Process GC under `-Dgc_none` is not a
# supported runtime yet (needs Mach thread suspend + dyld image roots). Stubs
# keep the shard compiling so library-heap specs can run under Boehm on darwin.

require "c/pthread"

module Gcry
  module Platform
    {% if flag?(:darwin) %}
      enum BarrierBackend
        None
        SoftDirty
        Mprotect
      end

      PAGE_SIZE = 4096_u64

      def self.darwin_process_gc_supported? : Bool
        false
      end

      def self.invalidate_static_root_cache : Nil
      end

      def self.scan_static_roots(& : Void*, Void* ->) : Nil
      end

      def self.pthread_stack_bounds(thread : LibC::PthreadT) : {Void*, Void*}?
        nil
      end

      def self.current_pthread_stack_bounds : {Void*, Void*}?
        nil
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

      def self.install_stw_sp_capture : Nil
      end

      def self.stw_sp_capture_installed? : Bool
        false
      end

      def self.stw_sp_clamp_enabled? : Bool
        false
      end

      def self.stw_sp_clamp_enabled=(value : Bool) : Bool
        value
      end

      def self.clear_thread_sps : Nil
      end

      def self.reset_stw_after_fork : Nil
      end

      def self.thread_sp(id : LibC::PthreadT) : Void*?
        nil
      end

      def self.sp_from_ucontext(uctx : Void*) : UInt64
        0_u64
      end

      def self.rsp_from_ucontext(uctx : Void*) : UInt64
        0_u64
      end

      def self.set_atfork_handlers(prepare : -> Nil, parent : -> Nil, child : -> Nil) : Nil
      end

      def self.install_atfork : Nil
      end

      def self.atfork_installed? : Bool
        false
      end
    {% end %}
  end
end
