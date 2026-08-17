# Root scanning: stacks, fibers, threads, static ranges, metadata.

module Gcry
  class Heap
    def push_stack(stack_top : Void*, stack_bottom : Void*) : Nil
      raise "push_stack outside of collect" unless @collecting
      # stack_top may sit on the PROT_NONE guard; cheap safe skips leading
      # unreadable pages then bulk-scans (see Roots.scan_range_safe).
      Roots.scan_range(stack_top, stack_bottom, safe: true) do |candidate|
        mark_root_candidate(candidate, source: RootSource::Parked)
      end
    end

    # Module-typed Reference ivars (Scheduler, ExecutionContext) cannot
    # `.as(Reference)` / `unsafe_as(Reference)` yet — load the pointer bits.
    #
    # The counter counts the slot, not the mark: a nil ivar is a slot the block
    # visited and found empty, and a gate that could not tell that from a slot
    # the block never looked at would be the same blind spot this counter exists
    # to remove.
    private def mark_ref_slot(slot_addr : UInt64) : Nil
      @ec_root_pins += 1
      bits = Pointer(UInt64).new(slot_addr).value
      return if bits == 0
      mark_root_candidate(Pointer(Void).new(bits), source: RootSource::Thread)
    end

    # An EC structure pinned by name rather than reached by scanning something
    # else. Counted so the pin block's engagement is readable from outside the
    # collector — see `ec_root_pins`.
    private def pin_ec_root(obj) : Nil
      @ec_root_pins += 1
      mark_root_candidate(Pointer(Void).new(obj.object_id), source: RootSource::Thread)
    end

    # Mark every word of one ivar slot. For anything that is not plainly a
    # `Reference`, guessing which word holds the pointer is worse than not
    # guessing: `@next : (Fiber::ExecutionContext | Nil)` is **16 bytes** on
    # Crystal 1.21.0 — a module union carries a type_id word — so pinning "the
    # pointer word" would pin the type_id and look covered. A `Proc` is 16 bytes
    # for the same practical reason (function, then closure environment).
    private def pin_ec_slot(slot_addr : UInt64, bytes : Int32) : Nil
      word = sizeof(Void*)
      if bytes < word
        # Pointer-bearing and narrower than a pointer: nothing sound to mark.
        # Cannot happen on 1.21.0; counted so it cannot happen quietly.
        @ec_root_unpinned_ivars += 1
        return
      end
      offset = 0
      while offset + word <= bytes
        mark_ref_slot(slot_addr + offset)
        offset += word
      end
    end

    # Pin every pointer-bearing ivar of an EC structure, derived from the type
    # itself rather than from a list of names written beside it. A list drifts:
    # upstream adds a queue, the block keeps pinning the four it was written
    # with, and nothing says otherwise — the shape of both v0.19.0 register gaps,
    # and the reason this item stayed open after `ec_root_pins` proved the block
    # *ran*. `instance_vars` cannot drift.
    #
    # Two outcomes per ivar, and no third one to forget about: a `Reference` is
    # one word, and anything else that can hold a pointer gets every word of its
    # slot marked. Values (`Int32`, `Bool`, `Atomic(Int32)`, an enum) are skipped
    # because `has_inner_pointers?` says there is nothing in them — the same
    # predicate `Layout.register` was fixed to ask on 2026-08-15.
    private macro pin_ec_ivars(obj, type)
      {% for ivar in type.resolve.instance_vars %}
        {% ty = ivar.type %}
        {% if ty < Reference %}
          mark_ref_slot(pointerof({{obj}}.@{{ivar.name}}).address)
        {% elsif ty.has_inner_pointers? %}
          pin_ec_slot(pointerof({{obj}}.@{{ivar.name}}).address, sizeof({{ty}}))
        {% end %}
      {% end %}
    end

    # Mark Thread objects and Parallel EC roots (TLS alone is not scanned).
    private def scan_thread_roots : Nil
      Thread.unsafe_each do |thread|
        mark_root_candidate(Pointer(Void).new(thread.object_id), source: RootSource::Thread)
        # Parallel EC can briefly have nil current_fiber while a worker OS
        # thread is between fibers / during shutdown — skip rather than raise.
        if fiber = thread.@current_fiber
          mark_root_candidate(Pointer(Void).new(fiber.object_id), source: RootSource::Thread)
        end
        if main = thread.@main_fiber
          mark_root_candidate(Pointer(Void).new(main.object_id), source: RootSource::Thread)
        end
        # Scheduler + ExecutionContext hold run queues / event-loop state. Relying
        # only on conservative Thread body scan missed them when layout/scan_cap
        # truncated the object (Kemal EC4 SEGV @ …0008).
        # Gate on the ivar itself: Crystal 1.21.0 release declares
        # @execution_context by default; tip needs -Dexecution_context
        # (-Dpreview_mt). Flag-only gates break one of the two.
        {% if Thread.instance_vars.any? { |v| v.name == "execution_context" } %}
          mark_ref_slot(pointerof(thread.@scheduler).address)
          mark_ref_slot(pointerof(thread.@execution_context).address)
        {% end %}
      end

      {% if Thread.instance_vars.any? { |v| v.name == "execution_context" } %}
        # Global EC list (not thread-local) — keeps contexts that temporarily have
        # no worker with them pinned via Thread.@execution_context.
        Fiber::ExecutionContext.unsafe_each do |ec|
          mark_ref_slot(pointerof(ec).address)
          # Pin each context's queues / event loop / schedulers explicitly. Body
          # scan alone still left residual EC4 SEGV @ …0008 under release Kemal.
          #
          # The *set of context types* is derived too, not just each type's
          # ivars: this named `Parallel` and nothing else, so an
          # `Fiber::ExecutionContext::Isolated` — which holds `@main_fiber`,
          # `@thread`, `@wait_list` and the user's `@func` closure — got no
          # explicit pin at all, and the block looked like it had run. Same
          # shape as the seven-name list it replaced, one level up.
          # Subclasses are listed before their parents so a `Concurrent` is
          # pinned with `Concurrent.instance_vars` rather than `Parallel`'s; it
          # adds none today, and a future one would be covered without an edit.
          {% ec_types = [] of Nil %}
          {% for includer in Fiber::ExecutionContext.includers %}
            {% for sub in includer.all_subclasses %}
              {% ec_types << sub %}
            {% end %}
            {% ec_types << includer %}
          {% end %}
          case ec
          {% for t in ec_types %}
          when {{t}}
            pin_ec_ivars(ec, {{t}})
            # Derived rather than named: a context that owns schedulers has an
            # `@schedulers` ivar, and each scheduler is a root in its own right.
            {% if t.instance_vars.any? { |v| v.name == "schedulers" } %}
              ec.@schedulers.each do |sched|
                pin_ec_root(sched)
                pin_ec_ivars(sched, Fiber::ExecutionContext::Parallel::Scheduler)
              end
            {% end %}
          {% end %}
          end
        end
      {% end %}

      audit_ec_queues
    end

    # ── Execution-context queue audit ─────────────────────────────────────────
    #
    # The 2026-08-10 soak died in `Parallel::Scheduler#quick_dequeue?` on
    # `0x7f1700000149` — a heap pointer with its low bytes overwritten — 1h24m
    # in. The dequeue is where the damage *surfaces*; the write that did it
    # happened an unknown time earlier, and at one crash per five hours the gap
    # cannot be bisected. This walks the two structures that dequeue reads —
    # each scheduler's `Runnables` ring between head and tail, and the context's
    # `GlobalQueue` list — and names the first *collection* at which a slot
    # stops being a live Fiber.
    #
    # It runs inside the stopped world, which is what makes it readable at all:
    # the queues are quiescent there, so a slot that fails the test failed it
    # before the world stopped rather than under the walk.
    #
    # Off by default (`GCRY_EC_QUEUE_AUDIT=1`) — it is a bounded walk (≤ ring
    # capacity per scheduler, plus the global list) but it is inside the pause.
    private def ec_queue_slot_live_fiber?(bits : UInt64) : Bool
      return false if bits == 0
      ptr = Pointer(Void).new(bits)
      return false unless is_heap_ptr(ptr)
      return false unless live?(ptr)
      # A queue slot holds a Fiber and nothing else, so the type_id is an exact
      # test rather than a plausibility one — which is the difference between
      # this and the conservative marking path.
      ptr.as(Int32*).value == Fiber.crystal_instance_type_id
    end

    private def audit_ec_queues : Nil
      return unless @ec_queue_audit
      {% if Thread.instance_vars.any? { |v| v.name == "execution_context" } %}
        Fiber::ExecutionContext.unsafe_each do |ec|
          # Which contexts have queues is asked of the types, not written down:
          # `Isolated` has neither a global queue nor schedulers and is skipped
          # for that reason rather than by name. A context type added upstream
          # with a queue is audited without an edit here.
          {% ec_types = [] of Nil %}
          {% for includer in Fiber::ExecutionContext.includers %}
            {% for sub in includer.all_subclasses %}
              {% ec_types << sub %}
            {% end %}
            {% ec_types << includer %}
          {% end %}
          case ec
          {% for t in ec_types %}
            {% has_queue = t.instance_vars.any? { |v| v.name == "global_queue" } %}
            {% has_scheds = t.instance_vars.any? { |v| v.name == "schedulers" } %}
            {% if has_queue || has_scheds %}
          when {{t}}
              # Before the slots, the structures that hold them. The standing
              # reading of the 2026-08-10 SEGV is that a slot was freed and
              # reused while the scheduler still pointed at it — and the object
              # that holds the slots can be reissued the same way, in which case
              # a slot walk reads a head, a tail and a ring out of whatever the
              # block became and reports nothing, because everything it finds is
              # garbage rather than a bad Fiber.
              audit_ec_structs(ec, {{t}})
              {% if has_queue %}
                # Only walk a container that is still that container. The report
                # from `audit_ec_structs` already named it; walking it anyway
                # would bury that line under a ring's worth of garbage slots,
                # which is what the first run of this gate did.
                if ec_struct_ok?(pointerof(ec.@global_queue).as(UInt64*).value,
                     typeof(ec.@global_queue).crystal_instance_type_id)
                  audit_ec_global_queue(ec.@global_queue)
                end
              {% end %}
              {% if has_scheds %}
                ec.@schedulers.each_with_index do |sched, i|
                  audit_ec_structs(sched, Fiber::ExecutionContext::Parallel::Scheduler)
                  if ec_struct_ok?(pointerof(sched.@runnables).as(UInt64*).value,
                       typeof(sched.@runnables).crystal_instance_type_id)
                    audit_ec_runnables(sched.@runnables, i)
                  end
                end
              {% end %}
            {% end %}
          {% end %}
          end
        end
      {% end %}
    end

    # Is `bits` a live object of exactly type `type_id`? Same three questions as
    # a queue slot, with the type it must be passed in rather than fixed to
    # Fiber.
    private def ec_struct_ok?(bits : UInt64, type_id : Int32) : Bool
      return false if bits == 0
      ptr = Pointer(Void).new(bits)
      # Outside the heap is not a fault: a `String` literal — every context's
      # `@name` — lives in the program image, and gcry never sweeps what it did
      # not allocate. It is also the limit of this check, and worth stating: a
      # wild pointer that happens to land outside the heap passes here. Only
      # objects the collector manages can be swept, so only those are the
      # question. (Measured the hard way: without this, every collection
      # reported `Parallel@name` as corrupt.)
      return true unless is_heap_ptr(ptr)
      return false unless live?(ptr)
      ptr.as(Int32*).value == type_id
    end

    # Check every ivar of an EC structure whose declared type is a **concrete**
    # Reference class, i.e. every one whose runtime type_id is known at compile
    # time. Abstract and module-typed ivars (`@event_loop : Crystal::EventLoop`)
    # are skipped rather than guessed at: their runtime type is a subclass and
    # there is no single id to compare against. Derived from `instance_vars` for
    # the same reason the pins are — a structure added upstream is checked
    # without an edit here.
    #
    # This is the check that would name a *reissued* structure. The slot walks
    # cannot: if a `Runnables` block is freed and reused, its head, tail and ring
    # are whatever the new owner wrote, and a walk over them finds garbage
    # everywhere rather than a slot that stopped being a Fiber.
    private macro audit_ec_structs(obj, type)
      {% for ivar in type.resolve.instance_vars %}
        {% ty = ivar.type %}
        {% if ty < Reference && !ty.abstract? %}
          unless ec_struct_ok?(pointerof({{obj}}.@{{ivar.name}}).as(UInt64*).value,
                   {{ty}}.crystal_instance_type_id)
            @ec_queue_audit_faults += 1
            @ec_queue_audit_last_fault = pointerof({{obj}}.@{{ivar.name}}).as(UInt64*).value
            EcQueueAudit.report_struct({{type.resolve.name.stringify}}, {{ivar.name.stringify}},
              pointerof({{obj}}.@{{ivar.name}}).as(UInt64*).value)
          end
        {% end %}
      {% end %}
    end

    # No macro gate on these two: `instance_vars` cannot be called at class-body
    # scope, and none is needed. They take untyped parameters, so a compiler
    # without execution contexts never instantiates them — the only call site is
    # inside the gate above.
    private def audit_ec_runnables(runnables, scheduler_index : Int32) : Nil
      capacity = runnables.capacity.to_u32
      head = runnables.@head.get(:relaxed)
      tail = runnables.@tail.get(:relaxed)
      # head and tail are a wrapping pair, so the size is their difference. A
      # difference past capacity is itself corruption; clamp so the walk cannot
      # run away, and let the slots it does read report what they are.
      size = tail &- head
      count = size > capacity ? capacity : size
      # `pointerof`, not `.to_unsafe`: reading the ivar would copy the whole
      # ring (N Fiber-sized words) into a temporary first.
      base = pointerof(runnables.@buffer).as(UInt64*)
      i = 0_u32
      while i < count
        slot = (head &+ i) % capacity
        bits = base[slot]
        @ec_queue_audit_ring_slots += 1
        unless ec_queue_slot_live_fiber?(bits)
          @ec_queue_audit_faults += 1
          @ec_queue_audit_last_fault = bits
          EcQueueAudit.report(EcQueueAudit::KIND_RUNNABLES, scheduler_index, slot, bits)
        end
        i += 1
      end
    end

    private def audit_ec_global_queue(queue) : Nil
      size = queue.@list.size
      return if size <= 0
      bits = pointerof(queue.@list.@head).as(UInt64*).value
      walked = 0_u32
      # Bounded twice: by the list's own size (plus slack, since the size
      # itself could be the corrupt word) and by a hard cap against a cycle.
      limit = size > 65_536 ? 65_536_u32 : (size.to_u32 &+ 8_u32)
      while bits != 0 && walked < limit
        @ec_queue_audit_list_slots += 1
        unless ec_queue_slot_live_fiber?(bits)
          @ec_queue_audit_faults += 1
          @ec_queue_audit_last_fault = bits
          EcQueueAudit.report(EcQueueAudit::KIND_GLOBAL_LIST, -1, walked, bits)
          # The chain cannot be followed past a node that is not a Fiber.
          return
        end
        bits = Pointer(UInt64).new(bits &+ offsetof(Fiber, @list_next).to_u64).value
        walked &+= 1
      end
    end

    # Spill GP registers, then scan approx SP→bottom for the running fiber.
    private def scan_mutator_stack : Nil
      bottom = Fiber.current.@stack.bottom
      @stack_bottom = bottom
      if @precise_stack_exclusive
        # Exclusive: no full SP→bottom word scan (RSS experiment). Still need
        # setjmp regs + a shallow window for LLVM spill slots in active frames;
        # stackmaps cover call-site lives via FP walk below.
        Roots.each_spilled_register do |candidate|
          mark_root_candidate(candidate, source: RootSource::Stack)
        end
        scan_exclusive_mutator_spill_window(bottom)
      else
        Roots.scan_mutator(bottom) do |candidate|
          note_mutator_candidate(candidate.address)
          mark_root_candidate(candidate, source: RootSource::Stack)
        end
      end
      scan_precise_mutator_stack(bottom)
    end

    # Below SP (+ red zone): catch LLVM spill slots maps/FP walk miss without
    # scanning the whole fiber high-water (exclusive's RSS point). 4 KiB was
    # too shallow under acik --release (ThreadPool UAF / collect hang); 16 KiB
    # still << full stack.
    EXCLUSIVE_MUTATOR_SPILL_WINDOW = 16_u64 * 1024

    private def scan_exclusive_mutator_spill_window(bottom : Void*) : Nil
      red = STACK_SCAN_RED_ZONE.to_u64
      sp = Roots.hardware_stack_pointer.address
      win = EXCLUSIVE_MUTATOR_SPILL_WINDOW
      low = sp > (red &+ win) ? sp - red - win : 0_u64
      hi = bottom.address
      return unless low < hi
      Roots.scan_range(Pointer(Void).new(low), bottom, safe: true) do |candidate|
        mark_root_candidate(candidate, source: RootSource::Stack)
      end
    end

    # Precise roots from `.llvm_stackmaps`. Hybrid (=1): capped mutator FP
    # walk (conservative still covers the stack; other-thread leaf needs
    # Parallel EC gregs). Exclusive (=2): full FP walk, no word scan.
    private def scan_precise_mutator_stack(bottom : Void*) : Nil
      return unless @precise_stack_roots
      return unless StackMaps.ensure_loaded

      {% if flag?(:x86_64) || flag?(:aarch64) %}
        rsp = Roots.hardware_stack_pointer.address
        rbp = uninitialized UInt64
        {% if flag?(:x86_64) %}
          asm("movq %rbp, $0" : "=r"(rbp) :: "volatile")
        {% else %}
          asm("mov $0, x29" : "=r"(rbp) :: "volatile")
        {% end %}
        lo = rsp > STACK_SCAN_RED_ZONE ? rsp - STACK_SCAN_RED_ZONE : 0_u64
        hi = bottom.address
        max_frames = @precise_stack_exclusive ? StackMaps::MAX_FP_FRAMES : StackMaps::HYBRID_MAX_FP_FRAMES
        StackMaps.each_root_fp_walk(rsp, rbp, lo, hi, max_frames) do |ptr|
          mark_precise_root(ptr)
        end
      {% end %}
    end

    private def scan_precise_thread_stack(pthread : LibC::PthreadT, stack_lo : UInt64, stack_hi : UInt64) : Nil
      return unless @precise_stack_roots
      return unless StackMaps.loaded? || StackMaps.ensure_loaded

      {% if flag?(:linux) && flag?(:x86_64) %}
        Platform.with_thread_gregs(pthread) do |gregs, n|
          return if n < 17
          # glibc: REG_RBP=10, REG_RSP=15, REG_RIP=16
          rbp = gregs[10]
          rsp = gregs[15]
          rip = gregs[16]
          lo = stack_lo
          hi = stack_hi
          StackMaps.each_root_near(rip, rsp, rbp, gregs, n, lo, hi) do |ptr|
            mark_precise_root(ptr)
          end
          if @precise_stack_exclusive && lo < hi
            StackMaps.each_root_fp_walk(rsp, rbp, lo, hi) do |ptr|
              mark_precise_root(ptr)
            end
          end
        end
      {% end %}
    end

    # Precise roots for a parked fiber (x86_64-sysv swapcontext layout).
    # Uses synthetic gregs + RSP@ret; skips FP walk when RBP not on-stack
    # (makecontext / never-started fibers).
    private def scan_precise_parked_fiber(fiber : Fiber, guard : UInt64, bottom : UInt64) : Nil
      return unless @precise_stack_roots
      return unless StackMaps.loaded? || StackMaps.ensure_loaded

      {% if flag?(:x86_64) || flag?(:aarch64) %}
        top = fiber.@context.stack_top.address
        min_spill = {% if flag?(:aarch64) %} StackMaps::PARKED_AARCH64_SPILL_WORDS * 8 {% else %} 64 {% end %}
        return unless top >= guard && (top &+ min_spill) <= bottom

        max_frames = @precise_stack_exclusive ? StackMaps::MAX_FP_FRAMES : StackMaps::HYBRID_MAX_FP_FRAMES
        StackMaps.each_root_parked_sysv(top, guard, bottom, max_frames) do |ptr|
          mark_precise_root(ptr)
        end
      {% end %}
    end

    # True when more than the usual main + ExecutionContext Monitor threads
    # exist. Parallel EC workers and Thread.new storms need aggressive STW
    # stack scans; EC1/default must keep the cheap stack_top clamp or Kemal
    # /json thr collapses (~78%→~48% Boehm on CI after always-full-scan).
    private def multi_mutator_threads? : Bool
      n = 0
      Thread.unsafe_each do
        n += 1
        return true if n > 2
      end
      false
    end

    # For `Invariant`: its walks are snapshots, and the counters they compare
    # against are bumped by whichever thread allocates. With another mutator
    # running the two are sampled at different instants and disagree by the
    # allocations in flight — a race, not a drift.
    def concurrent_mutators? : Bool
      # Deliberately *not* consulting the staging record. A staged id says a
      # thread was created; it is cleared only when a collection drains it, and
      # nothing clears it when the thread dies — so "staged and not in the list"
      # covers the birth window and every dead thread since, and a check that
      # skips forever is worse than one that races.
      multi_mutator_threads?
    end

    # Can this heap's counters lose an update outright? `note_alloc_bytes` uses
    # plain get/set unless `heap_counters_atomic` is set, so two threads doing
    # `set(get + 1)` at once drop one increment **permanently** — not a sampling
    # race, a counter that is now wrong and stays wrong.
    #
    # `heap.cr` calls that trade-off safe on the grounds of "single mutator +
    # rare SYSMON", and this is the measurement against it: with the invariant
    # checker on, the process heap drifts in 3 runs of 40, `actual` one above
    # `reported`, with no thread in the program but main and the monitor
    # (`spec/invariant_spec.cr`). So the counter equals the walk only on a heap
    # that either has one thread near it or counts atomically, and stating the
    # invariant anywhere else is stating it of a heap that does not maintain it.
    def counters_may_lose_updates? : Bool
      return false if @heap_counters_atomic
      n = 0
      Thread.unsafe_each do
        n += 1
        return true if n > 1
      end
      false
    end

    # Empty-chunk reclaim after major.
    # - EC1: dormant (DONTNEED within retain) + munmap excess (default).
    # - Parallel default: no empty reclaim (munmap amplified soft realloc;
    #   dormant-all cuts RSS ~3× but thr ~25%). Opt in:
    #   GCRY_PARALLEL_DORMANT=1 — DONTNEED within empty_chunk_retain (bounded);
    #   GCRY_PARALLEL_DORMANT_ALL=1 — DONTNEED every empty (legacy RSS max);
    #   GCRY_PARALLEL_RELEASE=1 — unsupported munmap excess (can hang/soft).
    property parallel_empty_chunk_dormant : Bool = false
    property parallel_empty_chunk_dormant_all : Bool = false
    property parallel_empty_chunk_munmap : Bool = false
    # Finish STW before size-class reclaim so pause excludes O(heap) sweep.
    # Mutators resume; sweep holds per-class freelist locks (safe only when
    # world is running — STW must not take those locks). Default on for
    # Parallel reclaim-off; escape GCRY_DISABLE_LAZY_SWEEP=1.
    property lazy_sweep : Bool = true

    private def release_empty_chunks_this_collect? : Bool
      return false unless @release_empty_chunks
      return true unless multi_mutator_threads?
      @parallel_empty_chunk_dormant || @parallel_empty_chunk_munmap
    end

    # Post-STW sweep: freelist locks serialize alloc into the class being
    # swept (TLAB-off).
    #
    # Parallel: dormant-only empty reclaim (chunks stay linked). Post-STW
    # munmap of excess empties was REJECT'd (SEGV + thr cliff; FINDINGS
    # munmap-lazy) — keep that gate.
    #
    # EC1: allow post-STW sweep **with** munmap pending-list (pause excludes
    # O(heap) walk). Sole mutator rebuilds `@chunks`; other threads (SYSMON)
    # spin via `@block_other_heap` during the post-STW section.
    private def sweep_after_world? : Bool
      return false unless @lazy_sweep
      return false if @tlab_enabled
      return false if @madvise_free_pages
      unless multi_mutator_threads?
        return true
      end
      return false if munmap_empty_chunks_this_collect?
      true
    end

    # EC1 post-STW: rebuild `@chunks` so munmap drops leave the list (Parallel
    # after_world must not — map_chunk races).
    private def relink_chunks_after_world? : Bool
      !multi_mutator_threads?
    end

    private def munmap_empty_chunks_this_collect? : Bool
      return false unless @release_empty_chunks
      !multi_mutator_threads? || @parallel_empty_chunk_munmap
    end

    # How far below parked stack_top to scan under multi-mutator STW.
    # Full guard→bottom × N fibers faults/scans historical high-water and
    # dominated EC4 phase_roots (~100ms+/collect). Mid-swap frames with SP on
    # the stack are covered by fiber_stack_sp_scan_low / scan_other_thread_stacks;
    # this lag catches stack_top that lags without a visible SP. Override via
    # GCRY_STW_STACK_LAG (bytes; 0 = full guard→bottom). Default 256 KiB
    # (2026-08-01 A/B: soft 0/40; quiet thr ≥ 512 KiB default).
    property stw_multi_stack_lag : UInt64 = 256_u64 * 1024

    # Skip the never-written head of a parked fiber stack — on *both* the lag-0
    # and the lag>0 default path (GCRY_STACK_LOW_WATER=0 to disable).
    # Semantics-preserving: pages with neither the present nor the swapped bit
    # set have never been faulted, so they are zero and cannot hold a pointer.
    # Linux-only; falls back to the unskipped range whenever
    # /proc/self/pagemap cannot answer, so a failure only ever widens the scan.
    property stack_low_water_scan : Bool = true

    # When suspend SP sits on a pool fiber, Parallel still scans the OS pthread
    # mapping for leftover scheduler frames. Full map (often ~8 MiB × N) dominates
    # phase_stacks after fiber-scan dedupe. Scan only the top *lag* bytes from
    # stack high (grows down). Override via GCRY_STW_PTHREAD_LAG; 0 = full map.
    # Default 256 KiB (2026-08-01: soft 0/40; stacks ~7→~0.4 ms; thr ≥ 71.5% cut).
    property stw_multi_pthread_lag : UInt64 = 256_u64 * 1024

    # One-shot stderr warning the first time a collect actually lands in the
    # shape where lag 0 is expensive. Boot is the wrong place to warn: `GCRY_SOUND=1`
    # sets lag 0 unconditionally, but the knob is *inert* until STW runs with more
    # than two mutator threads, and at EC1 the whole profile is throughput-neutral.
    # Warning at boot would cry wolf on the configuration that is fine.
    @warned_stw_lag_zero = false

    # Lowest scan address from a suspended thread SP on *fiber*, or nil.
    private def fiber_stack_sp_scan_low(fiber : Fiber, guard : UInt64) : UInt64?
      return nil unless @world_stopped

      stack = fiber.@stack
      base = stack.pointer.address
      bottom = stack.bottom.address
      return nil unless guard < bottom

      current = Thread.current
      Thread.unsafe_each do |thread|
        next if thread == current
        sp = Platform.thread_sp(thread.to_unsafe)
        next unless sp
        spa = sp.address
        next unless spa >= base && spa < bottom
        return stack_scan_low(spa, guard)
      end
      nil
    end

    private def fiber_stack_scan_top(fiber : Fiber, guard : UInt64, stw_multi : Bool) : UInt64
      if low = fiber_stack_sp_scan_low(fiber, guard)
        return low
      end

      if fiber.running?
        # Parallel: full span (mid-swap / stale stack_top). EC1: stack_top only
        # — full guard→bottom on SYSMON crushed Kemal thr (~86%→~80% Boehm).
        return guard if stw_multi
        t = fiber.@context.stack_top.address
        return t < guard ? guard : t
      end

      t = fiber.@context.stack_top.address
      t = guard if t < guard
      return t unless stw_multi

      lag = @stw_multi_stack_lag
      # 0 ⇒ classic full parked-fiber scan (correctness A/B; thr regresses).
      #
      # "Full" only has to mean every word that can hold a pointer. A fiber
      # stack is 8 MiB of reserved address space and ~0.05% of it is ever
      # written; the untouched remainder is provably zero, so starting at the
      # low-water mark instead of at `guard` sees exactly the same words for a
      # fraction of the faults. Falls back to `guard` whenever pagemap cannot
      # answer, so a failure can only ever widen the scan.
      if lag == 0
        {% if flag?(:linux) %}
          if @stack_low_water_scan
            bottom = fiber.@stack.bottom.address
            if bottom > guard
              lw = Platform.stack_low_water(guard, bottom)
              if lw > guard
                @low_water_skips += 1
                @low_water_skipped_bytes += lw - guard
                return lw
              end
              return guard
            end
          end
        {% end %}
        return guard
      end

      lagged = t > lag ? t - lag : guard
      lagged = guard if lagged < guard

      # The same skip, on the default path. The lag window is a *bound* on how
      # far below stack_top to look; it says nothing about whether those pages
      # were ever written, and on a fat app most of them were not — measured
      # 2026-08-09, tuned spent 20.4 ms of root work per large-heap collection
      # against sound's 11.4 ms, because lag 0 got this skip and lag 256 KiB did
      # not (`bench/log/linux/2026-08-09-071144-root-phase/FINDINGS.md`).
      #
      # Start at whichever is higher, the lag floor or the low-water mark. That
      # is never wider than the lag window and never narrower than what the
      # words can hold: everything skipped is a page with neither the present
      # nor the swapped bit, i.e. never faulted, i.e. zero. Probing is cheap
      # here in a way it is not at lag 0 — the live frames begin within `lag`
      # bytes of `lagged`, so the walk stops after ~lag/PAGE_SIZE entries (64
      # for the 256 KiB default), one pread.
      {% if flag?(:linux) %}
        if @stack_low_water_scan
          bottom = fiber.@stack.bottom.address
          if bottom > lagged
            lw = Platform.stack_low_water(lagged, bottom)
            if lw > lagged
              @low_water_skips += 1
              @low_water_skipped_bytes += lw - lagged
              lagged = lw
            end
          end
        end
      {% end %}
      lagged
    end

    # lag=0 used to mean scanning every parked fiber guard→bottom, ~8 MiB each:
    # 19× pause at Kemal EC4, 14.5× on a fat app past ~60 MiB (2026-08-06). The
    # low-water skip removed that — 13.9× → 1.03× on bench/stw_lag_pause.cr —
    # so the warning now fires only when the skip is not in play, which is the
    # only case still carrying the old cost.
    #
    # LibC.write, not STDERR: this runs inside STW and must not allocate.
    private def warn_stw_lag_zero_once : Nil
      return if @warned_stw_lag_zero
      {% if flag?(:linux) %}
        return if @stack_low_water_scan && Platform.pagemap_available?
      {% end %}
      @warned_stw_lag_zero = true
      msg = "gcry: WARNING: stw_multi_stack_lag=0 under multi-mutator STW without the " \
            "low-water skip — every parked fiber stack is scanned in full (measured 19× " \
            "pause at Parallel EC4, 14.5× on a large heap). Re-enable GCRY_STACK_LOW_WATER, " \
            "or set GCRY_STW_STACK_LAG. See docs/SOUND-DEFAULTS.md\n"
      LibC.write(2, msg.to_unsafe, LibC::SizeT.new(msg.bytesize))
    end

    private def scan_all_fiber_roots : Nil
      current = Fiber.current
      # Parallel / multi-thread STW: extend parked stack_top by LAG (and SP when
      # present). Single-mutator: cheap stack_top clamp (Kemal thr path).
      stw_multi = @world_stopped && multi_mutator_threads?
      warn_stw_lag_zero_once if stw_multi && @stw_multi_stack_lag == 0
      Fiber.unsafe_each do |fiber|
        mark_root_candidate(Pointer(Void).new(fiber.object_id), source: RootSource::Stack)
        next if fiber == current

        # Without STW we must not touch another thread's live stack.
        # Parallel STW: scan running fibers here too (current_fiber TLS can be
        # briefly nil). EC1: leave running stacks to scan_other_thread_stacks
        # (cheap SP/stack_top) — full dual-scan was thr-only cost.
        if fiber.running?
          next unless stw_multi
        end

        stack = fiber.@stack
        guard = stack.pointer.address + Roots::PAGE_SIZE
        bottom = stack.bottom.address
        next unless guard < bottom

        top = fiber_stack_scan_top(fiber, guard, stw_multi)
        next unless top < bottom

        # Precise walk of parked swapcontext frames (hybrid additive).
        unless fiber.running?
          scan_precise_parked_fiber(fiber, guard, bottom)
        end

        # Word scan:
        # - Hybrid: always.
        # - Exclusive default: full parked top→bottom.
        # - Exclusive + fibers_exclusive: LEAF window (default 8 KiB) plus
        #   optional FP-frame fill. LEAF=0 + fill-only misses stack slots
        #   outside tiny [rsp,fp) spans (stackmap_exclusive_fiber_smoke SEGV).
        if @precise_stack_exclusive
          next if fiber.running?
          if @precise_stack_fibers_exclusive
            scan_exclusive_parked_fiber_leaf(top, bottom)
            if @precise_stack_fiber_fp_fill
              filled = scan_exclusive_parked_fp_fill(fiber, guard, bottom)
              # No usable FP chain (makecontext / stale RBP) and no leaf →
              # full parked word-scan for this fiber (correctness floor).
              if !filled && @precise_stack_fiber_leaf_bytes == 0
                Roots.scan_range(Pointer(Void).new(top), Pointer(Void).new(bottom), safe: true) do |candidate|
                  mark_root_candidate(candidate, source: RootSource::Parked)
                end
              end
            elsif @precise_stack_fiber_leaf_bytes == 0
              # Pure maps, no fill, no leaf — research UAF path
              # (GCRY_DISABLE_FIBER_FP_FILL=1 + LEAF=0).
            end
          else
            Roots.scan_range(Pointer(Void).new(top), Pointer(Void).new(bottom), safe: true) do |candidate|
              mark_root_candidate(candidate, source: RootSource::Parked)
            end
          end
        else
          Roots.scan_range(Pointer(Void).new(top), Pointer(Void).new(bottom), safe: true) do |candidate|
            mark_root_candidate(candidate, source: RootSource::Parked)
          end
        end
      end
    end

    private def scan_exclusive_parked_fiber_leaf(top : UInt64, bottom : UInt64) : Nil
      win = @precise_stack_fiber_leaf_bytes
      return if win == 0
      hi = top &+ win
      hi = bottom if hi > bottom
      return unless top < hi
      Roots.scan_range(Pointer(Void).new(top), Pointer(Void).new(hi), safe: true) do |candidate|
        mark_root_candidate(candidate, source: RootSource::Parked)
      end
    end

    # Word-scan parked FP-chain frame bodies. Additive safety net with LEAF.
    # Default: every frame. Opt-in miss-only (GCRY_FIBER_FP_FILL_MISS_ONLY=1)
    # skips nonempty map hits — acik UAF. Returns true when the FP chain was
    # walkable (at least one frame yielded).
    private def scan_exclusive_parked_fp_fill(fiber : Fiber, guard : UInt64, bottom : UInt64) : Bool
      {% if flag?(:x86_64) || flag?(:aarch64) %}
        top = fiber.@context.stack_top.address
        min_spill = {% if flag?(:aarch64) %} StackMaps::PARKED_AARCH64_SPILL_WORDS * 8 {% else %} 64 {% end %}
        return false unless top >= guard && (top &+ min_spill) <= bottom
        max_frames = StackMaps::MAX_FP_FRAMES
        miss_only = @precise_stack_fiber_fp_fill_miss_only
        saw = false
        StackMaps.each_parked_fp_frame_range(top, guard, bottom, max_frames, miss_only) do |lo, hi, do_fill|
          saw = true
          span = hi - lo
          unless do_fill
            @parked_fp_fill_skipped_frames += 1
            @parked_fp_fill_skipped_bytes += span
            next
          end
          @parked_fp_fill_frames += 1
          @parked_fp_fill_bytes += span
          Roots.scan_range(Pointer(Void).new(lo), Pointer(Void).new(hi), safe: true) do |candidate|
            mark_root_candidate(candidate, source: RootSource::Parked)
          end
        end
        saw
      {% else %}
        false
      {% end %}
    end

    private def scan_other_thread_stacks : Nil
      return unless @stop_the_world

      # Parallel mid-swap needs full fiber + pthread coverage. EC1 only has
      # main+SYSMON — full 8 MiB SYSMON scans blew phase_stacks (~0.02→~3ms)
      # and dropped Kemal /json ~86%→~80% Boehm. Keep the cheap path there.
      multi = multi_mutator_threads?
      current = Thread.current
      Thread.unsafe_each do |thread|
        next if thread == current
        pthread = thread.to_unsafe
        fiber = thread.@current_fiber

        # Always spill GP registers at suspend — may hold the only live copy.
        Platform.each_thread_greg(pthread) do |candidate|
          @thread_greg_candidates += 1
          mark_root_candidate(candidate, source: RootSource::Thread)
        end

        sp = Platform.thread_sp(pthread)
        # Snapshot taken in stop_world before any thread was suspended. Calling
        # pthread_getattr_np here instead is what hung the collector: it locks the
        # target's descriptor, and a suspended thread can hold its own. See
        # Platform.snapshotted_stack_bounds.
        pthread_bounds = Platform.snapshotted_stack_bounds(pthread)

        # Precise stack-map roots (additive). Prefer fiber bounds when SP is on
        # a fiber; else pthread mapping.
        if @precise_stack_roots
          lo = 0_u64
          hi = 0_u64
          if fiber
            st = fiber.@stack
            lo = st.pointer.address + Roots::PAGE_SIZE
            hi = st.bottom.address
          elsif pthread_bounds
            lo = pthread_bounds[0].address
            hi = pthread_bounds[1].address
          end
          scan_precise_thread_stack(pthread, lo, hi) if lo < hi
        end

        unless multi
          # current_fiber can be nil (idle Monitor / mid-swap). Skipping the
          # whole thread left Darwin CI stw_sp_clamp at hits=0 fallbacks=0 and
          # missed OS-stack roots. Scan pthread bounds when fiber is absent.
          #
          # Exclusive skips *mutator* full-stack word scan only — other threads
          # under STW still need conservative coverage (gregs + maps alone
          # missed SYSMON roots → acik ThreadPool UAF / collect hang).
          if fiber
            mark_root_candidate(Pointer(Void).new(fiber.object_id), source: RootSource::Thread)
            scan_other_thread_fiber_ec1(fiber, sp, pthread_bounds)
          else
            scan_pthread_stack(pthread_bounds, sp)
          end
          next
        end

        # Running/parked fiber stacks are already covered by scan_all_fiber_roots
        # under stw_multi (full guard→bottom for running; LAG for parked). Dual
        # scan_fiber_stack_full here was thr-only cost (~phase_stacks half).
        # Keep fiber object pin + mid-swap SP stack + pthread (scheduler frames).
        if fiber
          mark_root_candidate(Pointer(Void).new(fiber.object_id), source: RootSource::Thread)
        end

        # Mid-swap: Scheduler sets current_fiber to the *next* fiber before
        # swapcontext saves the previous SP. If we only trust current_fiber +
        # stack_top, live frames below a stale top (still holding SP) are
        # swept → Kemal EC>1 SEGV @ 0x4. Always scan the stack that contains
        # the suspend SP (red zone included). Exclusive must keep this too.
        scan_stack_containing_sp(sp)

        # Pthread mapping: scheduler/main frames remain here while SP sits on
        # a pool fiber (Boehm tracks per-thread stackbottom through swaps).
        scan_pthread_stack(pthread_bounds, sp)
      end
    end

    # Single-mutator other-thread scan. Do **not** key off fiber.name == "main":
    # every Thread's root fiber is named "main" (incl. SYSMON), and the old
    # heuristic fell into full pthread scans when SP sat on a fiber stack
    # (phase_stacks ~1.5ms vs ~0.02ms; Kemal /json stuck ~82% Boehm).
    private def scan_other_thread_fiber_ec1(fiber : Fiber, sp : Void*?, pthread_bounds : {Void*, Void*}?) : Nil
      stack = fiber.@stack
      guard = stack.pointer.address + Roots::PAGE_SIZE
      bottom = stack.bottom.address

      if sp
        spa = sp.address
        if spa >= stack.pointer.address && spa < bottom && guard < bottom
          top = stack_scan_low(spa, guard)
          @sp_clamp_hits += 1
          Roots.scan_range(Pointer(Void).new(top), Pointer(Void).new(bottom), safe: true) do |candidate|
            mark_root_candidate(candidate, source: RootSource::Thread)
          end
          return
        end
        if pthread_bounds
          pl = pthread_bounds[0].address
          ph = pthread_bounds[1].address
          if spa >= pl && spa < ph
            # SP on OS stack — clamp; never full-map when SP is elsewhere.
            scan_pthread_stack(pthread_bounds, sp)
            return
          end
        end
      end

      # Idle / SP unknown: cheap stack_top clamp (not full 8 MiB).
      # Count as fallback so samples/stw_sp_clamp (and metrics) see the scan —
      # aarch64/Darwin often land here when suspend SP is outside fiber/pthread
      # bounds; skipping the counter made CI abort after the EC1 cheap path.
      if guard < bottom
        top = fiber.@context.stack_top.address
        top = guard if top < guard
        if top < bottom
          @sp_clamp_fallbacks += 1
          Roots.scan_range(Pointer(Void).new(top), Pointer(Void).new(bottom), safe: true) do |candidate|
            mark_root_candidate(candidate, source: RootSource::Thread)
          end
          return
        end
      end

      # Fiber stack unusable — still cover OS frames (Darwin SYSMON flake).
      scan_pthread_stack(pthread_bounds, sp)
    end

    # Scan [SP−red_zone, bottom) of whichever fiber stack holds *sp*.
    private def scan_stack_containing_sp(sp : Void*?) : Nil
      return unless sp

      spa = sp.address
      Fiber.unsafe_each do |fiber|
        stack = fiber.@stack
        base = stack.pointer.address
        bottom = stack.bottom.address
        next unless spa >= base && spa < bottom

        guard = base + Roots::PAGE_SIZE
        next unless guard < bottom

        low = stack_scan_low(spa, guard)
        @sp_clamp_hits += 1
        Roots.scan_range(Pointer(Void).new(low), Pointer(Void).new(bottom), safe: true) do |candidate|
          mark_root_candidate(candidate, source: RootSource::Thread)
        end
        return
      end
    end

    # SysV x86_64 red zone: callees may store below SP without adjusting it.
    {% if flag?(:x86_64) %}
      STACK_SCAN_RED_ZONE = 128_u64
    {% else %}
      STACK_SCAN_RED_ZONE = 0_u64
    {% end %}

    private def stack_scan_low(sp_addr : UInt64, floor : UInt64) : UInt64
      low = sp_addr > STACK_SCAN_RED_ZONE ? sp_addr - STACK_SCAN_RED_ZONE : 0_u64
      low < floor ? floor : low
    end

    # Scan [low, high) of the OS thread stack. When SP is inside the mapping,
    # clamp to SP−red_zone (still covers live frames). When SP is on a fiber
    # stack, Parallel workers leave scheduler frames near the pthread high end —
    # scan a LAG window from high (not the full ~8 MiB map) unless lag is 0.
    private def scan_pthread_stack(pthread_bounds : {Void*, Void*}?, sp : Void*?) : Nil
      return unless pthread_bounds

      low = pthread_bounds[0].address
      high = pthread_bounds[1].address
      return unless low < high

      if sp
        spa = sp.address
        if spa >= low && spa < high
          low = stack_scan_low(spa, low)
          @sp_clamp_hits += 1
        else
          @sp_clamp_fallbacks += 1
          # SP on pool fiber (or elsewhere): Parallel LAG from high.
          if multi_mutator_threads?
            lag = @stw_multi_pthread_lag
            unless lag == 0
              lagged = high > lag ? high - lag : low
              low = lagged if lagged > low
            end
          end
        end
      else
        @sp_clamp_fallbacks += 1
        if multi_mutator_threads?
          lag = @stw_multi_pthread_lag
          unless lag == 0
            lagged = high > lag ? high - lag : low
            low = lagged if lagged > low
          end
        end
      end

      # Same removal as the parked-fiber path: with lag 0 this scans the whole
      # ~8 MiB pthread mapping, nearly all of which was never written. Skipping
      # the untouched head sees identical words — a page with neither the
      # present nor the swapped bit has never been faulted, so it is zero.
      {% if flag?(:linux) %}
        if @stack_low_water_scan && low < high
          lw = Platform.stack_low_water(low, high)
          if lw > low && lw < high
            @low_water_skips += 1
            @low_water_skipped_bytes += lw - low
            low = lw
          end
        end
      {% end %}

      Roots.scan_range(Pointer(Void).new(low), Pointer(Void).new(high), safe: true) do |candidate|
        mark_root_candidate(candidate, source: RootSource::Thread)
      end
    end

    private def mark_metadata_roots : Nil
      # Finalizer/link tables are LibC storage (not GC roots for Entry.object).
      # Only mark callback closure_data so Proc captures stay alive. Marking the
      # old Crystal Array buffer kept every finalizable object forever (acik
      # TCPSocket/Digest + 32 KiB IO buffers; finalizers never ran).
      # World stopped; registry quiesced at stop_world.
      n = @finalizers.entry_count
      i = 0
      while i < n
        data = @finalizers.entry_closure_data_at(i)
        mark_candidate(data) unless data.null?
        i += 1
      end
    end

    # Emit [low, high) minus each mapped heap chunk via sorted chunk index merge.
    private def each_static_range_excluding_heap(low : Void*, high : Void*, & : Void*, Void* ->) : Nil
      ensure_chunk_index
      lo = low.address
      hi = high.address
      return if hi <= lo

      cursor = lo
      i = 0
      n = @chunk_index_count
      while i < n && cursor < hi
        chunk = (@chunk_index + i).value
        c_lo = chunk.address
        c_hi = c_lo + chunk.value.mapped_bytes

        if c_hi <= cursor
          i += 1
          next
        end
        break if c_lo >= hi

        if c_lo > cursor
          gap_hi = c_lo < hi ? c_lo : hi
          yield Pointer(Void).new(cursor), Pointer(Void).new(gap_hi)
        end

        cursor = c_hi if c_hi > cursor
        i += 1
      end

      if cursor < hi
        yield Pointer(Void).new(cursor), Pointer(Void).new(hi)
      end
    end
  end
end
