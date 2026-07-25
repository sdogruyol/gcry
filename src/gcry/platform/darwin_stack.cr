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
  end
end
