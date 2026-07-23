require "c/pthread"

module Gcry
  # Linux pthread stack bounds (for STW root scanning / main-fiber setup).
  module Platform
    # Returns {stack_low, stack_high} for *thread*, or nil on failure.
    # *stack_high* is the exclusive top (stack grows down toward *stack_low*).
    def self.pthread_stack_bounds(thread : LibC::PthreadT) : {Void*, Void*}?
      {% if flag?(:linux) %}
        attr = uninitialized LibC::PthreadAttrT
        return nil unless LibC.pthread_getattr_np(thread, pointerof(attr)) == 0

        begin
          addr = Pointer(Void).null
          size = LibC::SizeT.new(0)
          return nil unless LibC.pthread_attr_getstack(pointerof(attr), pointerof(addr), pointerof(size)) == 0
          return nil if addr.null? || size == 0

          high = Pointer(Void).new(addr.address + size.to_u64)
          {addr, high}
        ensure
          LibC.pthread_attr_destroy(pointerof(attr))
        end
      {% else %}
        nil
      {% end %}
    end

    def self.current_pthread_stack_bounds : {Void*, Void*}?
      {% if flag?(:linux) %}
        pthread_stack_bounds(LibC.pthread_self)
      {% else %}
        nil
      {% end %}
    end
  end
end
