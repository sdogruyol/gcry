require "c/pthread"

module Gcry
  # Darwin pthread stack bounds (for STW root scanning / main-fiber setup).
  module Platform
    # Returns {stack_low, stack_high} for *thread*, or nil on failure.
    # *stack_high* is the exclusive top (stack grows down toward *stack_low*).
    # Darwin: pthread_get_stackaddr_np returns the high address.
    def self.pthread_stack_bounds(thread : LibC::PthreadT) : {Void*, Void*}?
      {% if flag?(:darwin) %}
        addr = LibC.pthread_get_stackaddr_np(thread)
        size = LibC.pthread_get_stacksize_np(thread)
        return nil if addr.null? || size == 0

        high = addr
        low = Pointer(Void).new(addr.address - size.to_u64)
        {low, high}
      {% else %}
        nil
      {% end %}
    end

    def self.current_pthread_stack_bounds : {Void*, Void*}?
      {% if flag?(:darwin) %}
        pthread_stack_bounds(LibC.pthread_self)
      {% else %}
        nil
      {% end %}
    end

    # Same API as the Linux snapshot, and deliberately not the same mechanism.
    # Linux cannot call `pthread_getattr_np` under STW — it takes the target's
    # descriptor lock and mallocs for the main thread, which deadlocked against a
    # frozen thread (see linux_stack.cr). Darwin's accessors only read the
    # descriptor: no lock, no allocation, no `/proc` equivalent. So there is
    # nothing to snapshot here and the lookup answers directly.
    def self.begin_stack_bounds_snapshot : Nil
    end

    def self.snapshot_pthread_stack_bounds(thread : LibC::PthreadT) : Nil
    end

    def self.snapshotted_stack_bounds(thread : LibC::PthreadT) : {Void*, Void*}?
      pthread_stack_bounds(thread)
    end

    def self.stack_bounds_snapshot_misses : UInt64
      0_u64
    end
  end
end
