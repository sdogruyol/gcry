# Boehm-style stack hygiene without compiler stack maps.
#
# clear_stack: zero unused words below SP so later root scans do not treat
# stale stack slots as live. scrub_parked_fibers: same for parked fiber stacks.
#
# Alloc-path: GCRY_CLEAR_STACK=1. Parked-fiber collect scrub: opt-in,
# GCRY_SCRUB_FIBERS=1 — it wipes below another fiber's *estimated* SP, which is
# a correctness question nothing measured has closed (docs/SOUND-DEFAULTS.md).
#
# The allocation-path wipe must not call Fiber/Thread APIs — those malloc
# during early Thread TLS publish and recurse into allocate. Its bounds come
# from pthread_getattr_np (thread stack) or a small capped wipe on fiber
# stacks. The collector's own scrub runs where `Fiber.current` is already in
# use (the stack scan), so it may take a fiber's real bounds.

module Gcry
  class Heap
    DEFAULT_CLEAR_STACK_BYTES = 4096_u64
    # Cap for a wipe whose stack bounds are unknown (the allocation-path wipe
    # on a fiber stack): fiber stacks start thinly mapped.
    # Parallel parked-fiber scrub default (override via GCRY_FIBER_SCRUB_BYTES).
    FIBER_CLEAR_STACK_CAP = 512_u64

    property clear_stack_enabled : Bool = false
    property clear_stack_bytes : UInt64 = DEFAULT_CLEAR_STACK_BYTES
    # When > 1, only every Nth allocate calls clear_stack (thr trade-off).
    property clear_stack_every : Int32 = 1
    property scrub_fibers_enabled : Bool = false
    # GCRY_SCRUB_AUDIT=1 — probe whether the parked-fiber wipe ever lands on a
    # stack an OS thread is still running on. Off by default; the probe walks
    # every thread per parked fiber.
    #
    # What the probe sees: `Platform.thread_sp` is populated by the STW suspend
    # signal handler, so on its own it knows about *signal-suspended* threads
    # only. The EC Monitor (SYSMON) is signal-exempt (`stw_signal_exempt?`) and
    # cooperates via @world_stopped, so its SP is never recorded there — and
    # SYSMON is precisely the thread the EC1 exemption is about, which left this
    # audit structurally blind to the shape it exists to test.
    #
    # With the audit on, `fiber_stack_foreign_sp` falls back to a /proc snapshot
    # (`Platform.audit_snapshot_sps`), which reads every thread's SP without a
    # signal. The guard path is unchanged — this only widens what the *probe*
    # can observe.
    property scrub_audit_foreign_sp : Bool = false

    # Research only: stop skipping fibers a suspended thread's SP sits on.
    # That skip is the mid-swap safety guard under Parallel; disabling it is
    # how the audit gets a positive control — a run where the counters are
    # expected to move, proving they can. Do not ship with this off.
    property scrub_skip_foreign_sp : Bool = true
    # Parallel multi-mutator parked-fiber wipe size (bytes below saved SP).
    property fiber_scrub_bytes : UInt64 = FIBER_CLEAR_STACK_CAP

    # Research only — GCRY_SCRUB_OVERSHOOT=<bytes>, default 0. Slides the wipe
    # window above `stack_top`, into frames that should be live. It exists to
    # give the scrub audit a positive control: a run that is *expected* to
    # corrupt, so a clean run at overshoot 0 means something. **Never ship
    # non-zero** — this deliberately destroys live data.
    property scrub_overshoot_bytes : UInt64 = 0_u64

    # Research only, default nil — treat this one fiber as parked even though it
    # reports `running?`, so the mid-swap state can be manufactured: a stale
    # `stack_top` with a thread still on the stack below it. That is the state
    # `scrub_skip_foreign_sp` exists for and which no workload has produced, so
    # without it the guard cannot be observed doing anything.
    #
    # It is a heap property, and not `bench/` reaching in to flip the fiber's own
    # `Context.resumable`, because that lies to Crystal's scheduler too: the
    # fiber reads back *resumable*, so a worker may legitimately decide to resume
    # a stack another thread is running on. Measured, doing it that way hung
    # 1 run in 26 inside STW. Here the lie exists only inside
    # `scrub_parked_fiber_stacks`, with the world already stopped, so nothing but
    # the scrub can observe it. **Never ship non-nil.**
    property scrub_force_parked : Fiber? = nil

    getter clear_stack_bytes_total : UInt64 = 0_u64
    getter fiber_scrub_bytes_total : UInt64 = 0_u64
    getter clear_stack_calls : UInt64 = 0_u64
    getter fiber_scrub_runs : UInt64 = 0_u64
    # Audit counters (GCRY_SCRUB_AUDIT=1). `overlaps` is the one that decides
    # the knob: non-zero means the wipe zeroed memory at or above a suspended
    # thread's SP — live frames — which is the failure mode the whole
    # root-completeness argument against scrub_fibers rests on.
    getter fiber_scrub_foreign_sp_scrubs : UInt64 = 0_u64
    getter fiber_scrub_live_frame_overlaps : UInt64 = 0_u64
    # Fibers that hold a foreign thread's SP but were skipped as `running?`
    # before any scrub logic ran. This separates the two readings of a zero
    # above: "no thread's stack was ever in scrub range" (what we want to
    # conclude) from "the thread's fiber was excluded earlier for an unrelated
    # reason" (which would make the zero say nothing about the wipe).
    getter fiber_scrub_running_foreign_sp : UInt64 = 0_u64
    # Times the mid-swap guard actually fired: a fiber reporting parked with a
    # foreign thread's SP still on its stack, skipped instead of wiped. Without
    # this the guard is invisible — `overlaps == 0` from a guarded run cannot be
    # told apart from "the guard never had anything to do", which is exactly the
    # unreadable zero `fiber_scrub_running_foreign_sp` exists to prevent one
    # branch earlier. `bench/scrub_midswap.cr` reads it.
    getter fiber_scrub_midswap_skips : UInt64 = 0_u64

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

    # Bytes of dead stack zeroed below the SP at every collection entry
    # (`GCRY_COLLECT_SCRUB`, 0 disables). The previous collection's mark frames
    # are still intact below the mutator's SP, and they are dense with block
    # addresses: mark-stack batches, the prefetch ring, `find_block` results.
    # The next collection's scan chain pushes frames over that region and then
    # scans it, so every slot a frame does not write reads as last cycle's
    # heap pointer and is accepted as a root. Under `-Dgcry_headerless` a
    # block's address *is* its user pointer, so `base_only` accepts them; the
    # header build only escaped because the same residue was header-valued.
    # Measured: 2.1k stale seeds retaining a 74k-object web on gc_phases.
    property collect_scrub_bytes : UInt64 = 16384_u64

    # Accounted apart from `clear_stack_calls`, which means the allocation-path
    # wipe (`GCRY_CLEAR_STACK`) and would otherwise count every collection.
    getter collect_scrub_runs : UInt64 = 0_u64
    getter collect_scrub_bytes_total : UInt64 = 0_u64

    # Zero unused stack below the hardware SP (stack grows down).
    def clear_stack(bytes : UInt64 = @clear_stack_bytes) : Nil
      len = clear_stack_guarded(bytes, fiber_bounds: false)
      return if len == 0
      @clear_stack_bytes_total += len
      @clear_stack_calls += 1
    end

    # The collector's own entry/exit scrub; see `run_collection`.
    protected def collect_scrub : Nil
      len = clear_stack_guarded(@collect_scrub_bytes, fiber_bounds: true)
      return if len == 0
      @collect_scrub_bytes_total += len
      @collect_scrub_runs += 1
    end

    # Bytes zeroed, 0 when nothing was (disabled, re-entered, or no room).
    private def clear_stack_guarded(bytes : UInt64, fiber_bounds : Bool) : UInt64
      return 0_u64 if bytes == 0
      return 0_u64 if @@clear_stack_active
      @@clear_stack_active = true
      begin
        clear_stack_body(bytes, fiber_bounds)
      ensure
        @@clear_stack_active = false
      end
    end

    private def clear_stack_body(bytes : UInt64, fiber_bounds : Bool) : UInt64
      # Must use hardware SP — Roots.stack_pointer is mid-frame and wiping
      # up to it corrupts the leaf (null-deref SEGV on aarch64 CI).
      sp_addr = Roots.hardware_stack_pointer.address
      skip = CLEAR_STACK_RED_ZONE + CLEAR_STACK_LEAF_MARGIN
      return 0_u64 if sp_addr <= skip

      high = sp_addr - skip
      guard = 0_u64
      bounds_known = false

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
              bounds_known = true
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
            bounds_known = true
            guard = lo + Roots::PAGE_SIZE
          end
        end
      {% end %}

      if !bounds_known && fiber_bounds
        # A Crystal fiber stack: the fiber knows its own bounds, so the wipe
        # can stop at its guard page like the pthread case above. Only the
        # collector's scrub asks (see the file comment).
        stack = Fiber.current.@stack
        lo = stack.pointer.address
        hi = stack.bottom.address
        if lo < hi && sp_addr > lo && sp_addr <= hi
          bounds_known = true
          guard = lo + Platform.host_page_size
        end
      end

      wipe = bytes
      unless bounds_known
        # Unknown stack. Cap wipe so we do not walk into an unmapped/guard
        # page on a thinly grown stack.
        wipe = FIBER_CLEAR_STACK_CAP if wipe > FIBER_CLEAR_STACK_CAP
        guard = high > wipe ? high - wipe : 0_u64
      end

      return 0_u64 if high <= guard
      return 0_u64 if sp_addr <= guard + skip

      low = high > wipe ? high - wipe : guard
      low = guard if low < guard
      return 0_u64 if low >= high

      len = high - low
      return 0_u64 if len == 0 || len > Roots::MAX_SCAN_BYTES

      Pointer(UInt8).new(low).clear(len)
      len
    end

    # Zero a capped window below each parked fiber's saved SP — not the full
    # [guard, SP) span (that faults pages in and inflates RSS).
    #
    # EC1 (PERF): 4 KiB blind clear — same as v0.15 `bebedae`. Cuts false
    # stack roots (tip retained ~4× live_objects vs bebedae with 512 B +
    # clear_range_safe). Stack type_id_gate stays off (Channel/Deque SEGV).
    # Parallel: fiber_scrub_bytes (default 512) + clear_range_safe; skip when a
    # foreign SP sits on the fiber (mid-swap). 4 KiB×clear_range_safe on EC1
    # hurts thr (page probes).
    protected def scrub_parked_fiber_stacks : Nil
      return unless @scrub_fibers_enabled

      current = Fiber.current
      multi = multi_mutator_threads?
      wipe = @clear_stack_bytes
      if multi
        # Parallel: dedicated cap (default 512). Not clamped by clear_stack_bytes.
        wipe = @fiber_scrub_bytes
        wipe = FIBER_CLEAR_STACK_CAP if wipe == 0
      else
        wipe = DEFAULT_CLEAR_STACK_BYTES if wipe > DEFAULT_CLEAR_STACK_BYTES
      end
      # One /proc pass per scrub run, not per fiber. Fills a preallocated table
      # so the per-fiber check below costs a scan of an array.
      {% if flag?(:linux) %}
        Platform.audit_snapshot_sps if @scrub_audit_foreign_sp
      {% end %}

      scrubbed = 0_u64
      forced = @scrub_force_parked
      Fiber.unsafe_each do |fiber|
        next if fiber == current
        if fiber.running? && !(forced && fiber.same?(forced))
          # Audit only: a running fiber is never scrubbed, but we need to know
          # whether it is where the foreign SPs actually live — otherwise a zero
          # from the counters below is unreadable.
          {% if flag?(:linux) %}
            if @scrub_audit_foreign_sp
              rstack = fiber.@stack
              rbase = rstack.pointer.address
              rbottom = rstack.bottom.address
              if rbase != 0 && rbottom > rbase && Platform.audit_sp_within(rbase, rbottom)
                @fiber_scrub_running_foreign_sp += 1
              end
            end
          {% end %}
          next
        end
        # Mid-swap under Parallel: current_fiber already points at the next
        # fiber while SP (and live frames) remain on this "parked" stack.
        # Only skip under Parallel.
        #
        # The EC1 exemption used to be justified as "SYSMON is suspended on its
        # fiber during our STW, so the foreign-SP skip would never scrub it".
        # `bench/scrub_audit.cr` measured that and it is not what happens:
        # SYSMON's fiber reports `running?` at every collection (200/200 at EC1,
        # 1170 sightings at EC4), so it is excluded above, before any of this
        # runs. The exemption is harmless, but it is not what protects that
        # stack — the `running?` check is. See docs/SOUND-DEFAULTS.md.
        #
        # That EC1 exemption is a throughput argument for not applying a safety
        # check, so GCRY_SCRUB_AUDIT=1 measures what it costs instead of leaving
        # it to reasoning: it counts the fibers scrubbed with a foreign SP on
        # them, and — the number that decides it — how often the wipe window
        # reaches at or above that SP, i.e. over live frames. Off by default:
        # the probe walks every thread per parked fiber.
        foreign_sp = nil
        if multi || @scrub_audit_foreign_sp
          foreign_sp = fiber_stack_foreign_sp(fiber)
          if multi && foreign_sp && @scrub_skip_foreign_sp
            @fiber_scrub_midswap_skips += 1
            next
          end
        end

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

        # Research only (GCRY_SCRUB_OVERSHOOT, default 0). Slide the window *up*
        # by N bytes, deliberately over `stack_top` and into what should be live
        # frames.
        #
        # This exists because the open half of the scrub question cannot be
        # observed directly: for a genuinely parked fiber, `@context.stack_top`
        # is the only record of its SP, so there is nothing independent to check
        # the window against. What can be done is locate the boundary — if the
        # shipping window (overshoot 0) never breaks and a small overshoot
        # always does, that is a positive control for the instrument *and* a
        # measurement of the margin. A harness that can only ever report "no
        # crash" is the thing this repo already refused once, in scrub_audit.
        if (over = @scrub_overshoot_bytes) > 0
          low += over
          top += over
          top = bottom if top > bottom
          next if low >= top
        end

        if fsp = foreign_sp
          @fiber_scrub_foreign_sp_scrubs += 1
          # Live frames occupy [sp, bottom). The wipe covers [low, top), so it
          # is harmless only while the whole window sits strictly below sp.
          @fiber_scrub_live_frame_overlaps += 1 if top > fsp
        end

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

    # A suspended OS thread's SP that lies on *fiber*'s stack, or nil. The
    # address, not a bool, because the audit needs to know where the live
    # frames start — "a foreign SP is somewhere on this stack" does not say
    # whether the wipe window reaches it.
    private def fiber_stack_foreign_sp(fiber : Fiber) : UInt64?
      return nil unless @world_stopped

      stack = fiber.@stack
      base = stack.pointer.address
      bottom = stack.bottom.address
      return nil if bottom <= base

      current = Thread.current
      Thread.unsafe_each do |thread|
        next if thread == current
        sp = Platform.thread_sp(thread.to_unsafe)
        next unless sp
        spa = sp.address
        return spa if spa >= base && spa < bottom
      end

      # Audit path: the loop above can only see signal-suspended threads, and
      # the EC Monitor is signal-exempt — which is exactly the thread the EC1
      # scrub exemption is about. Fall back to the /proc snapshot so the probe
      # is not blind to the one shape it exists to test.
      {% if flag?(:linux) %}
        if @scrub_audit_foreign_sp
          return Platform.audit_sp_within(base, bottom)
        end
      {% end %}

      nil
    end

    # True when a suspended OS thread's SP still lies on *fiber*'s stack.
    private def fiber_stack_holds_foreign_sp?(fiber : Fiber) : Bool
      !fiber_stack_foreign_sp(fiber).nil?
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
