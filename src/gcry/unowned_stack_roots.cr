# Stacks that belong to no fiber, offered to the mark.
#
# Research arms for the fiber-creation use-after-free, and only that: both are
# off by default and neither is a fix. The address-space audit
# (`bench/log/linux/2026-08-17-address-space-audit/FINDINGS.md`) found the dying
# `Deque(Fiber::Stack)` buffer's address on two kinds of stack that
# `Fiber.unsafe_each` does not yield, so nothing scans them:
#
#   - **pooled** — sitting in a `Fiber::StackPool` deque, released by a fiber
#     that has finished,
#   - **in flight** — checked out of the pool and not yet attached to a
#     published `Fiber`.
#
# Both hold the value at the same place, 968–1408 bytes below the stack top,
# which is where `makecontext` writes a new fiber's first frame. The counts do
# not say which of the two the crash needs, and the two answers call for
# different fixes: pooled stacks are enumerable and cheap to scan, while the
# in-flight window is invisible to gcry and would need Crystal to say something
# it does not say today.
#
# So ask the crash. Each window gets an arm that roots it and an arm that walks
# exactly the same memory and roots **nothing** — because the birth grace
# already taught this hunt that an arm which roots more can take a crash rate to
# zero for reasons that have nothing to do with the pointer in question
# (`GCRY_BIRTH_GRACE`: null-rooting was as effective as rooting). A window is
# named only if its rooting arm goes to zero and its walking arm does not.
#
#   GCRY_POOLED_STACK_ROOTS=1     scan pooled stacks
#   GCRY_POOLED_STACK_NOROOT=1    walk them, offer nothing
#   GCRY_INFLIGHT_STACK_ROOTS=1   scan stack-shaped mappings no fiber and no
#                                 pool owns
#   GCRY_INFLIGHT_STACK_NOROOT=1  walk them, offer nothing
#
# Only the top `UNOWNED_STACK_WINDOW` of each stack is walked. A fiber's first
# frame is within 1.5 KiB of the top, and walking 8 MiB per stack inside the
# pause would make the arms unmeasurable against each other.

module Gcry
  class Heap
    property pooled_stack_roots : Bool = false
    property pooled_stack_noroot : Bool = false
    property inflight_stack_roots : Bool = false
    property inflight_stack_noroot : Bool = false

    # Stacks walked, and words offered to the mark, per arm. Counted so a null
    # result cannot be "the arm never ran" — the failure mode every step of this
    # hunt has hit at least once.
    getter pooled_stacks_walked : UInt64 = 0_u64
    getter pooled_stack_words : UInt64 = 0_u64
    getter inflight_stacks_walked : UInt64 = 0_u64
    getter inflight_stack_words : UInt64 = 0_u64

    UNOWNED_STACK_WINDOW = 64_u64 * 1024

    protected def scan_unowned_stacks : Nil
      scan_pooled_stacks if @pooled_stack_roots || @pooled_stack_noroot
      scan_inflight_stacks if @inflight_stack_roots || @inflight_stack_noroot
    end

    private def scan_pooled_stacks : Nil
      {% if Thread.instance_vars.any? { |v| v.name == "execution_context" } %}
        offer = @pooled_stack_roots
        Fiber::ExecutionContext.unsafe_each do |ec|
          pool = ec.stack_pool?
          next unless pool
          deque = pool.@deque
          buffer = deque.@buffer
          next if buffer.null?
          capacity = deque.@capacity
          size = deque.@size
          next if capacity <= 0 || size <= 0 || size > capacity
          start = deque.@start
          next if start < 0 || start >= capacity
          i = 0
          while i < size
            stack = buffer[(start + i) % capacity]
            i += 1
            lo = stack.pointer.address
            hi = stack.bottom.address
            next unless lo < hi
            @pooled_stacks_walked &+= 1
            walk_stack_top(lo, hi, offer, pointerof(@pooled_stack_words))
          end
        end
      {% end %}
    end

    # Every mapping shaped like a `Fiber::StackPool` stack that no live fiber
    # and no pool claims. The shape test is the mapped size alone — `mmap`
    # promises page alignment, not stack-size alignment — so this can in
    # principle pick up an unrelated mapping of exactly that size. That would
    # cost the arm precision, not soundness: scanning extra memory conservatively
    # retains, it does not corrupt.
    private def scan_inflight_stacks : Nil
      offer = @inflight_stack_roots
      Platform.each_map_region do |lo, hi, perms, _name, _name_len|
        next unless perms[0] == 'r'.ord.to_u8
        next unless fiber_stack_geometry?(lo, hi)
        next if fiber_owns_stack?(lo, hi)
        next if pool_holds_stack?(lo, hi)
        @inflight_stacks_walked &+= 1
        walk_stack_top(lo, hi, offer, pointerof(@inflight_stack_words))
      end
    end

    private def walk_stack_top(lo : UInt64, hi : UInt64, offer : Bool, words : UInt64*) : Nil
      low = hi - UNOWNED_STACK_WINDOW
      low = lo if low < lo
      Roots.scan_range(Pointer(Void).new(low), Pointer(Void).new(hi), safe: true) do |candidate|
        words.value &+= 1
        mark_root_candidate(candidate, source: RootSource::Parked) if offer
      end
    end

    private def fiber_owns_stack?(lo : UInt64, hi : UInt64) : Bool
      owned = false
      Fiber.unsafe_each do |fiber|
        next if owned
        stack = fiber.@stack
        base = stack.pointer.address
        bottom = stack.bottom.address
        owned = true if base <= lo && bottom >= hi
      end
      owned
    end

    private def pool_holds_stack?(lo : UInt64, hi : UInt64) : Bool
      held = false
      {% if Thread.instance_vars.any? { |v| v.name == "execution_context" } %}
        Fiber::ExecutionContext.unsafe_each do |ec|
          next if held
          pool = ec.stack_pool?
          next unless pool
          deque = pool.@deque
          buffer = deque.@buffer
          next if buffer.null?
          capacity = deque.@capacity
          size = deque.@size
          next if capacity <= 0 || size <= 0 || size > capacity
          start = deque.@start
          next if start < 0 || start >= capacity
          i = 0
          while i < size
            stack = buffer[(start + i) % capacity]
            i += 1
            if stack.pointer.address <= lo && stack.bottom.address >= hi
              held = true
              break
            end
          end
        end
      {% end %}
      held
    end
  end
end
