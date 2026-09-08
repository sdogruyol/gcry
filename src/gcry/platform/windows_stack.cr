module Gcry
  module Platform
    def self.current_pthread_stack_bounds : {Void*, Void*}?
      LibC.GetCurrentThreadStackLimits(out low, out high)
      {Pointer(Void).new(low), Pointer(Void).new(high)}
    end

    def self.pthread_stack_bounds(handle : LibC::HANDLE) : {Void*, Void*}?
      Thread.unsafe_each do |thread|
        next unless thread.to_unsafe == handle
        if fiber = thread.@main_fiber
          stack = fiber.@stack
          return {stack.pointer.as(Void*), stack.bottom.as(Void*)}
        end
      end
      nil
    end

    # Crystal records each thread's stack bounds at startup, so suspended
    # threads need no OS query or allocating snapshot.
    def self.begin_stack_bounds_snapshot : Nil
    end

    # Linux caches the initial thread's bounds; here every lookup is direct.
    def self.note_main_thread : Nil
    end

    def self.reset_main_thread_after_fork : Nil
    end

    def self.stack_bounds_main_cached : UInt64
      0_u64
    end

    def self.stack_bounds_main_refreshed : UInt64
      0_u64
    end

    def self.snapshot_pthread_stack_bounds(thread : LibC::HANDLE) : Nil
    end

    def self.snapshotted_stack_bounds(thread : LibC::HANDLE) : {Void*, Void*}?
      pthread_stack_bounds(thread)
    end

    def self.stack_bounds_snapshot_misses : UInt64
      0_u64
    end

    # There is no table to run out of, for the same reason there is nothing to
    # snapshot. Zero rather than a missing method: a caller that gates on this
    # must not have to ask which platform it is on.
    def self.stack_bounds_capacity_misses : UInt64
      0_u64
    end

    def self.stack_bounds_nogrow=(value : Bool) : Bool
      value
    end

    def self.stack_bounds_visited : UInt64
      0_u64
    end

    def self.stack_bounds_read : UInt64
      0_u64
    end

    def self.stack_bounds_in_flight : UInt64
      0_u64
    end

    def self.stack_bounds_seen_before?(id : UInt64) : Bool
      false
    end

    def self.stack_bounds_seen_full? : Bool
      false
    end
  end
end
