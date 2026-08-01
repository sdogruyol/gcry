# Boehm-style stack hygiene without compiler stack maps.
#
# clear_stack: zero unused words below SP so later root scans do not treat
# stale stack slots as live. scrub_parked_fibers: same for parked fiber stacks.
#
# Alloc-path: GCRY_CLEAR_STACK=1. Parked-fiber collect scrub: process default;
# escape GCRY_DISABLE_SCRUB_FIBERS=1.
#
# clear_stack must not call Fiber/Thread APIs — those malloc during early
# Thread TLS publish and recurse into allocate. Bounds come from
# pthread_getattr_np (thread stack) or a small capped wipe on fiber stacks.

module Gcry
  class Heap
    DEFAULT_CLEAR_STACK_BYTES = 4096_u64
    # Fiber stacks start thinly mapped; keep non-pthread wipes small.
    FIBER_CLEAR_STACK_CAP = 512_u64

    property clear_stack_enabled : Bool = false
    property clear_stack_bytes : UInt64 = DEFAULT_CLEAR_STACK_BYTES
    # When > 1, only every Nth allocate calls clear_stack (thr trade-off).
    property clear_stack_every : Int32 = 1
    property scrub_fibers_enabled : Bool = false

    getter clear_stack_bytes_total : UInt64 = 0_u64
    getter fiber_scrub_bytes_total : UInt64 = 0_u64
    getter clear_stack_calls : UInt64 = 0_u64
    getter fiber_scrub_runs : UInt64 = 0_u64

    @clear_stack_ops : UInt64 = 0_u64

    # Plain flag (not ThreadLocal): must work before Thread TLS exists.
    # Same-thread reentrancy only; concurrent MT clears on different stacks
    # may briefly skip — acceptable for an opt-in hygiene path.
    @@clear_stack_active = false

    {% if flag?(:x86_64) %}
      # SysV ABI red zone — callees may use [SP-128, SP) without adjusting SP.
      CLEAR_STACK_RED_ZONE = 128_u64
    {% else %}
      CLEAR_STACK_RED_ZONE = 0_u64
    {% end %}
    # Extra skip below hardware SP so leaf spills / alignment never get wiped.
    CLEAR_STACK_LEAF_MARGIN = 64_u64

    # Zero unused stack below the hardware SP (stack grows down).
    def clear_stack(bytes : UInt64 = @clear_stack_bytes) : Nil
      return if bytes == 0
      return if @@clear_stack_active
      @@clear_stack_active = true
      begin
        clear_stack_body(bytes)
      ensure
        @@clear_stack_active = false
      end
    end

    private def clear_stack_body(bytes : UInt64) : Nil
      # Must use hardware SP — Roots.stack_pointer is mid-frame and wiping
      # up to it corrupts the leaf (null-deref SEGV on aarch64 CI).
      sp_addr = Roots.hardware_stack_pointer.address
      skip = CLEAR_STACK_RED_ZONE + CLEAR_STACK_LEAF_MARGIN
      return if sp_addr <= skip

      high = sp_addr - skip
      guard = 0_u64
      on_thread_stack = false

      {% if flag?(:linux) || flag?(:freebsd) || flag?(:openbsd) || flag?(:dragonfly) %}
        attr = uninitialized LibC::PthreadAttrT
        if LibC.pthread_getattr_np(LibC.pthread_self, pointerof(attr)) == 0
          stackaddr = Pointer(Void).null
          stacksize = LibC::SizeT.new(0)
          if LibC.pthread_attr_getstack(pointerof(attr), pointerof(stackaddr), pointerof(stacksize)) == 0 &&
             !stackaddr.null? && stacksize > 0
            lo = stackaddr.address
            hi = lo + stacksize.to_u64
            if sp_addr > lo && sp_addr <= hi
              on_thread_stack = true
              guard = lo + Roots::PAGE_SIZE
            end
          end
          LibC.pthread_attr_destroy(pointerof(attr))
        end
      {% elsif flag?(:darwin) %}
        if bounds = Platform.current_pthread_stack_bounds
          lo = bounds[0].address
          hi = bounds[1].address
          if sp_addr > lo && sp_addr <= hi
            on_thread_stack = true
            guard = lo + Roots::PAGE_SIZE
          end
        end
      {% end %}

      wipe = bytes
      unless on_thread_stack
        # Likely a Crystal fiber stack (not the pthread mapping). Cap wipe so
        # we do not walk into an unmapped/guard page on a thinly grown stack.
        wipe = FIBER_CLEAR_STACK_CAP if wipe > FIBER_CLEAR_STACK_CAP
        guard = high > wipe ? high - wipe : 0_u64
      end

      return if high <= guard
      return if sp_addr <= guard + skip

      low = high > wipe ? high - wipe : guard
      low = guard if low < guard
      return if low >= high

      len = high - low
      return if len == 0 || len > Roots::MAX_SCAN_BYTES

      Pointer(UInt8).new(low).clear(len)
      @clear_stack_bytes_total += len
      @clear_stack_calls += 1
    end

    # Zero a capped window below each parked fiber's saved SP — not the full
    # [guard, SP) span (that faults pages in and inflates RSS).
    #
    # EC1 (PERF): 4 KiB blind clear — same as v0.15 `bebedae`. Cuts false
    # stack roots (tip retained ~4× live_objects vs bebedae with 512 B +
    # clear_range_safe). Stack type_id_gate stays off (Channel/Deque SEGV).
    # Parallel: 512 B + clear_range_safe; skip when a foreign SP sits on the
    # fiber (mid-swap). 4 KiB×clear_range_safe on EC1 hurts thr (page probes).
    protected def scrub_parked_fiber_stacks : Nil
      return unless @scrub_fibers_enabled

      current = Fiber.current
      multi = multi_mutator_threads?
      wipe = @clear_stack_bytes
      if multi
        wipe = FIBER_CLEAR_STACK_CAP if wipe > FIBER_CLEAR_STACK_CAP
      else
        wipe = DEFAULT_CLEAR_STACK_BYTES if wipe > DEFAULT_CLEAR_STACK_BYTES
      end
      scrubbed = 0_u64
      Fiber.unsafe_each do |fiber|
        next if fiber == current
        next if fiber.running?
        # Mid-swap under Parallel: current_fiber already points at the next
        # fiber while SP (and live frames) remain on this "parked" stack.
        # EC1: SYSMON is suspended on its fiber during our STW — foreign-SP
        # skip would never scrub it. Only skip under Parallel.
        next if multi && fiber_stack_holds_foreign_sp?(fiber)

        stack = fiber.@stack
        base = stack.pointer.address
        bottom = stack.bottom.address
        next if base == 0 || bottom <= base + Roots::PAGE_SIZE

        guard = base + Roots::PAGE_SIZE
        top = fiber.@context.stack_top.address
        top = guard if top < guard
        next if top <= guard || top > bottom

        low = top > wipe ? top - wipe : guard
        low = guard if low < guard
        next if low >= top

        if multi
          scrubbed += Roots.clear_range_safe(low, top)
        else
          len = top - low
          next if len > Roots::MAX_SCAN_BYTES
          Pointer(UInt8).new(low).clear(len)
          scrubbed += len
        end
      end
      @fiber_scrub_bytes_total += scrubbed
      @fiber_scrub_runs += 1
    end

    # True when a suspended OS thread's SP still lies on *fiber*'s stack.
    private def fiber_stack_holds_foreign_sp?(fiber : Fiber) : Bool
      return false unless @world_stopped

      stack = fiber.@stack
      base = stack.pointer.address
      bottom = stack.bottom.address
      return false if bottom <= base

      current = Thread.current
      Thread.unsafe_each do |thread|
        next if thread == current
        sp = Platform.thread_sp(thread.to_unsafe)
        next unless sp
        spa = sp.address
        return true if spa >= base && spa < bottom
      end
      false
    end

    protected def maybe_clear_stack_on_alloc : Nil
      return unless @clear_stack_enabled
      return if @@clear_stack_active
      every = @clear_stack_every
      return if every <= 0
      @clear_stack_ops += 1
      return if every > 1 && (@clear_stack_ops % every.to_u64) != 0
      clear_stack(@clear_stack_bytes)
    end
  end

  def self.clear_stack(bytes : Int = 0) : Nil
    h = default_heap
    n = bytes > 0 ? bytes.to_u64 : h.clear_stack_bytes
    h.clear_stack(n)
  end
end
