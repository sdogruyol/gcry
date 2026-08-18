# Fiber stacks that belong to no fiber the collector can see.
#
# `Fiber.unsafe_each` is how gcry finds fiber stacks, so a stack no `Fiber`
# yields is scanned by nothing. The address-space audit
# (`bench/log/linux/2026-08-17-address-space-audit/FINDINGS.md`) found the dying
# `Deque(Fiber::Stack)` buffer's address on exactly such stacks, and this file
# is what closed the window they belong to.
#
# **The one that matters is the stack of a fiber that is terminating.** Crystal
# says why in `crystal/system/thread.cr`: *"When a fiber terminates we can't
# release its stack until we swap context to another fiber."* So
# `Thread#dying_fiber` parks the dying fiber's stack on the thread and hands
# back the previous one. While it sits there the thread may still be executing
# on it, and the fiber that owns it is already gone from the fiber list — and
# gcry's other-thread scan uses the *pthread* stack bounds, which a thread
# running on a fiber stack is nowhere near. Nothing covers it.
#
# Rooting it takes the repro from **11/24 crashes to 0/24**, with a twin arm
# that walks the same memory and offers nothing at **12/24**
# (`bench/log/linux/2026-08-17-dead-fiber-stack-roots/FINDINGS.md`). That twin
# is the whole design: the birth grace also went to zero, and its zero turned
# out to be timing rather than rooting.
#
# Two neighbouring windows were measured and are **not** the defect:
#
#   - **pooled** — a stack sitting in a `Fiber::StackPool` deque. Rooting them
#     is 20/24, worse than control. Those hits were stale copies.
#   - **in flight** — checked out of the pool, not yet attached to a published
#     `Fiber`. A hook on `Fiber::StackPool#checkout` that recorded exactly those
#     moved 13/24 to 8/24, which is not a result (p≈0.24), so the hook was
#     removed rather than shipped on a maybe.
#
# `GCRY_DEAD_STACK_ROOTS=0` turns the fix off. The research arms —
# `GCRY_DEAD_STACK_NOROOT`, `GCRY_POOLED_STACK_ROOTS`,
# `GCRY_POOLED_STACK_NOROOT`, `GCRY_MAPS_INFLIGHT_ROOTS`,
# `GCRY_MAPS_INFLIGHT_NOROOT` — stay, because the next question about this
# defect will want the same arms, and rebuilding them from a log is how a
# measurement gets quietly redefined.
#
# `GCRY_UNOWNED_COVERAGE_AUDIT=1` is the independent opinion: it walks
# `/proc/self/maps` beside the fix and counts stack-shaped mappings that no
# fiber, no pool and no thread's dying-fiber slot accounts for. A fix whose
# coverage is only argued for is the shape of every defect on this board.
#
# Only the top `UNOWNED_STACK_WINDOW` of a stack is scanned. Every hit the
# address-space audit reported was 968 to 1408 bytes below the stack top —
# `makecontext`'s frame — and walking 8 MiB per stack inside the pause would
# cost more than the defect does.

module Gcry
  class Heap
    # The fix. On by default; `GCRY_DEAD_STACK_ROOTS=0` disables it.
    property dead_stack_roots : Bool = true
    # Its twin: walk the same memory, offer nothing.
    property dead_stack_noroot : Bool = false

    property pooled_stack_roots : Bool = false
    property pooled_stack_noroot : Bool = false
    property maps_inflight_roots : Bool = false
    property maps_inflight_noroot : Bool = false

    property unowned_coverage_audit : Bool = false
    getter unowned_covered : UInt64 = 0_u64
    getter unowned_uncovered : UInt64 = 0_u64

    # Stacks walked and words offered, per arm. Counted so a null result cannot
    # be "the arm never ran" — the failure mode every step of this hunt has hit
    # at least once.
    getter dead_stacks_walked : UInt64 = 0_u64
    getter dead_stack_words : UInt64 = 0_u64
    getter pooled_stacks_walked : UInt64 = 0_u64
    getter pooled_stack_words : UInt64 = 0_u64
    getter maps_inflight_walked : UInt64 = 0_u64
    getter maps_inflight_words : UInt64 = 0_u64

    UNOWNED_STACK_WINDOW = 64_u64 * 1024

    # Rejects a torn or nonsensical pair before it becomes a range to scan. Not
    # every collection is stop-the-world, so a slot can be read while its owner
    # is writing it.
    MAX_STACK_BYTES = 64_u64 * 1024 * 1024

    protected def scan_unowned_stacks : Nil
      scan_dead_fiber_stacks if @dead_stack_roots || @dead_stack_noroot
      scan_pooled_stacks if @pooled_stack_roots || @pooled_stack_noroot
      if @maps_inflight_roots || @maps_inflight_noroot || @unowned_coverage_audit
        scan_maps_inflight_stacks
      end
    end

    # Read from the ivar, never through `dead_fiber_stack?`, which hands the
    # slot over and clears it: a scan that consumed the thread's stack would
    # change what the program does, not just what the collector sees.
    private def scan_dead_fiber_stacks : Nil
      {% if Thread.instance_vars.any? { |v| v.name == "dead_fiber_stack" } %}
        offer = @dead_stack_roots
        Thread.unsafe_each do |thread|
          stack = thread.@dead_fiber_stack
          next unless stack
          lo = stack.pointer.address
          hi = stack.bottom.address
          next unless plausible_stack_range?(lo, hi)
          @dead_stacks_walked &+= 1
          walk_stack_top(lo, hi, offer, pointerof(@dead_stack_words))
        end
      {% end %}
    end

    private def scan_pooled_stacks : Nil
      offer = @pooled_stack_roots
      each_pooled_stack do |lo, hi|
        @pooled_stacks_walked &+= 1
        walk_stack_top(lo, hi, offer, pointerof(@pooled_stack_words))
      end
    end

    # Every mapping shaped like a `Fiber::StackPool` stack that nothing claims.
    # The shape test is the mapped size alone — `mmap` promises page alignment,
    # not stack-size alignment — so it can pick up an unrelated mapping of the
    # same size. That costs precision, not soundness: scanning extra memory
    # conservatively retains, it does not corrupt.
    private def scan_maps_inflight_stacks : Nil
      offer = @maps_inflight_roots
      walk = @maps_inflight_roots || @maps_inflight_noroot
      Platform.each_map_region do |lo, hi, perms, _name, _name_len|
        next unless perms[0] == 'r'.ord.to_u8
        next unless fiber_stack_geometry?(lo, hi)
        next if fiber_owns_stack?(lo, hi)
        next if pool_holds_stack?(lo, hi)
        if @unowned_coverage_audit
          if dying_fiber_stack?(lo, hi)
            @unowned_covered &+= 1
          else
            @unowned_uncovered &+= 1
          end
        end
        next unless walk
        @maps_inflight_walked &+= 1
        walk_stack_top(lo, hi, offer, pointerof(@maps_inflight_words))
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

    private def plausible_stack_range?(lo : UInt64, hi : UInt64) : Bool
      return false if lo == 0 || hi <= lo
      return false if (hi - lo) > MAX_STACK_BYTES
      page = Roots::PAGE_SIZE.to_u64
      return false unless (lo & (page - 1)) == 0
      (hi & (page - 1)) == 0
    end

    private def dying_fiber_stack?(lo : UInt64, hi : UInt64) : Bool
      {% if Thread.instance_vars.any? { |v| v.name == "dead_fiber_stack" } %}
        parked = false
        Thread.unsafe_each do |thread|
          next if parked
          stack = thread.@dead_fiber_stack
          next unless stack
          parked = true if stack.pointer.address <= lo && stack.bottom.address >= hi
        end
        parked
      {% else %}
        false
      {% end %}
    end

    private def fiber_owns_stack?(lo : UInt64, hi : UInt64) : Bool
      owned = false
      Fiber.unsafe_each do |fiber|
        next if owned
        stack = fiber.@stack
        owned = true if stack.pointer.address <= lo && stack.bottom.address >= hi
      end
      owned
    end

    private def pool_holds_stack?(lo : UInt64, hi : UInt64) : Bool
      held = false
      each_pooled_stack do |plo, phi|
        held = true if plo <= lo && phi >= hi
      end
      held
    end

    # The deque is read through its raw ivars and clamped rather than iterated:
    # the buffer whose freeing started this hunt is exactly the one this would
    # be walking, and an instrument must not become the second crash.
    private def each_pooled_stack(& : UInt64, UInt64 ->) : Nil
      {% if Thread.instance_vars.any? { |v| v.name == "execution_context" } %}
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
            yield lo, hi if plausible_stack_range?(lo, hi)
          end
        end
      {% end %}
    end
  end
end
