# Boehm-style stack hygiene without compiler stack maps.
#
# clear_stack: zero unused words below SP so later root scans do not treat
# stale stack slots as live. scrub_parked_fibers: same for parked fiber stacks.
#
# Opt-in: GCRY_CLEAR_STACK=1, GCRY_SCRUB_FIBERS=1 (process dogfood).
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
      CLEAR_STACK_RED_ZONE = 128_u64
    {% else %}
      CLEAR_STACK_RED_ZONE = 0_u64
    {% end %}

    # Zero unused stack below the approximate SP (stack grows down).
    # Skip the ABI red zone immediately below SP — clearing it corrupts the
    # current leaf frame (x86_64 SysV: 128 bytes).
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
      sp_addr = Roots.stack_pointer.address
      return if sp_addr <= CLEAR_STACK_RED_ZONE

      high = sp_addr - CLEAR_STACK_RED_ZONE
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
      {% end %}

      wipe = bytes
      unless on_thread_stack
        # Likely a Crystal fiber stack (not the pthread mapping). Cap wipe so
        # we do not walk into an unmapped/guard page on a thinly grown stack.
        wipe = FIBER_CLEAR_STACK_CAP if wipe > FIBER_CLEAR_STACK_CAP
        guard = high > wipe ? high - wipe : 0_u64
      end

      return if high <= guard
      return if sp_addr <= guard + CLEAR_STACK_RED_ZONE

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
    # [guard, SP) span (that faults in multi-MiB stacks and inflates RSS).
    protected def scrub_parked_fiber_stacks : Nil
      return unless @scrub_fibers_enabled

      current = Fiber.current
      wipe = @clear_stack_bytes
      wipe = DEFAULT_CLEAR_STACK_BYTES if wipe > DEFAULT_CLEAR_STACK_BYTES
      scrubbed = 0_u64
      Fiber.unsafe_each do |fiber|
        next if fiber == current
        next if fiber.running?

        stack = fiber.@stack
        guard = stack.pointer.address + Roots::PAGE_SIZE
        top = fiber.@context.stack_top.address
        top = guard if top < guard
        next if top <= guard

        low = top > wipe ? top - wipe : guard
        low = guard if low < guard
        next if low >= top

        len = top - low
        next if len > Roots::MAX_SCAN_BYTES

        Pointer(UInt8).new(low).clear(len)
        scrubbed += len
      end
      @fiber_scrub_bytes_total += scrubbed
      @fiber_scrub_runs += 1
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
