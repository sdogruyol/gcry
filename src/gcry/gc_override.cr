# Reopens Crystal's `GC` module under `-Dgc_none`, forwarding to Gcry.

require "./platform/stw_signals"

{% if flag?(:linux) && flag?(:gnu) %}
  lib LibC
    $__libc_stack_end : Void*
  end
{% end %}

module GC
  @@gcry_ready = false
  # Bytes `GC.malloc`/`GC.realloc` handed out from libc before the heap was
  # ready (`bootstrap_malloc`), still live. Nothing ever sweeps them, so they
  # are `GC.prof_stats.non_gc_bytes` — Boehm's "bytes not considered candidates
  # for collection". Counted in libc's usable size, the unit the frees below
  # can recover. A literal, so it is statically initialised before `GC.init`.
  @@non_gc_bytes = 0_u64
  # Set when fork child cannot reinit (GCRY_DISABLE_ATFORK=1 or install failed).
  @@after_fork_child = false
  @@handle_fork = true

  def self.init : Nil
    Crystal::System::Thread.init_suspend_resume
    # Capture SP in the suspend handler so other-thread scans skip below-SP.
    #
    # Installed unconditionally, and that is a fix rather than a tidy-up:
    # `GCRY_DISABLE_SP_CLAMP=1` used to skip this, and on Linux this call is
    # what installs the `SIG_SUSPEND` handler — the mechanism the stop gets its
    # acknowledgements through. Setting the knob therefore did not trade
    # precision for speed, it **wedged the collector**: `bench/greg_roots.cr`
    # made no progress in 60 s with it, and the orphan-knob census recorded the
    # same hang on two harnesses without knowing why
    # (`bench/log/linux/2026-09-18-sp-clamp-knob/FINDINGS.md`). The knob now
    # disables only the clamp, which is what `docs/HARDENING.md` always said it
    # did.
    Gcry::Platform.install_stw_sp_capture

    Gcry::Platform.init_staging
    Gcry::Platform.note_main_thread
    Gcry::ThreadBirthRoot.init

    # Build the heap while still on LibC malloc (@@gcry_ready == false).
    heap = Gcry.default_heap
    heap.scan_static_roots = true
    # Process GC must STW: ExecutionContext always has a Monitor OS thread.
    heap.stop_the_world = true
    # Process GC majors by default. Nursery needs a sound old→young remembered
    # set: Linux soft-dirty is probed later, but has false-negatives under WSL
    # release HTTP (Kemal Hash key UAF / SEGV at 0x0..0x11). Default OFF on all
    # platforms; opt in with GCRY_NURSERY=1 once barriers are measured clean.
    heap.nursery_enabled = false
    heap.nursery_threshold = UInt64::MAX
    # Incremental majors likewise depend on the page-dirty barrier between
    # slices. Same WSL false-negatives made Kemal release crashy — default OFF;
    # opt in via GCRY_INCREMENTAL=1.
    heap.incremental_auto = false
    # Process GC: adaptive empty-chunk release (dormant DONTNEED within retain,
    # munmap excess). GCRY_KEEP_CHUNKS=1 forces off; GCRY_RELEASE_CHUNKS=1 forces on.
    heap.release_empty_chunks = true
    # Keep recently-freed chunks as dormant (MADV_DONTNEED-style page release)
    # up to 512 KiB on Darwin (macOS MADV_FREE_REUSABLE drops RSS efficiently
    # at the page level, so a 512 KiB cap keeps tiny reuse bursts warm without
    # pinning the full 8 MiB wastage seen in v0.12.0). Higher retain budgets on
    # macOS only inflate RSS — the per-page reclaim is already done.
    # Pure-munmap churn under Kemal-style workloads fragments the VMA space
    # and inflates RSS via repeated mmap+madvise cycles; a moderate retain
    # budget lets the kernel drop physical pages while keeping VMA cache
    # hot for the next reuse.
    {% if flag?(:darwin) %}
      heap.empty_chunk_retain = 512_u64 * 1024_u64
      # 256 KiB size-class chunk (up from 128 KiB library default). The 128 KiB
      # chunk inflated collection count (~290 majors in 30s) and crushed
      # acikturkiye throughput to ~57% Boehm (vs ~79% at 256 KiB). Kemal RSS
      # barely moves (0.88× → 1.04× Boehm). Escape: GCRY_CHUNK_BYTES=131072.
      heap.small_chunk_bytes = 262144_u64
      # Parked fiber stacks carry stale pointer values from prior activations,
      # and those become false roots during conservative scanning. Scrubbing
      # them was default-on to cut that retention. It is **off** now: the wipe
      # zeroes memory below another fiber's *estimated* SP from a foreign
      # thread, its RSS justification does not reproduce, and no perf axis
      # decides it — see the Linux branch below and docs/SOUND-DEFAULTS.md
      # § "What scrub_fibers costs".
      # Opt back in: GCRY_SCRUB_FIBERS=1.
      heap.scrub_fibers_enabled = false
      heap.blacklist_enabled = false
      # Large cache on Darwin starts at 1 MiB (adaptive can grow to LARGE_CACHE_LIMIT
      # if hit-rate warrants it). A cached chunk stays resident and counts in
      # `phys_footprint`, so a fat cache is wasteful; the 1 MiB floor avoids mmap
      # churn for the common case.
      heap.large_cache_retain = 1048576_u64
    {% else %}
      # Linux: munmap empty size-class chunks (no dormant retain). Prior 16 MiB
      # retain + adaptive large-cache (→32 MiB) left acik ~2× Boehm RSS after the
      # finalizer fix; release0 med3 (`…/acik-release0-med3/`) tied Boehm RSS at
      # ~94% thr. Escape: GCRY_EMPTY_CHUNK_RETAIN=<bytes>.
      heap.empty_chunk_retain = 0_u64
      # Parked-fiber scrub: **off**. It was turned on for fat-app RSS
      # (acikturkiye 3.00× → 2.65×) and that number does not reproduce — acik is
      # bistable between a ~44 and a ~72 MiB heap regime, so n=3 said +46% worse
      # and n=9 said −34.9% better; stratified it is a wash. Kemal RSS is flat
      # (0.76× → 0.75×). Throughput cannot decide it either: `roots + scrub +
      # stacks` is 0.146% of wall time at EC1 and the knob moves 9.1% of that,
      # i.e. ~0.013% — both the +1.29% and the −1.22% cuts are ~100× the largest
      # effect the mechanism can produce.
      #
      # What is left is the correctness axis, and it is not settled in scrub's
      # favour. The wipe zeroes `[stack_top − 4 KiB, stack_top)` on *another*
      # fiber's stack, keyed on `@context.stack_top` — a saved value, i.e. an
      # estimate of where that fiber's live frames end. bdwgc's `GC_clear_stack`
      # only ever wipes below the *calling* thread's own hardware SP.
      # `bench/scrub_audit.cr` answers one half of that: across EC1 and EC4 the
      # window never reached a foreign thread's live frames, because every SP
      # sighting was on a fiber still reporting `running?`. It explicitly does
      # not answer the other half — whether a pointer can live only in the wiped
      # region in a shape those runs never exercised. This document's own claims
      # table rates the default "unproven either way".
      #
      # A wipe that lands one frame too high zeroes a live reference slot, which
      # surfaces either as an immediate nil deref when the fiber resumes or as a
      # dropped root → swept-while-live → SEGV at a small address. A knob whose
      # benefit is a wash, whose cost is a wash, and which is the only default-on
      # heuristic that *writes* to memory the collector does not own does not
      # keep its default on "unproven". Opt back in: GCRY_SCRUB_FIBERS=1.
      #
      # Collect-time mutator clear_stack was measured and dropped (below-SP wipe
      # is outside the root-scan window; no durable thr/RSS win).
      heap.scrub_fibers_enabled = false
      heap.blacklist_enabled = false
      # Large-object freelist: no retain (was 4 MiB floor, adaptive → 32 MiB).
      # Escape: GCRY_LARGE_CACHE=<bytes> (adaptive may grow from a non-zero floor).
      heap.large_cache_retain = 0_u64
    {% end %}
    # No type_id gate on any ambient root, static ones included.
    #
    # Until 2026-09-29 static roots were gated: a class variable, constant or
    # main-thread thread-local that pointed at a non-atomic block was dropped
    # unless the block's first `Int32` looked like a type id. A raw buffer of
    # references does not: `@@buf = Pointer(String).malloc(n)` or
    # `@@items = Slice(String).new(n) { ... }` held its first element's
    # address there, so the buffer was swept while the class variable still
    # named it, and reading it crashed in 3 of 3 runs. The gate had been
    # measured a no-op for RSS when it went in, and on Kemal today it rejects
    # one static root in a whole run, with pause, post-GC RSS and req/s
    # unchanged at EC1 and EC4
    # (`bench/log/linux/2026-09-29-static-type-id-gate/`). Stack roots were
    # never gated for the same reason (Channel/Deque buffers, the
    # Log::AsyncDispatcher SEGV). `GCRY_TYPE_ID_GATE=1` restores the static
    # gate.
    heap.type_id_gate = false
    heap.type_id_gate_stacks = false
    # Page blacklist: off (set in the Darwin/Linux branches above). Its only
    # input was the static type_id gate's rejects, and with the gate gone it
    # had none. Fed the sound way instead, from root candidates that name a
    # free block, it skipped 538 k blocks in a Kemal EC4 run and moved neither
    # pause, post-GC RSS nor req/s, so it stays off
    # (`bench/log/linux/2026-09-29-static-type-id-gate/`). `GCRY_BLACKLIST=1`
    # turns it on.
    # Interior pointers on ambient roots are a *soundness* requirement under
    # LLVM -O3, not a tuning: a strength-reduced loop over an Array/String
    # buffer keeps only `buffer + i*8` in a register while the base is dead,
    # and base-only marking then frees the buffer under the loop. A 40-line
    # program (400k-element Array + allocation churn) SIGSEGVs 3 of 3 on
    # `--release` with this false; bdwgc as Crystal links it has always
    # accepted interiors. Measured cost on Kemal /json: −0.1% (SOUND-DEFAULTS).
    # Escape for measurement: GCRY_DISABLE_INTERIOR=1.
    heap.allow_interior_pointers = true
    # The same argument one byte over: a byte-wise loop over a `Bytes` is
    # reduced to a raw pointer induction variable that is word-aligned one
    # time in eight, and the cheap alignment filter rejected that one
    # reference before `find_block` ran (`make unaligned-only-buffer`:
    # SIGSEGV 3 of 3 with the filter). bdwgc resolves it through GC_base.
    # Cost is +4.3% of root work, a few µs per collection (SOUND-DEFAULTS).
    # Escape for measurement: GCRY_ALIGNED_CANDIDATES=1.
    heap.scan_unaligned_candidates = true
    heap.layout_precise = true
    # Avoid mid-boot collections until env config runs.
    heap.gc_threshold = UInt64::MAX

    {% if flag?(:linux) && flag?(:gnu) %}
      heap.set_stackbottom(LibC.__libc_stack_end)
    {% elsif flag?(:darwin) || flag?(:win32) %}
      if bounds = Gcry::Platform.current_pthread_stack_bounds
        heap.set_stackbottom(bounds[1])
      end
    {% end %}
    # Suspended fiber stacks are scanned once inside Heap#scan_all_fiber_roots
    # (with guard clamp). Do not also call push_gc_roots here — that doubled
    # stack word walks under HTTP (many fibers) and dominated STW pauses.
    # Crystal 1.21+ ExecutionContext does not call GC.set_stackbottom on swap —
    # refresh the running fiber bottom each collect.
    heap.before_collect do
      # Arm the crash reporter *first*. It is installed here rather than at
      # `GC.init` because Crystal installs its own SIGSEGV handler after init
      # and does not chain, so anything installed earlier is discarded
      # (`Gcry::SegvReport.install_if_requested`).
      #
      # Before the `Fiber.current` call below rather than after it: that call
      # is the one thing in this block that can raise, and a reporter armed
      # after it is a reporter that is not armed when it does. A/B'd on
      # `bench/large_cache_race.cr` and the two orders were indistinguishable
      # there — the reporter installs either way — so this is ordering for a
      # reason, not a measured fix.
      {% if flag?(:unix) %} Gcry::SegvReport.install_if_requested {% end %}
      heap.set_stackbottom(Fiber.current.@stack.bottom)
    end

    # Layout tables must be built on LibC malloc (before @@gcry_ready). Hash/Array
    # growth under gcry during GC.init SIGSEGVs — Fiber/runtime is not ready yet.
    # GCRY_DISABLE_LAYOUT is applied here and again in apply_env_config.
    if env_flag_one?("GCRY_DISABLE_LAYOUT")
      heap.layout_precise = false
      Gcry::Layout.enabled = false
    else
      Gcry::Layout.register_builtins
      # Precise whole-program layouts (Reference.all_subclasses). Opt-in via
      # GCRY_AUTO_LAYOUTS=1 — Linux Kemal /json ~7pp thr vs builtins-only
      # (bench/log/thr-abis). register() falls back to scan_cap for unsafe ivars;
      # alloc_size must match before precise/scan_cap (raw-buffer type_id collisions).
      # Escape when opted in: GCRY_DISABLE_AUTO_LAYOUTS=1.
      # Curated HTTP::Headers::Key Hash as process default was measured: Kemal
      # /json thr soft vs builtins-only — keep registration app-side
      # (bench/nursery_headers.cr) or via GCRY_AUTO_LAYOUTS.
      if env_flag_one?("GCRY_AUTO_LAYOUTS") && !env_flag_one?("GCRY_DISABLE_AUTO_LAYOUTS")
        Gcry.register_layouts
      end
      # Optional size-class slack caps for all Reference types (GCRY_SCAN_CAPS=1).
      if env_flag_one?("GCRY_SCAN_CAPS")
        Gcry::Layout.register_scan_caps
      end
    end

    # Ordering marker for `GCRY_TRACE_LARGE=1`: everything above is gcry
    # bringing itself up, everything below is the program.
    if env_flag_one?("GCRY_TRACE_LARGE")
      buf = uninitialized UInt8[Gcry::RawOut::LIMIT]
      n = Gcry::RawOut.append(buf.to_unsafe, 0, "gcry: init done\n")
      Gcry::RawOut.flush(buf.to_unsafe, n)
    end
    @@gcry_ready = true
    apply_env_config(heap)
    # After the allocator's shape is final: the reserve serves the bitmap
    # path only (`src/gcry/oom_reserve.cr`). `GCRY_OOM_RESERVE_KB=0` is the
    # red arm of `make oom-no-hang`.
    heap.setup_oom_reserve((env_u64("GCRY_OOM_RESERVE_KB") || Gcry::Heap::OOM_RESERVE_DEFAULT_KB) &* 1024)

    # Fork: reinit locks/STW in the child (opt out with GCRY_DISABLE_ATFORK=1).
    # `make fork-test` requires the handler installed; `--disabled` needs the
    # knob so it is not, then `note_fork_child` + malloc must `_exit(69)`
    # without allocating. Dropping the skip reddens the gate (exit 64).
    unless env_flag_one?("GCRY_DISABLE_ATFORK")
      @@handle_fork = true
      Gcry::Platform.set_atfork_handlers(
        -> { GC.fork_prepare },
        -> { GC.fork_parent },
        -> { GC.fork_child },
      )
      Gcry::Platform.install_atfork
    else
      @@handle_fork = false
    end
  end

  # Manual integrator hook: mark child poisoned when atfork reinit is disabled.
  # :nodoc:
  def self.note_fork_child : Nil
    if @@handle_fork && @@gcry_ready
      fork_child
    else
      @@after_fork_child = true
    end
  end

  # :nodoc:
  def self.fork_prepare : Nil
    # Avoid holding GC write lock across fork (deadlock if parent owned it).
  end

  # :nodoc:
  def self.fork_parent : Nil
  end

  # :nodoc:
  def self.fork_child : Nil
    return unless @@gcry_ready
    Gcry::IdleRelease.after_fork_child
    if @@handle_fork
      Gcry.default_heap.after_fork_child_reinit
      @@after_fork_child = false
      Gcry::Platform.install_stw_sp_capture
    else
      @@after_fork_child = true
    end
  end

  # Child status `make fork-test --disabled` requires. Must not allocate:
  # `raise` re-enters `malloc` and overflows the stack (measured).
  FORK_POISON_EXIT = 69

  private def self.check_fork_poison! : Nil
    if @@after_fork_child
      buf = uninitialized UInt8[Gcry::RawOut::LIMIT]
      n = Gcry::RawOut.append(buf.to_unsafe, 0, "gcry: GC after fork is unsupported without atfork reinit (unset GCRY_DISABLE_ATFORK); see docs/POLICY.md\n")
      Gcry::RawOut.flush(buf.to_unsafe, n)
      LibC._exit(FORK_POISON_EXIT)
    end
  end

  # Root-completeness profile (GCRY_SOUND=1). See docs/SOUND-DEFAULTS.md.
  #
  # Every knob here trades *root-scan completeness* for throughput or RSS:
  # each one can decline to mark a pointer that is genuinely live. Each was
  # argued individually, in place, against a measured regression. The sound
  # profile turns the whole class off at once so a measurement can answer one
  # question honestly: what does gcry cost when it is not allowed to guess?
  #
  # (First cut said: less than expected. Kemal /json is ~1pp of throughput and
  # no RSS movement — see docs/SOUND-DEFAULTS.md. Since 2026-10-05 the process
  # defaults are this profile: the last two knobs it moved, the STW stack lags,
  # default to 0. The profile stays as the switch that forces it whole.)
  #
  #   allow_interior_pointers  LLVM may keep only an interior pointer live in a
  #                            register / spill slot while the base is dead
  #                            (strength-reduced loop over a String / Array
  #                            buffer). bdwgc as Crystal links it treats
  #                            interiors as valid, so base-only ambient roots
  #                            are strictly less conservative than what
  #                            Crystal's codegen has been validated against.
  #   scan_unaligned_candidates  ditto for `str.to_unsafe + 3`: a misaligned
  #                            interior is a root bdwgc resolves via GC_base.
  #   type_id_gate             rejects a *static* root whose first Int32 is
  #                            <= 0 or > 1_000_000 — a heuristic applied to a
  #                            real reference (see type_id_root_false_negatives,
  #                            which exists to count when it was wrong).
  #   stw_multi_*_lag          bounds how far below a parked stack_top another
  #                            thread's stack is scanned; a live pointer deeper
  #                            than the lag is never seen. 0 == full scan.
  #   scrub_fibers_enabled     zeroes bytes below a parked fiber's *estimated*
  #                            SP, from another thread. bdwgc's GC_clear_stack
  #                            only ever wipes below the calling thread's own
  #                            hardware SP.
  #   blacklist_enabled        steers allocation away from pages the type_id
  #                            gate called false. With the gate off nothing
  #                            feeds it; keep it off so the profile has exactly
  #                            one meaning.
  #   scan_static_roots        a heap that never walks BSS/data misses roots by
  #                            construction (GCRY_DISABLE_STATIC_ROOTS=1).
  #   nursery / incremental    the *barrier* axis: both make liveness depend on
  #                            the page-dirty remembered set, and soft-dirty has
  #                            measured false-negatives (see the nursery note in
  #                            GC.init). Already off for process GC; set here so
  #                            the profile does not rely on that default.
  #
  # Object-body scan precision (Gcry::Layout, keyed on the payload's first
  # Int32) is a *separate* axis and is deliberately not touched here — measure
  # it with GCRY_DISABLE_LAYOUT=1 so the two costs stay attributable.
  #
  # Applied before the individual knobs below, so an explicit GCRY_* still
  # wins: `GCRY_SOUND=1 GCRY_SCRUB_FIBERS=1` re-enables scrub.
  private def self.apply_sound_profile(heap : Gcry::Heap) : Nil
    heap.allow_interior_pointers = true
    heap.scan_unaligned_candidates = true
    heap.scan_static_roots = true
    heap.type_id_gate = false
    heap.type_id_gate_stacks = false
    heap.stw_multi_stack_lag = 0_u64
    heap.stw_multi_pthread_lag = 0_u64
    heap.scrub_fibers_enabled = false
    heap.blacklist_enabled = false
    # Barrier axis: liveness must not depend on the page-dirty remembered set.
    # Both are already off for process GC — set them so the profile is
    # self-contained rather than relying on a default that could move.
    heap.nursery_enabled = false
    heap.incremental_auto = false
  end

  # The dormant budget `GCRY_PARALLEL_DORMANT(_ALL)=1` gets when no
  # `GCRY_EMPTY_CHUNK_RETAIN` was given: one Parallel major threshold.
  PARALLEL_DORMANT_DEFAULT_RETAIN = Gcry::Heap::PROCESS_GC_THRESHOLD_PARALLEL

  # Use Gcry::OS.getenv — Crystal's ENV uses `once` + Fiber, unavailable in GC.init.
  private def self.apply_env_config(heap : Gcry::Heap) : Nil
    heap.root_phase_timing = env_flag_one?("GCRY_ROOT_PHASE_TIMING")
    # First: whole-class root-completeness profile. Individual knobs below
    # override it, so this must run before them.
    apply_sound_profile(heap) if env_flag_one?("GCRY_SOUND")

    # Live × factor sizes both the adaptive threshold and the warm-retention
    # budget (`adapt_after_sweep`), and the budget follows it under a fixed
    # `GCRY_THRESHOLD` too - so the factor is read once, outside the branch
    # that decides whether the threshold adapts.
    if pct = env_u64("GCRY_THRESHOLD_FACTOR")
      heap.adaptive_threshold_pct = pct.clamp(10_u64, 1000_u64)
    end
    # Below the floor it would undercut the threshold's own minimum, so it is
    # ignored there rather than clamped.
    if (max = env_u64("GCRY_THRESHOLD_MAX")) && max >= Gcry::Heap::ADAPTIVE_THRESHOLD_MIN
      heap.adaptive_threshold_max = max
    end

    if env_flag_one?("GCRY_DISABLE_AUTO")
      heap.gc_threshold = UInt64::MAX
    elsif thr = env_u64("GCRY_THRESHOLD")
      heap.gc_threshold = thr unless thr == 0
    elsif heap.bitmap_alloc?
      # No fixed threshold asked for: start at the floor and size the heap
      # from the live set after each major (`adapt_after_sweep`). A fixed
      # 16 MiB regressed acikturkiye by ~20pp through major cycling; the
      # adaptive threshold grows with that live set instead, and a small one
      # (Kemal: ~10 MB) no longer pays for a 32 MiB budget in RSS. Bitmap
      # allocator only: it is paired with warm retention there, and the
      # header build took 251 majors for 62 with the smaller threshold and
      # none of the relief.
      heap.gc_threshold = Gcry::Heap::ADAPTIVE_THRESHOLD_MIN
      heap.adaptive_threshold = true
      # Parallel EC: raise major threshold (see PROCESS_GC_THRESHOLD_PARALLEL).
      # Explicit GCRY_THRESHOLD above wins; EC1/default unchanged.
      if (ec = env_u64("EC_PARALLELISM")) && ec > 1
        heap.gc_threshold = Gcry::Heap::PROCESS_GC_THRESHOLD_PARALLEL
        heap.adaptive_threshold = false # unmeasured under EC4; keep the fixed 64 MiB
        # Contended alloc/free counters need Atomic RMW.
        heap.heap_counters_atomic = true
      end
    else
      # Header allocator: the fixed defaults as before (Linux 32 MiB,
      # Darwin 16 MiB), and 64 MiB under a Parallel execution context.
      {% if flag?(:darwin) %}
        heap.gc_threshold = 16_u64 * 1024_u64 * 1024_u64
      {% else %}
        heap.gc_threshold = 32_u64 * 1024_u64 * 1024_u64
      {% end %}
      if (ec = env_u64("EC_PARALLELISM")) && ec > 1
        heap.gc_threshold = Gcry::Heap::PROCESS_GC_THRESHOLD_PARALLEL
        heap.heap_counters_atomic = true
      end
    end

    # A/B for the allocation counters. They are plain get/set by default, which
    # loses increments outright once a second thread allocates
    # (src/gcry/invariant.cr), and atomic costs a LOCK RMW on the hot path — so
    # the two arms have to be runnable side by side before either can be
    # defended.
    if env_flag_one?("GCRY_HEAP_COUNTERS_ATOMIC")
      heap.heap_counters_atomic = true
      heap.heap_counters_atomic_pinned = true
    elsif env_flag_zero?("GCRY_HEAP_COUNTERS_ATOMIC")
      heap.heap_counters_atomic = false
      heap.heap_counters_atomic_pinned = true
    end

    if env_flag_one?("GCRY_DISABLE_NURSERY")
      heap.nursery_enabled = false
      heap.nursery_threshold = UInt64::MAX
    elsif (nursery = env_u64("GCRY_NURSERY")) && {% if flag?(:gcry_block_headers) %} true {% else %} false {% end %}
      # (headerless, the default layout: GCRY_NURSERY is ignored — see Heap#nursery_enabled=)
      # Opt-in: nursery without barriers is expensive (old→young full scan).
      heap.nursery_enabled = true
      heap.nursery_threshold = nursery unless nursery == 0
      heap.nursery_threshold = Gcry::Heap::DEFAULT_NURSERY_THRESHOLD if heap.nursery_threshold == UInt64::MAX
    end

    if env_flag_one?("GCRY_DISABLE_ADAPTIVE_NURSERY")
      heap.adaptive_nursery = false
    end

    # Soft-dirty page scan only when dirty/total ≤ this percent (default 25).
    # GCRY_DISABLE_SOFT_DIRTY=1 forces full old→young object scan.
    if env_flag_one?("GCRY_DISABLE_SOFT_DIRTY")
      heap.soft_dirty_max_pct = 0
    elsif max_pct = env_u64("GCRY_SOFT_DIRTY_MAX")
      heap.soft_dirty_max_pct = max_pct.to_i32 if max_pct <= 100
    end

    # Page-dirty barrier: prefer soft-dirty; mprotect as opt-in / fallback.
    # Process GC may use mprotect when soft-dirty is unavailable.
    heap.allow_mprotect_barrier = true
    if env_flag_one?("GCRY_MPROTECT_BARRIER")
      heap.prefer_mprotect_barrier = true
      heap.allow_mprotect_barrier = true
    end
    if env_flag_one?("GCRY_DISABLE_MPROTECT")
      heap.prefer_mprotect_barrier = false
      heap.allow_mprotect_barrier = false
    end

    if env_flag_one?("GCRY_INCREMENTAL")
      # Sliced majors with dirty-page re-scan when a barrier backend is armed.
      heap.incremental_auto = true
    end

    if env_flag_one?("GCRY_DISABLE_INCREMENTAL") || env_flag_one?("GCRY_NO_INCREMENTAL")
      heap.incremental_auto = false
    end

    if work = env_u64("GCRY_INCREMENTAL_WORK")
      heap.incremental_work = work.to_i32 if work > 0 && work <= Int32::MAX
    end

    # Adaptive empty-chunk release is process default (dormant + munmap excess).
    # GCRY_KEEP_CHUNKS=1 forces off; GCRY_RELEASE_CHUNKS=1 forces on.
    # Parallel: reclaim off by default.
    #   GCRY_PARALLEL_DORMANT=1 — DONTNEED within empty_chunk_retain (bounded).
    #   GCRY_PARALLEL_DORMANT_ALL=1 — DONTNEED every empty (legacy; thr↓).
    #   GCRY_PARALLEL_RELEASE=1 — munmap excess (UNSUPPORTED; can hang).
    if env_flag_one?("GCRY_KEEP_CHUNKS")
      heap.release_empty_chunks = false
    elsif env_flag_one?("GCRY_RELEASE_CHUNKS")
      heap.release_empty_chunks = true
    end
    if env_flag_one?("GCRY_PARALLEL_DORMANT") || env_flag_one?("GCRY_PARALLEL_DORMANT_ALL")
      heap.parallel_empty_chunk_dormant = true
    end
    if env_flag_one?("GCRY_PARALLEL_DORMANT_ALL")
      heap.parallel_empty_chunk_dormant_all = true
    end
    if env_flag_one?("GCRY_PARALLEL_RELEASE")
      warn_unsupported_env(
        "gcry: WARNING: GCRY_PARALLEL_RELEASE=1 is unsupported (can hang / force in-STW sweep). " \
        "Supported Parallel RSS opt-in is GCRY_PARALLEL_DORMANT=1. See docs/POLICY.md\n"
      )
      heap.parallel_empty_chunk_munmap = true
      heap.parallel_empty_chunk_dormant = true
    end

    if env_flag_one?("GCRY_DISABLE_LAZY_SWEEP")
      heap.lazy_sweep = false
    end

    if retain = env_u64("GCRY_EMPTY_CHUNK_RETAIN")
      heap.empty_chunk_retain = retain
    elsif heap.parallel_empty_chunk_dormant && heap.empty_chunk_retain < PARALLEL_DORMANT_DEFAULT_RETAIN
      # The dormant opt-ins release empties *within* this budget, and the
      # process default is 0 on Linux (512 KiB on Darwin) since 2026-08-03,
      # which left `GCRY_PARALLEL_DORMANT=1` — the documented Parallel RSS
      # opt-in — and `_ALL` doing nothing at all for two months: Kemal EC4
      # post-GC RSS 83.4 MB with it against 83.7 without, 19.3 MB once a
      # budget was given (`bench/log/linux/2026-09-26-parallel-dormant-inert/`).
      # One Parallel threshold is what a cycle can reuse; an explicit
      # `GCRY_EMPTY_CHUNK_RETAIN` still wins.
      #
      # Darwin too since 2026-09-27, when its release became
      # `MADV_FREE_REUSABLE`. Before that (`MADV_FREE`) the budget only turned
      # empties that would have been munmapped into dormant ones that stayed
      # in the footprint. Measured on the macOS runner, footprint after
      # `GC.collect` ÷ without the knob: EC1 1.04×, EC1 + a thread 0.50×,
      # EC4 0.36×. `ps` RSS reads EC1 1.65× because it counts reusable pages.
      heap.empty_chunk_retain = PARALLEL_DORMANT_DEFAULT_RETAIN
    end
    if warm = env_u64("GCRY_EMPTY_CHUNK_WARM_RETAIN")
      heap.empty_chunk_warm_retain = warm
    elsif heap.bitmap_alloc? && heap.gc_threshold != UInt64::MAX
      heap.warm_retain_follows_live = true
      # A bitmap chunk emptied by the sweep costs nothing to keep: its pages
      # are resident and its `occ` is zero, so the pool cursor reuses it in
      # place. Releasing it instead meant every 8 KiB block the next cycle
      # handed out arrived on a fresh page — two minor faults per allocation,
      # 1 256 per 1 000 Kemal requests against Boehm's 2 — for a mapping the
      # mutator was about to need again. Keep what one cycle allocates.
      heap.empty_chunk_warm_retain = heap.gc_threshold
    end

    if env_flag_one?("GCRY_DISABLE_MADVISE")
      heap.madvise_free_pages = false
    elsif env_flag_one?("GCRY_PAGE_DONTNEED")
      # Sparse-chunk free-page release (HOLED + post-STW madvise).
      heap.madvise_free_pages = true
      # Opt-in for throughput and RSS reasons, not soundness. It used to be
      # unsound: the post-STW walk computed a run of free pages from block
      # headers and then syscalled with the world running, so a block handed
      # out from a TLAB in between was zeroed after the mutator wrote it
      # (`make page-release-corruption` faulted 4 of 28). The walk now runs
      # under every lock a small allocation of the class can take
      # (`with_small_allocation_excluded`); the same gate and
      # `make live-graph-audit` are clean since (2026-09-04).
    end

    {% if flag?(:darwin) %}
      # Darwin: MADV_FREE_REUSABLE drops RSS, and this used to be **on by
      # default** here — the one platform where the free-page walk shipped
      # enabled, and where it visits every kept size-class chunk rather than
      # only the HOLED ones.
      #
      # It is opt-in now, matching Linux. The walk was unsound until
      # 2026-09-04 (a free-page run computed from headers, then a syscall with
      # the world running, so a TLAB could hand a block out in between); it now
      # runs under every lock a small allocation of the class can take, on
      # both platforms. It stays off here because the gate has no Darwin
      # runner: the Linux fix is measured, the Darwin one is read from the
      # code. `GCRY_PAGE_DONTNEED=1` turns it on; the escape hatches keep
      # working for anyone who does.
      if env_flag_one?("GCRY_PAGE_DONTNEED") &&
         !(env_flag_one?("GCRY_DISABLE_MADVISE") || env_flag_one?("GCRY_DISABLE_PAGE_RELEASE"))
        heap.madvise_free_pages = true
      else
        heap.madvise_free_pages = false
      end
    {% elsif flag?(:linux) %}
      # Linux HOLED free-page release stays OPT-IN (`GCRY_PAGE_DONTNEED=1`).
      # Default-on was measured to regress Kemal and acik thr/RSS: HOLED freelist
      # rebuild blows sweep cost and abandoned free pages cause chunk churn.
      #
      # Tight small-heap growth: prefer newest-chunk freelist + sparse
      # GC-before-grow. Acik med3 ~103% thr @ ~0.92× RSS (vs ~1.56× control).
      # Opt-in until Kemal reconfirm; then consider Linux process default.
      #   GCRY_TIGHT_GROW=1 / GCRY_DISABLE_TIGHT_GROW=1 / GCRY_DISABLE_TIGHT_GROW_GC=1
      if env_flag_one?("GCRY_TIGHT_GROW")
        heap.tight_grow = true
      end
      if env_flag_one?("GCRY_DISABLE_TIGHT_GROW")
        heap.tight_grow = false
      end
      if env_flag_one?("GCRY_DISABLE_TIGHT_GROW_GC")
        heap.tight_grow_gc = false
      end
      #
      # Mostly-empty (HOLED-less) is a separate research knob:
      #   GCRY_MOSTLY_EMPTY=1           — MADV_FREE free pages in ≤25%-live chunks
      #   GCRY_MOSTLY_EMPTY_MODE=dontneed — unlink free-only runs + DONTNEED (churn risk)
      #   GCRY_MOSTLY_EMPTY_PCT / GCRY_MOSTLY_EMPTY_BUDGET
      # Ignored when PAGE_DONTNEED is on (HOLED owns the path).
      if env_flag_one?("GCRY_MOSTLY_EMPTY") && !heap.madvise_free_pages
        heap.mostly_empty_release = true
        if pct = env_u64("GCRY_MOSTLY_EMPTY_PCT")
          # Avoid NamedTuple/clamp alloc during GC.init — clamp manually.
          p = pct
          p = 1_u64 if p < 1
          p = 100_u64 if p > 100
          heap.mostly_empty_max_live_pct = p.to_u32
        end
        if budget = env_u64("GCRY_MOSTLY_EMPTY_BUDGET")
          heap.mostly_empty_budget = budget
        end
        # Gcry::OS.getenv only — ENV[] allocates and can SEGV during GC.init.
        mode = Gcry::OS.getenv("GCRY_MOSTLY_EMPTY_MODE")
        unless mode.null?
          # "dontneed" (case-sensitive ASCII); any other value keeps MADV_FREE.
          # Measured REJECT on acik (COLLECT_HANG 2/3) — research only.
          heap.mostly_empty_dontneed =
            mode[0] == 'd'.ord.to_u8 && mode[1] == 'o'.ord.to_u8 &&
              mode[2] == 'n'.ord.to_u8 && mode[3] == 't'.ord.to_u8 &&
              mode[4] == 'n'.ord.to_u8 && mode[5] == 'e'.ord.to_u8 &&
              mode[6] == 'e'.ord.to_u8 && mode[7] == 'd'.ord.to_u8 &&
              mode[8] == 0
          if heap.mostly_empty_dontneed
            warn_unsupported_env("gcry: GCRY_MOSTLY_EMPTY_MODE=dontneed is research-only (COLLECT_HANG risk); not a product default\n")
          end
        end
      end
    {% end %}

    # Both free-page release paths stand down on every bitmap-allocated chunk
    # (`bitmap_alloc_chunk?` in the sweep and the flush): their machinery is
    # freelist-shaped end to end, and engaging it on `occ` chunks corrupted
    # (`collect_sweep.cr`). The bitmap allocator is the only one on the
    # headerless default and the default on the header layout too, so without
    # this both knobs are silently inert for nearly everyone who sets them —
    # measured 2026-09-23: 0 bytes released on either layout's default, where
    # the header layout with `GCRY_BITMAP_ALLOC=0` released 72 MB and 104 MB.
    # Nursery chunks are header-based and still reached, so a heap with one
    # does not warn. `make ignored-knob-warnings` asserts all three cases.
    # `GCRY_PAGE_RELEASE_BITMAP_WALK=1` (research, read further down) removes
    # the flush stand-down on purpose and does release bitmap-chunk tail slack
    # (208 KiB on Darwin), so with it set the knob is not ignored.
    if (heap.madvise_free_pages || heap.mostly_empty_release) &&
       heap.bitmap_alloc? && !heap.nursery_enabled &&
       !(heap.madvise_free_pages && env_flag_one?("GCRY_PAGE_RELEASE_BITMAP_WALK"))
      # Literals only: this runs inside GC.init, where a concatenation would
      # allocate from the heap being configured.
      warn_unsupported_env(heap.madvise_free_pages ? "gcry: GCRY_PAGE_DONTNEED=1" : "gcry: GCRY_MOSTLY_EMPTY=1")
      {% if flag?(:gcry_block_headers) %}
        warn_unsupported_env(
          " is ignored on the bitmap allocator (the default here too): free-page " \
          "release walks freelist chunks only, and this heap has none. " \
          "GCRY_BITMAP_ALLOC=0 selects the freelist it needs, at a higher RSS than " \
          "the bitmap allocator reaches without it (docs/HARDENING.md)\n"
        )
      {% else %}
        warn_unsupported_env(
          " is ignored on the headerless layout (the compile default): free-page " \
          "release walks freelist chunks only, and a headerless heap has none. " \
          "Rebuild with -Dgcry_block_headers and set GCRY_BITMAP_ALLOC=0 to run it, " \
          "at a higher RSS than this layout reaches without it (docs/HARDENING.md)\n"
        )
      {% end %}
    end

    if env_flag_one?("GCRY_DISABLE_INTERIOR")
      heap.allow_interior_pointers = false
    end

    # Misaligned candidate *values* (interiors into byte buffers) are followed
    # by default; GCRY_ALIGNED_CANDIDATES=1 forces the cheap alignment filter
    # back on so its cost can be measured apart.
    if env_flag_one?("GCRY_ALIGNED_CANDIDATES")
      heap.scan_unaligned_candidates = false
    end

    # Research only: the static-root type_id gate, the default until
    # 2026-09-29. `make static-raw-buffer-roots` is its red arm.
    heap.type_id_gate = true if env_flag_one?("GCRY_TYPE_ID_GATE")

    if env_flag_one?("GCRY_DISABLE_STATIC_ROOTS")
      heap.scan_static_roots = false
    end

    if env_flag_one?("GCRY_BLACKLIST")
      heap.blacklist_enabled = true
    end

    if env_flag_one?("GCRY_DISABLE_LAYOUT")
      heap.layout_precise = false
      Gcry::Layout.enabled = false
    end

    # GCRY_DISABLE_AUTO_LAYOUTS is handled in GC.init (before apply_env_config).
    # The env var is listed here for discoverability — GC.init already checked it.

    if env_flag_one?("GCRY_DISABLE_SP_CLAMP")
      Gcry::Platform.stw_sp_clamp_enabled = false
    end

    # Free large-object bytes to retain after post-collect trim
    # (Linux process 4 MiB / Darwin 1 MiB; override via GCRY_LARGE_CACHE).
    if cache = env_u64("GCRY_LARGE_CACHE")
      heap.large_cache_retain = cache
    end

    # Size-class chunk mmap size (default 128 KiB; macOS process GC bumps to 256 KiB).
    # Must be ≥64 KiB, page-aligned, and no larger than the bound the block
    # ordinal's magic reciprocal is exact to — past that a block address would
    # resolve to the wrong ordinal, silently, on the collector's hottest path.
    # That bound depends on the layout (51.2 MiB headerless, 86.3 MiB under
    # `-Dgcry_block_headers`) and is a **method**: as a constant it would be
    # `once`-initialised, and this code runs inside `GC.init`, before Crystal's
    # runtime — where it read 0 and rejected every legal value.
    if chunk_bytes = env_u64("GCRY_CHUNK_BYTES")
      if chunk_bytes >= Gcry::Heap::MIN_SMALL_CHUNK_BYTES &&
         chunk_bytes <= Gcry::Heap.max_reciprocal_chunk_bytes &&
         (chunk_bytes % 4096_u64) == 0
        heap.small_chunk_bytes = chunk_bytes
      end
    end

    # Torture: collect every N allocs (CI / dogfood).
    if env_flag_one?("GCRY_STRESS")
      every = env_u64("GCRY_STRESS_EVERY") || 16_u64
      heap.stress_every = every.to_i32 if every > 0 && every <= Int32::MAX
    end

    # Knobs the headerless layout — the compile default since 0.26.0 — cannot
    # honour, because it has no per-block header for a freelist link or a
    # NURSERY flag to live in. Their reads are compiled out on that layout, so
    # without this they are silently inert: `GCRY_BITMAP_ALLOC=0` was the
    # documented escape for a workload that cares about RSS more than
    # throughput, and a user who upgrades into a changed default deserves to
    # be told rather than to measure no difference and wonder. One line per
    # knob, and it names the way back. `make ignored-knob-warnings` asserts
    # both directions.
    {% unless flag?(:gcry_block_headers) %}
      if env_flag_zero?("GCRY_BITMAP_ALLOC")
        warn_unsupported_env(
          "gcry: GCRY_BITMAP_ALLOC=0 is ignored on the headerless layout (the compile " \
          "default): a headerless block has no header for the freelist to thread a link " \
          "through. Rebuild with -Dgcry_block_headers for the freelist allocator. " \
          "Headerless is the lower-RSS layout of the two, so this is likely not the knob " \
          "you want — see docs/HARDENING.md\n"
        )
      end
      if (n = env_u64("GCRY_NURSERY")) && n != 0
        warn_unsupported_env(
          "gcry: GCRY_NURSERY is ignored on the headerless layout (the compile default): " \
          "nursery chunks keep the header representation. Rebuild with " \
          "-Dgcry_block_headers to run one — it is off by default there too, and off " \
          "because it is unsound without a barrier (docs/HARDENING.md)\n"
        )
      end
    {% end %}

    # TLAB is freelist-shaped: the bitmap cursor replaces it, and
    # `tlab_enabled=` refuses it whenever that allocator is on — which the
    # headerless default forces. On the header layout it is merely unsupported
    # under Parallel EC. One warning either way, naming which case this is.
    if env_flag_one?("GCRY_TLAB")
      {% if flag?(:gcry_block_headers) %}
        warn_unsupported_env(
          "gcry: WARNING: GCRY_TLAB=1 is unsupported under Parallel EC " \
          "(supported path: TLAB off + lazy). Soft-soak/SEGV risk — see docs/POLICY.md\n"
        )
      {% else %}
        warn_unsupported_env(
          "gcry: GCRY_TLAB=1 is ignored on the headerless layout (the compile default): " \
          "the per-thread allocation buffer is freelist-shaped and the bitmap cursor " \
          "replaces it. Rebuild with -Dgcry_block_headers to A/B it\n"
        )
      {% end %}
      heap.tlab_enabled = true
    end
    heap.tlab_quiesce = false if env_flag_zero?("GCRY_TLAB_QUIESCE")
    # TLAB-off: batch-pop N size-class nodes under freelist lock (USED stash).
    # Amortizes lock vs lazy sweep. Clamped 1..64; ignored when TLAB is on.
    if ab = env_u64("GCRY_ALLOC_BATCH")
      if ab >= 1 && ab <= 64
        heap.alloc_batch = ab.to_i32
      end
    end
    if min_live = env_u64("GCRY_PARALLEL_MARK_MIN_LIVE")
      heap.parallel_mark_min_live = min_live
    end
    if pm = env_u64("GCRY_PARALLEL_MARK")
      heap.parallel_mark_workers = pm.to_i32 if pm >= 1 && pm <= 16
    end
    # Research only: pin mark workers at 1 even if a later assignment asks
    # for more. `make parallel-mark-process --disabled` is the red arm —
    # stolen stays 0. Dropping the skip reddens it.
    heap.force_serial_mark = true if env_flag_one?("GCRY_DISABLE_PARALLEL_MARK")
    # Research only: invalidate the bitmap pool index on every take, so each
    # refill walks the class again. `make pool-refill-cost --disabled` is the
    # red arm — rebuilds per collection exceed the per-version floor.
    heap.pool_index_disabled = true if env_flag_one?("GCRY_DISABLE_POOL_INDEX")
    # Research only: gate nursery mark clear on the global `@bitmap_marks`
    # flag. `make nursery-bitmap-marks --disabled` is the red arm — a
    # child reachable only through a marked nursery parent is swept.
    heap.nursery_marks_global = true if env_flag_one?("GCRY_NURSERY_MARKS_GLOBAL")
    # Research only: the pre-2026-09-04 pop/busy protocol, which lets the
    # master end a mark cycle while a worker still holds a batch.
    heap.mark_busy_unlocked = true if env_flag_one?("GCRY_MARK_BUSY_UNLOCKED")
    # Multi-mutator parked-fiber scan depth below stack_top (bytes). Default 0,
    # the whole touched stack; a non-zero lag trades completeness for pause.
    if lag = env_u64("GCRY_STW_STACK_LAG")
      heap.stw_multi_stack_lag = lag
    end
    # Escape hatch for the low-water skip. It preserves semantics (untouched
    # pages are zero), so this exists to A/B its cost and to disable it on a
    # kernel whose pagemap misbehaves. `make stw-lag-pause --disabled` is the
    # red arm — default-path skips stay 0. Dropping the assignment reddens it.
    if env_flag_zero?("GCRY_STACK_LOW_WATER")
      heap.stack_low_water_scan = false
    end
    # With a non-zero `GCRY_STW_STACK_LAG`, a parked fiber is scanned from its
    # saved `stack_top` when every thread that can run a fiber has a recorded
    # SP. `0` keeps the lag window for all of them (A/B, and the escape hatch).
    heap.parked_fiber_sp = false if env_flag_zero?("GCRY_PARKED_FIBER_SP")
    # `GC.collect`, idle and emergency collections make a multi-mutator heap's
    # empty chunks dormant; `0` keeps them mapped (A/B, escape hatch).
    heap.parallel_release_on_collect = false if env_flag_zero?("GCRY_PARALLEL_RELEASE_ON_COLLECT")
    # Darwin: prove a large range untouched from the VM object's resident count
    # instead of asking about every page (`platform/darwin_low_water.cr`).
    # `0` restores the per-page query everywhere — A/B, and the red arm of
    # `stw_lag_pause --resident-off`.
    {% if flag?(:darwin) %}
      Gcry::Platform.resident_low_water = false if env_flag_zero?("GCRY_DARWIN_RESIDENT_LOW_WATER")
      # Dormant chunks and the large cache release with `MADV_FREE_REUSABLE`;
      # `0` restores `MADV_FREE`, the red arm of `make parallel-dormant`.
      Gcry::Platform.reusable_release = false if env_flag_zero?("GCRY_DARWIN_REUSABLE")
    {% end %}
    # Multi-mutator pthread map when SP is off the OS stack (on a pool fiber).
    # Default 0, the full mapping; a non-zero lag scans that many bytes from
    # stack high.
    if plag = env_u64("GCRY_STW_PTHREAD_LAG")
      heap.stw_multi_pthread_lag = plag
    end

    # Boehm-style stack hygiene (no compiler maps). Opt-in; measure RSS/thr.
    if env_flag_one?("GCRY_CLEAR_STACK")
      heap.clear_stack_enabled = true
      # Every-alloc wipe tanks HTTP thr; default to every 16 unless overridden.
      heap.clear_stack_every = 16
    end
    if csb = env_u64("GCRY_CLEAR_STACK_BYTES")
      heap.clear_stack_bytes = csb if csb >= 64 && csb <= 1024_u64 * 1024
    end
    # `GCRY_ALLOC_FAST_PATH=0`: every small allocation takes the locked path
    # (diagnosis and A/B only).
    if (v = Gcry::OS.getenv("GCRY_ALLOC_FAST_PATH")) && !v.null? && v.value == 0x30_u8 && (v + 1).value == 0_u8
      heap.fast_path_enabled = false
    end
    if scrub = env_u64("GCRY_COLLECT_SCRUB")
      heap.collect_scrub_bytes = scrub if scrub <= 1024_u64 * 1024
    end
    # Research only: the collector scrub's bounds from libc, which is a
    # `/proc/self/maps` parse per call on the initial thread.
    heap.scrub_libc_bounds = true if env_flag_one?("GCRY_SCRUB_LIBC_BOUNDS")
    if cse = env_u64("GCRY_CLEAR_STACK_EVERY")
      heap.clear_stack_every = cse.to_i32 if cse >= 1 && cse <= Int32::MAX
    end
    if env_flag_one?("GCRY_SCRUB_FIBERS")
      heap.scrub_fibers_enabled = true
    end
    if env_flag_one?("GCRY_DISABLE_SCRUB_FIBERS")
      heap.scrub_fibers_enabled = false
    end
    # Audit the EC1 foreign-SP exemption in scrub_parked_fiber_stacks. Costs a
    # thread walk per parked fiber, so it is opt-in — see docs/SOUND-DEFAULTS.md.
    if env_flag_one?("GCRY_SCRUB_AUDIT")
      heap.scrub_audit_foreign_sp = true
    end
    # Parallel parked-fiber scrub window below saved SP (default 512).
    if fsb = env_u64("GCRY_FIBER_SCRUB_BYTES")
      heap.fiber_scrub_bytes = fsb if fsb >= 64 && fsb <= 8192
    end
    # The Monitor runs inside the stopped world unless it is handshaken out
    # (src/gcry/monitor_gate.cr). Default on; 0 restores the old behaviour for A/B.
    Gcry::MonitorGate.enabled = false if env_flag_zero?("GCRY_MONITOR_GATE")
    # A hang with the world stopped is otherwise silent — every mutator is in
    # sigsuspend and /gc-stats cannot answer. Arms a raw watcher thread that
    # prints which phase is stuck. Default off; see src/gcry/stw_watchdog.cr.
    if wd = env_u64("GCRY_STW_WATCHDOG_MS")
      Gcry::StwWatchdog.threshold_ms = wd if wd > 0
    end
    # One releasing collection once the process has not allocated for N ms
    # (src/gcry/idle_release.cr). **On by default at two minutes** — Go's
    # forced-GC period; `GCRY_IDLE_RELEASE_MS=0` turns it
    # off. Two minutes, not seconds: a shorter delay releases chunks the next
    # burst faults straight back in, which is the churn the warm budget and the
    # unmap grace exist to prevent. Windows too since 2026-10-03, once its
    # gates job could run `make idle-release` and `idle-thread-roots`; there,
    # as on Darwin, the stop suspends the idle thread like any other. Never
    # under `-Dwithout_mt`, where `Crystal::SpinLock` compiles to nothing and a
    # collection from a second thread would take none of the locks it needs.
    # It warns only when the knob is set, since off is simply its default.
    idle_env = env_u64("GCRY_IDLE_RELEASE_MS")
    {% if flag?(:without_mt) %}
      if idle_env && idle_env > 0
        warn_unsupported_env("gcry: GCRY_IDLE_RELEASE_MS is ignored under -Dwithout_mt: " \
                             "the locks a collection from another thread needs compile to nothing there\n")
      end
    {% else %}
      Gcry::IdleRelease.idle_ms = idle_env || Gcry::IdleRelease::DEFAULT_MS
    {% end %}
    # Research only, `make idle-thread-roots`: a block held only by the idle
    # thread's stack, and the pre-0.27.1 skip of that stack as the red arm.
    Gcry::IdleRelease.test_hold = true if env_flag_one?("GCRY_IDLE_TEST_HOLD")
    heap.idle_scan_skip = true if env_flag_one?("GCRY_IDLE_SCAN_SKIP")
    # Research only, `make oom-no-hang`: build an out-of-memory message before
    # `oom!` is entered, as the call sites did before 2026-09-24; and fail
    # every small allocation the reserve does not serve once one has failed.
    heap.oom_eager_message = true if env_flag_one?("GCRY_OOM_EAGER_MESSAGE")
    heap.oom_test_exhausted = true if env_flag_one?("GCRY_OOM_TEST_EXHAUSTED")
    # Research only, `make index-grow-race`: the pre-2026-09-25 order (the old
    # chunk index freed before the new one is published), and a stall there.
    heap.index_grow_free_first = true if env_flag_one?("GCRY_INDEX_GROW_FREE_FIRST")
    if stall = env_u64("GCRY_INDEX_GROW_TEST_STALL_MS")
      heap.index_grow_stall_ms = stall.clamp(0_u64, 1000_u64).to_u32
    end
    # Walk the Parallel EC run queues inside STW and check every slot is still a
    # live Fiber (bench/ec_queue_audit.cr). Off by default — bounded, but inside
    # the pause. The soak turns it on: it is what turns the 2026-08-10 SEGV from
    # "an hour after the write" into "the first collection after it".
    heap.ec_queue_audit = true if env_flag_one?("GCRY_EC_QUEUE_AUDIT")
    # Overwrite freed payloads so a use-after-free reads 0xdeadf2ee… instead of
    # something that looks like data (bench/poison_freed.cr). Costs a memset per
    # free; the soak turns it on.
    heap.poison_freed = true if env_flag_one?("GCRY_POISON_FREED")
    # `GCRY_POISON_TAG=1` implies the poison — asking for the tag and not getting
    # poisoned blocks would be a knob that silently does nothing.
    if env_flag_one?("GCRY_POISON_TAG")
      heap.poison_freed = true
      heap.poison_tag_addr = true
    end
    # Explain the address a crash died on against the heap's own tables
    # (src/gcry/segv_report.cr). Costs nothing until something faults; default
    # off because it installs a signal handler, and a collector should not do
    # that to a process that did not ask.
    {% if flag?(:unix) %}
      Gcry::SegvReport.request if env_flag_one?("GCRY_SEGV_REPORT")
      # Twin of the mapping line `make segv-region-report` asserts: skip it,
      # so a fault outside the span is back to "never a gcry allocation"
      # and nothing about the mapping. Research only.
      Gcry::SegvReport.skip_region if env_flag_one?("GCRY_DISABLE_REGION_REPORT")
    {% end %}
    # After mark, before sweep: does any marked object point at a block the
    # sweep is about to free? (src/gcry/mark_audit.cr). Off by default —
    # O(live heap) inside the pause.
    heap.always_clear = true if env_flag_one?("GCRY_ALWAYS_CLEAR")
    if q = env_u64("GCRY_RELEASE_QUARANTINE")
      heap.release_quarantine = q
    end
    heap.mark_audit = true if env_flag_one?("GCRY_MARK_AUDIT")
    if every = env_u64("GCRY_MARK_AUDIT_EVERY")
      heap.mark_audit_every = every
    end
    if v = env_u64("GCRY_DYING_AUDIT_MIN_BYTES")
      heap.dying_audit_min_bytes = v
    end
    if v = env_u64("GCRY_MARK_TEST_SHORT_TID")
      heap.mark_test_short_tid = v.to_i32
    end
    if env_flag_one?("GCRY_DYING_REGISTER_AUDIT")
      heap.mark_audit = true
      heap.dying_register_audit = true
    end
    # Which unowned stack does the crash need — the pooled one or the one in
    # flight? (src/gcry/unowned_stack_roots.cr). Each window has a rooting arm
    # and a walk-but-offer-nothing arm, because an arm that roots more can take
    # a crash rate to zero without being the mechanism.
    heap.pooled_stack_roots = true if env_flag_one?("GCRY_POOLED_STACK_ROOTS")
    heap.pooled_stack_noroot = true if env_flag_one?("GCRY_POOLED_STACK_NOROOT")
    # The fix: root the stack a thread is holding for a fiber that is
    # terminating (src/gcry/unowned_stack_roots.cr). **On** by default — it
    # closes a use-after-free, and a root source that ships off is the shape of
    # both defects v0.19.0 had to go back for.
    heap.dead_stack_roots = false if env_flag_zero?("GCRY_DEAD_STACK_ROOTS")
    heap.dead_stack_noroot = true if env_flag_one?("GCRY_DEAD_STACK_NOROOT")
    heap.maps_inflight_roots = true if env_flag_one?("GCRY_MAPS_INFLIGHT_ROOTS")
    heap.maps_inflight_noroot = true if env_flag_one?("GCRY_MAPS_INFLIGHT_NOROOT")
    heap.unowned_coverage_audit = true if env_flag_one?("GCRY_UNOWNED_COVERAGE_AUDIT")
    # Where in the address space does a dying block's value actually live?
    # (src/gcry/address_space_audit.cr). Implies the dying audit: it is that
    # audit's unreferenced branch that asks the question. Off by default and
    # very expensive — it reads the resident address space inside the pause.
    if env_flag_one?("GCRY_ADDRESS_SPACE_AUDIT")
      heap.mark_audit = true
      heap.dying_register_audit = true
      heap.address_space_audit = true
    end
    # Is a `Thread` — or any type asked for by id — about to be swept, and what
    # holds its address when it is? (src/gcry/thread_block_audit.cr). Implies
    # the address-space audit, because "a Thread died" without the region that
    # held it is the fact the last eight CI sightings already established.
    # `GCRY_ADDRESS_SPACE_AUDIT=0` below drops the expensive half and leaves the
    # report.
    if env_flag_one?("GCRY_THREAD_BLOCK_AUDIT")
      heap.thread_block_audit = true
      heap.address_space_audit = true
    end
    # Aim the same arm at another type. The gate uses it to point the audit at a
    # type whose death it controls, which is the only way its silence can be
    # read as evidence.
    if tid = env_u64("GCRY_DYING_TYPE_ID")
      if tid > 0 && tid <= UInt32::MAX
        heap.dying_type_id = tid.to_u32
        heap.thread_block_audit = true
        heap.address_space_audit = true
      end
    end
    # The off switch for the walk of the resident address space, so the cheap
    # half of either audit can run on its own.
    heap.address_space_audit = false if env_flag_zero?("GCRY_ADDRESS_SPACE_AUDIT")
    if env_flag_one?("GCRY_MARK_AUDIT_ALL")
      heap.mark_audit = true
      heap.mark_audit_all_parents = true
    end
    # Count the threads the OS has against the ones Crystal's list yields, at
    # every stop_world (src/gcry/platform/linux_thread_census.cr). Off by
    # default: it reads /proc inside the pause.
    heap.thread_census = true if env_flag_one?("GCRY_THREAD_CENSUS")
    # The twin: count the gap and do not name it, which is what the census did
    # until 2026-09-19. `make thread-census-names` runs both directions.
    heap.thread_census_names = false if env_flag_zero?("GCRY_THREAD_CENSUS_NAMES")
    # Root the `Thread` object from `pthread_create` until the thread publishes
    # itself (src/gcry/thread_birth_root.cr). **On** by default: it closes a
    # use-after-free, and it is one `add_root` per thread created.
    Gcry::ThreadBirthRoot.enabled = false if env_flag_zero?("GCRY_THREAD_BIRTH_ROOT")
    # The twin: record every birth and root nothing, so a run that survives is
    # not credited to the bookkeeping.
    Gcry::ThreadBirthRoot.noroot = true if env_flag_one?("GCRY_THREAD_BIRTH_NOROOT")
    # Research only: a birth that finds no slot goes unrooted, which is what the
    # table used to do to every birth past the 64th between two collections.
    Gcry::ThreadBirthRoot.overflow_unrooted = true if env_flag_one?("GCRY_THREAD_BIRTH_OVERFLOW_UNROOTED")
    # Research only: never release a birth root on a thread's death, so a
    # root ends only where it used to — when `stop_world` finds the thread on
    # Crystal's list. The control arm for `make thread-birth-root --churn`.
    Gcry::ThreadBirthRoot.track_deaths = false if env_flag_zero?("GCRY_THREAD_BIRTH_DEATHS")
    # Research only: keep the pthread stack-bounds snapshot at its initial size
    # instead of growing it, which is what a thread list longer than 64 used to
    # run into (src/gcry/platform/linux_stack.cr).
    Gcry::Platform.stack_bounds_nogrow = true if env_flag_one?("GCRY_STACK_BOUNDS_NOGROW")
    # Research only: refuse a BSS larger than 1 MiB as a root range, which is
    # what the maps parser did before 2026-08-22 and what
    # `make static-bss-roots` uses to show the block dying.
    Gcry::Platform.bss_size_cap = true if env_flag_one?("GCRY_STATIC_BSS_CAP")
    # Research only: per dead word, ask every cursor set whether it is
    # mid-allocation inside a block the after-world sweep just called dead.
    heap.sweep_occ_audit = true if env_flag_one?("GCRY_SWEEP_OCC_AUDIT")
    # Research only: does `@chunk_index` agree with the `@chunks` list? A chunk
    # in one and not the other is never swept and never has its marks cleared.
    heap.chunk_list_audit = true if env_flag_one?("GCRY_CHUNK_LIST_AUDIT")
    # Research only: after the mark clear, does any chunk the *index* knows
    # about still hold a set mark bit?
    heap.mark_clear_audit = true if env_flag_one?("GCRY_MARK_CLEAR_AUDIT")
    # Control arm: clear marks over the chunk list rather than the index.
    # `make mark-clear-index --control` and `make thread-churn-uaf --control`.
    heap.mark_clear_list = true if env_flag_one?("GCRY_MARK_CLEAR_LIST")
    # Research only: go back to re-evaluating the mutator count per decision
    # instead of latching it in the stop. The trigger half of
    # `make mark-clear-index` and `make thread-churn-uaf`.
    heap.sweep_mutator_latch = false if env_flag_zero?("GCRY_SWEEP_MUTATOR_LATCH")
    # Research only: run the holders search at every large release, so a live
    # block being let go names its holder then instead of a hundred
    # collections later at the fault. Walks the heap and every stack per
    # release, with the world up.
    heap.release_holders = true if env_flag_one?("GCRY_RELEASE_HOLDERS")
    # The main thread's thread-local storage is a root (Linux 2026-09-12,
    # Darwin and Windows 2026-09-15). Off is the pre-fix behaviour, which
    # `make tls-roots` needs as its red arm. Locating the live block is
    # platform-specific — `/proc/self/maps` on Linux, `mach_vm_region` on
    # Darwin, `VirtualQuery` on Windows — but the question is the same: a
    # `@[ThreadLocal]` is not in the executable's writable image, and the
    # main thread's copy is not on its stack.
    {% if flag?(:linux) || flag?(:darwin) || flag?(:win32) %}
      Gcry::Platform.tls_roots = false if env_flag_zero?("GCRY_TLS_ROOTS")
    {% end %}
    # Resolve the static roots now, on the main thread and before any other
    # thread exists: Linux reads the executable's program headers, which takes
    # the loader's lock, and Darwin walks dyld's image 0 and `realloc`s the
    # range cache. Neither is something to do first inside a stopped world
    # holding whatever locks the suspended threads hold.
    #
    # Both platforms as of 2026-09-04. Darwin was excluded because doing this
    # crashed `crystal spec -Dgc_none process_spec` on the macOS runner (CI
    # 33900305015) with no host to attribute it on. The host now exists and the
    # mechanism was named: two of `darwin_roots.cr`'s class variables had
    # initialisers the compiler wraps in `__crystal_once`, `GC.init` runs
    # before `Crystal.main` reaches `init_runtime`, and `__crystal_once` there
    # reaches `Fiber.current` -> `Thread.new` -> `Fiber.new` ->
    # `Fiber.@@fibers.push` on a null class variable. Fixed at the
    # declarations, not here (src/gcry/platform/darwin_roots.cr).
    #
    # Research only: `GCRY_STATIC_ROOT_LAZY=1` skips this, which puts the
    # first walk back inside the first stopped world. It is the red arm of
    # `make darwin-static-root-init`.
    unless env_flag_one?("GCRY_STATIC_ROOT_LAZY")
      Gcry::Platform.ensure_static_root_cache
    end
    # Research only: a full staging table refuses the birth being handed in
    # rather than evicting the oldest, which is what it did before 2026-08-22
    # (src/gcry/platform/thread_staging.cr).
    Gcry::Platform.staged_no_evict = true if env_flag_one?("GCRY_STAGED_NO_EVICT")
    # Research only, and a **reproducer for an open defect**: drop a thread's
    # staging record when it dies. Right on its face, and it crashes — the
    # pre-stop wait's spin budget is what has been giving a dying thread time
    # to leave the window where it is off Crystal's list and still using
    # itself (src/gcry/platform/thread_staging.cr).
    Gcry::Platform.unstage_on_death = true if env_flag_one?("GCRY_THREAD_UNSTAGE_ON_DEATH")
    # Research only: let the dying-type audit walk every block on a minor
    # collection, where unmarked does not mean dying
    # (src/gcry/thread_block_audit.cr).
    heap.dying_audit_all_collections = true if env_flag_one?("GCRY_DYING_AUDIT_ALL_COLLECTIONS")
    # Count unlocked chunk-index reads taken during a stop by a thread that is
    # not the one that stopped the world (src/gcry/heap.cr `chunk_containing`).
    heap.index_audit = true if env_flag_one?("GCRY_INDEX_AUDIT")
    # Research only: release chunks with mprotect(PROT_NONE) instead of munmap,
    # so a fault in released memory can be told which chunk it was and when
    # (src/gcry/collect.cr `guard_release`).
    heap.unmap_guard = true if env_flag_one?("GCRY_UNMAP_GUARD")
    # Research only: trim the large cache without the allocator lock, which is
    # what it did before 2026-08-23 (src/gcry/heap.cr `trim_large_cache`).
    heap.trim_unlocked = true if env_flag_one?("GCRY_TRIM_UNLOCKED")
    heap.trim_immediate = true if env_flag_one?("GCRY_TRIM_IMMEDIATE")
    heap.madvise_unchecked = true if env_flag_one?("GCRY_MADVISE_UNCHECKED")
    heap.large_release_from_base = true if env_flag_one?("GCRY_LARGE_RELEASE_FROM_BASE")
    heap.mark_prefetch = false if env_flag_zero?("GCRY_PREFETCH")
    if pfw = env_u64("GCRY_ALLOC_PFW")
      heap.alloc_pfw = pfw
    end
    heap.hugepages = true if env_flag_one?("GCRY_HUGEPAGES")
    heap.release_ledger = true if env_flag_one?("GCRY_RELEASE_LEDGER")
    heap.trace_large = true if env_flag_one?("GCRY_TRACE_LARGE")
    heap.monitor_gate_late_close = true if env_flag_one?("GCRY_MONITOR_GATE_LATE_CLOSE")
    heap.empty_flush_unlocked = true if env_flag_one?("GCRY_EMPTY_FLUSH_UNLOCKED")
    Gcry::MonitorGate.test_spawn = true if env_flag_one?("GCRY_MONITOR_GATE_TEST_SPAWN")
    heap.page_release_unchecked = true if env_flag_one?("GCRY_PAGE_RELEASE_UNCHECKED")
    # Research only: let the Darwin free-page walk visit bitmap-allocated
    # chunks, which is the stand-down in `flush_pending_page_release_chunks`
    # turned off. `make darwin-bitmap-page-release` is the gate.
    heap.page_release_bitmap_walk = true if env_flag_one?("GCRY_PAGE_RELEASE_BITMAP_WALK")
    # Research only: grace every emptied chunk past the warm budget, as before
    # the threshold cap. `make idle-rss-after-burst` is the gate.
    heap.unmap_grace_unbounded = true if env_flag_one?("GCRY_UNMAP_GRACE_UNBOUNDED")
    # Research only: restore the last-chunk cache read that crashed
    # `find_block` (src/gcry/heap.cr `chunk_containing_unlocked`).
    heap.index_cache_unchecked = true if env_flag_one?("GCRY_INDEX_CACHE_UNCHECKED")
    # Research only: the pre-2026-08-22 `start_world` ordering, where every
    # thread is resumed while `@world_stopped` still says stopped.
    heap.stw_late_clear = true if env_flag_one?("GCRY_STW_LATE_CLEAR")
    # Research only: how long the suspend wait spins before it asks whether the
    # thread it is waiting for still exists (src/gcry/collect_stw.cr).
    if ss = env_u64("GCRY_SUSPEND_STALL_SPINS")
      heap.suspend_stall_spins = ss
    end
    # The suspend resend, and the epoch that makes it safe
    # (src/gcry/platform/linux_stw.cr). Both **on** by default; the two zeros
    # are the control arms `make stw-epoch` needs, and each is red on its own:
    # without the resend a dropped signal hangs the stop, without the epoch a
    # duplicate suspends a thread nothing will resume.
    heap.suspend_resend = false if env_flag_zero?("GCRY_STW_RESEND")
    if rs = env_u64("GCRY_STW_RESEND_SPINS")
      heap.suspend_resend_spins = rs
    end
    if rl = env_u64("GCRY_STW_RESEND_LIMIT")
      heap.suspend_resend_limit = rl.to_u32 if rl <= 1_000_000
    end
    {% if flag?(:linux) %}
      Gcry::Platform.stw_epoch_enabled = false if env_flag_zero?("GCRY_STW_EPOCH")
      # Research: acknowledge the suspend through `Thread#@suspended`, as the
      # handler did before the slot table. That path calls `::Thread.current`,
      # which *creates* a `Thread` when the TLS key is unset — an allocation
      # and a `Thread.lock` acquisition inside a signal handler with the world
      # stopping (src/gcry/platform/linux_stw.cr).
      Gcry::Platform.stw_ack_via_thread = true if env_flag_one?("GCRY_STW_ACK_VIA_THREAD")
    {% end %}
    {% if flag?(:darwin) %}
      # Research: resume the world from the 64-entry port table, as this
      # platform did before the thread list became the record. The stop
      # suspends every thread unconditionally, so past 64 threads that table is
      # short and the rest are never resumed — the red arm for
      # `make darwin-stw-resume`
      # (src/gcry/platform/darwin_stw.cr).
      Gcry::Platform.stw_bounded_resume = true if env_flag_one?("GCRY_STW_BOUNDED_RESUME")
    {% end %}
    # Research: make an explicit `GC.collect` return the moment any thread is
    # collecting, as it did before the guard told a peer's cycle apart from this
    # thread's own. Under load that is a silent no-op — 6 of 85 682 calls did
    # anything with 70 allocating threads — and it is the red arm for
    # `make explicit-collect-barrier` (src/gcry/collect.cr).
    heap.collect_skip_when_busy = true if env_flag_one?("GCRY_COLLECT_SKIP_WHEN_BUSY")
    {% if flag?(:linux) || flag?(:darwin) || flag?(:win32) %}
      # Research: pin the STW capture table at the 64 slots that shipped. That
      # bound cost Darwin the 65th thread's registers — `thread_get_state` is
      # their only copy — and cost Windows the whole collection, which it
      # refused rather than run uncovered. The red arm for
      # `make stw-capture-coverage` (src/gcry/stw_slots.cr).
      Gcry::Platform.stw_fixed_slots = true if env_flag_one?("GCRY_STW_FIXED_SLOTS")
    {% end %}
    {% if flag?(:win32) %}
      # Research: refuse the stop as though `SuspendThread` had failed, which is
      # the only way left to reach that path now that a full capture table grows
      # instead of failing the collection
      # (`process_spec/regression/9_windows_suspension_capacity_spec.cr`).
      Gcry::Platform.stw_test_fail_suspend = true if env_flag_one?("GCRY_STW_TEST_FAIL_SUSPEND")
    {% end %}
    # Research only: swallow this many suspend signals before sending any, so
    # a thread that was signalled and never acknowledged can be arranged
    # rather than waited for (src/gcry/collect_stw.cr).
    if ds = env_u64("GCRY_STW_TEST_DROP_SUSPENDS")
      heap.stw_test_drop_suspends = ds.to_u32 if ds <= 64
    end
    # Research only: swallow every signal to this many threads, resends
    # included — a thread that never answers rather than a lost delivery.
    if mt = env_u64("GCRY_STW_TEST_MUTE_THREADS")
      heap.stw_test_mute_threads = mt.to_u32 if mt <= 64
    end
    # Research only: answer every handle probe with ESRCH, so the abandonment
    # path can be exercised without a dead handle on Crystal's list.
    heap.stw_test_esrch = true if env_flag_one?("GCRY_STW_TEST_ESRCH")
    # Research only: send one more suspend signal to every thread after the
    # world restarts — the redundant delivery the epoch exists to decline.
    heap.stw_test_double_suspend = true if env_flag_one?("GCRY_STW_TEST_DOUBLE_SUSPEND")
    # Wait, briefly and before stopping anything, for a thread that exists but
    # has not published itself yet (src/gcry/collect_stw.cr). **On** by default.
    #
    # It went on rather than staying a knob for one reason: the local repro is
    # dead — `nested_spawn_uaf` is 0/23 and `ec_queue_audit` 0/25 — so CI is the
    # only place this defect is still observed, and a knob nobody sets is never
    # observed at all. The evidence for harm is nil (crashes 6/60 → 0/60, census
    # gaps 3/30 → 0/30, ~1.4% of collections wait, every gate green), and the
    # remaining question — whether it also closes the `Fiber` family, which has
    # never been shown to share this window — can only be answered where the
    # defect appears. `GCRY_STAGED_WAIT=0` turns it back off.
    heap.staged_wait = false if env_flag_zero?("GCRY_STAGED_WAIT")
    # EXPERIMENT: root every block for the collection after its birth
    # (src/gcry/birth_grace.cr). A measurement, not a fix.
    # Size window for the grace, so it can be aimed at one block shape at a
    # time (`GCRY_BIRTH_GRACE_MIN` / `_MAX`, payload bytes). Unset means every
    # size, which is what the 20/48 → 0/48 arm measured.
    if mn = env_u64("GCRY_BIRTH_GRACE_MIN")
      heap.birth_size_min = mn.to_u32
    end
    if mx = env_u64("GCRY_BIRTH_GRACE_MAX")
      heap.birth_size_max = mx.to_u32
    end
    heap.birth_grace_noroot = true if env_flag_one?("GCRY_BIRTH_GRACE_NOROOT")
    heap.birth_grace_dummy = true if env_flag_one?("GCRY_BIRTH_GRACE_DUMMY")
    heap.birth_grace_touch = true if env_flag_one?("GCRY_BIRTH_GRACE_TOUCH")
    if sp = env_u64("GCRY_POST_MARK_SPIN")
      heap.post_mark_spin = sp
    end
    heap.birth_grace = true if env_flag_one?("GCRY_BIRTH_GRACE")
    # `GCRY_POISON_HOLDERS=1` — after a use-after-free names the block it read
    # out of, search the root set, the live heap and the fiber stacks for
    # whatever still points into it (src/gcry/poison_holders.cr). It implies the
    # tag and the report it extends: the search needs a block address to look
    # for, and the tag is what supplies it, so asking for holders without them
    # would be a knob that silently does nothing.
    if env_flag_one?("GCRY_POISON_HOLDERS")
      heap.poison_freed = true
      heap.poison_tag_addr = true
      {% if flag?(:unix) %} Gcry::SegvReport.request {% end %}
      {% if flag?(:unix) %} Gcry::PoisonHolders.request {% end %}
    end
    # Twin of the heap walk `make holders-find` asserts: skip it, so a
    # planted holder in a live marked object comes back as none. Research
    # only — the crash-time search is unchanged.
    {% if flag?(:unix) || flag?(:win32) %}
      Gcry::PoisonHolders.skip_heap_count if env_flag_one?("GCRY_DISABLE_HOLDERS_FIND")
    {% end %}
    # Research only: release a chunk the flush found occupied anyway, which
    # is what this code did before 2026-09-14. `make occupied-release` walks
    # that window on a library heap through `Heap#post_stw_hook`; this is the
    # same control for a process heap.
    heap.release_occupied_anyway = true if env_flag_one?("GCRY_RELEASE_OCCUPIED")
    # Research only, restores a defect: queue an unreachable finalizable
    # object without resurrecting it, so its callback runs on a swept block.
    heap.finalizer_resurrect = false if env_flag_one?("GCRY_FINALIZER_NO_RESURRECT")
    # Research only: refuse the first n empty-chunk releases whatever the
    # occupancy says. The positive control for the kept-chunk ledger and the
    # crash-report line that names it, on a host where the real window does
    # not open.
    if n = env_u64("GCRY_REFUSE_EMPTY_RELEASE")
      heap.refuse_empty_release_budget = n
    end
    # Research only: fault on purpose inside the holders search, at the named
    # section, so the diagnosis path that reports *that* has a positive control.
    # `GCRY_POISON_HOLDERS_FAULT=1|2|3` — the explicit root set, the heap walk,
    # the fiber stacks. A digit and not a name because this is read from
    # `GC.init`, where `ENV[]` allocates and can fault. A report that dies
    # inside itself is indistinguishable from a search that found nothing —
    # which is how three CI reds read as "the heap search did not name it" — so
    # the only way to know the naming works is to break it on demand.
    {% if flag?(:unix) %}
      if stage = env_digit("GCRY_POISON_HOLDERS_FAULT")
        Gcry::PoisonHolders.fault_at(stage)
      end
      # Research only: `GCRY_SEGV_REPORT_STACK=1` prints how much alternate
      # signal stack the report has and how much of it the report used.
      Gcry::SegvReport.probe_stack if env_flag_one?("GCRY_SEGV_REPORT_STACK")
    {% end %}
    # Once, before any collection: prime the kernel's page size, which the
    # guard offsets and the pagemap probe read while the world is stopped.
    Gcry::Roots.runtime_page_size
    # Research only: state the `live_objects` invariant even of a heap whose
    # counters may lose updates, and count the failures rather than raising.
    # This is the measurement the checker's scope correction stopped making, and
    # it is what decides whether `heap_counters_atomic` should be the default.
    if env_flag_one?("GCRY_INVARIANT_COUNTER_LOSS")
      Gcry::Invariant.enable
      Gcry::Invariant.force_counters
    end
    # Research only: stall inside the thread-stacks phase with the world stopped,
    # so the watchdog above has a positive control. Never ship non-zero — it
    # freezes every mutator for that long, on purpose.
    heap.mostly_empty_unlink = true if env_flag_one?("GCRY_MOSTLY_EMPTY_UNLINK")
    # Research only: an unlocked walk of the runtime thread list before
    # `Thread.lock`. See src/gcry/thread_list_tripwire.cr for why it is off by
    # default.
    heap.thread_list_tripwire = true if env_flag_one?("GCRY_THREAD_LIST_TRIPWIRE")
    heap.dying_greg_dump = true if env_flag_one?("GCRY_DYING_GREG_DUMP")
    heap.disable_greg_roots = true if env_flag_one?("GCRY_DISABLE_GREG_ROOTS")
    heap.disable_ec_pins = true if env_flag_one?("GCRY_DISABLE_EC_PINS")
    # After `register_builtins` on purpose: Fiber#proc is one of the holes
    # this restores, and dropping it at init would take the process down
    # before `make ivar-layout-roots` could measure its own probes.
    Gcry::Layout.drop_unclassified = true if env_flag_one?("GCRY_LAYOUT_DROP_UNCLASSIFIED")
    heap.full_suspended_stack = true if env_flag_one?("GCRY_FULL_SUSPENDED_STACK")
    if sl = env_u64("GCRY_SUSPENDED_SP_SLACK")
      heap.suspended_sp_slack = sl
    end
    if lim = env_u64("GCRY_ADDRESS_SPACE_REPORT_LIMIT")
      heap.address_space_report_limit = lim.to_i32
    end
    if st = env_u64("GCRY_PAGE_RELEASE_TEST_STALL_MS")
      heap.page_release_test_stall_ms = st
    end
    heap.fiber_list_unlocked = true if env_flag_one?("GCRY_FIBER_LIST_UNLOCKED")
    if d = env_u64("GCRY_FIBER_WALK_TEST_DELAY_US")
      heap.fiber_walk_test_delay_us = d.clamp(0_u64, 100_000_u64)
    end
    if st = env_u64("GCRY_STW_TEST_STALL_MS")
      heap.stw_test_stall_ms = st if st <= 60_000
    end
    # The same, for the suspend phase — the one the aarch64 hang lives in.
    if pst = env_u64("GCRY_STW_TEST_POSTSUSPEND_STALL_MS")
      heap.stw_test_postsuspend_stall_ms = pst if pst <= 60_000
    end
    if tst = env_u64("GCRY_STW_TEST_STOPPED_STALL_MS")
      heap.stw_test_stopped_stall_ms = tst if tst <= 60_000
    end
    if pre = env_u64("GCRY_STW_TEST_PRESUSPEND_STALL_MS")
      heap.stw_test_presuspend_stall_ms = pre if pre <= 60_000
    end
    if sst = env_u64("GCRY_STW_TEST_SUSPEND_STALL_MS")
      heap.stw_test_suspend_stall_ms = sst if sst <= 60_000
    end
    # Research only: slide the parked-fiber wipe above stack_top, into live
    # frames. The positive control for bench/scrub_audit.cr — see
    # docs/SOUND-DEFAULTS.md § "Auditing the scrub". Corrupts on purpose.
    if so = env_u64("GCRY_SCRUB_OVERSHOOT")
      heap.scrub_overshoot_bytes = so if so <= 65536
    end
    # Compiler stack maps (docs/STACK_MAPS.md). Section load is lazy on first
    # collect. Needs CRYSTAL_EMIT_STACKMAP=1 binaries for real hits.
    #   GCRY_PRECISE_STACK=1 — hybrid (precise + conservative stacks)
    #   GCRY_PRECISE_STACK=2 — exclusive mutator/other-thread (parked fibers
    #     still word-scanned unless GCRY_PRECISE_FIBERS=1)
    case env_digit("GCRY_PRECISE_STACK")
    when 1
      heap.precise_stack_roots = true
    when 2
      heap.precise_stack_roots = true
      heap.precise_stack_exclusive = true
      warn_unsupported_env("gcry: GCRY_PRECISE_STACK=2 exclusive — research only; incomplete maps can UAF\n")
    end
    if env_flag_one?("GCRY_PRECISE_FIBERS")
      heap.precise_stack_fibers_exclusive = true
      # Optional leaf window (bytes). Default 8 KiB (property). Cap 16 MiB.
      # LEAF=0 = maps + FP-fill only (research; exclusive_fiber_smoke needs ≥8k
      # or full-scan fallback when the FP chain is unusable).
      if leaf = env_u64("GCRY_PRECISE_FIBER_LEAF")
        heap.precise_stack_fiber_leaf_bytes = leaf.clamp(0_u64, 16_u64 * 1024 * 1024)
      end
      # Escape: GCRY_DISABLE_FIBER_FP_FILL=1 → leaf/maps only (no FP-frame fill).
      if env_flag_one?("GCRY_DISABLE_FIBER_FP_FILL")
        heap.precise_stack_fiber_fp_fill = false
      end
      # Research: GCRY_FIBER_FP_FILL_MISS_ONLY=1 → skip fill on map-hit frames.
      # acik exclusivef UAF with this — map hit ≠ complete live set.
      if env_flag_one?("GCRY_FIBER_FP_FILL_MISS_ONLY")
        heap.precise_stack_fiber_fp_fill_miss_only = true
        warn_unsupported_env("gcry: GCRY_FIBER_FP_FILL_MISS_ONLY=1 — research; UAF risk\n")
      end
      warn_unsupported_env("gcry: GCRY_PRECISE_FIBERS=1 — parked full scan off; research\n")
    end
    {% if flag?(:win32) %}
      # The research walker decodes SysV fiber contexts, not Microsoft's ABI.
      if heap.precise_stack_roots || heap.precise_stack_fibers_exclusive
        warn_unsupported_env("gcry: precise stack maps are unsupported on Windows; using conservative stacks\n")
        heap.precise_stack_roots = false
        heap.precise_stack_exclusive = false
        heap.precise_stack_fibers_exclusive = false
      end
    {% end %}
    # Research: parked map-miss PC ring on /gc-stats (exclusivef gap hunt).
    if env_flag_one?("GCRY_STACKMAP_MISS_LOG")
      Gcry::StackMaps.miss_log = true
    end
    if near = env_u64("GCRY_STACKMAP_NEAR_DELTA")
      Gcry::StackMaps.near_delta = near
    end
    # Research: first-mark root-source counters + /gc-live-attr size/type summary.
    if env_flag_one?("GCRY_LIVE_ATTR")
      heap.live_attr_roots = true
    end
    # Watch one Crystal type_id's first-mark sources (e.g. TCPSocket=441).
    if wtid = env_u64("GCRY_LIVE_ATTR_WATCH_TID")
      if wtid > 0 && wtid <= Int32::MAX.to_u64
        heap.live_attr_watch_tid = wtid.to_i32
        heap.live_attr_roots = true
      end
    end
  end

  # stderr warn for knobs that stay wired for research but are not a product path.
  # Gcry::OS.write avoids allocating during GC.init / apply_env_config.
  private def self.warn_unsupported_env(msg : String) : Nil
    Gcry::OS.write(2, msg.to_unsafe, LibC::SizeT.new(msg.bytesize))
  end

  private def self.env_flag_one?(name : String) : Bool
    flag = Gcry::OS.getenv(name)
    return false if flag.null?
    flag.value == '1'.ord.to_u8 && (flag + 1).value == 0
  end

  # For knobs that default *on*: only an explicit "0" turns them off.
  private def self.env_flag_zero?(name : String) : Bool
    flag = Gcry::OS.getenv(name)
    return false if flag.null?
    flag.value == '0'.ord.to_u8 && (flag + 1).value == 0
  end

  # Single ASCII digit env (e.g. GCRY_PRECISE_STACK=1|2). Nil if unset/invalid.
  private def self.env_digit(name : String) : Int32?
    flag = Gcry::OS.getenv(name)
    return nil if flag.null?
    ch = flag.value
    return nil unless ch >= '0'.ord.to_u8 && ch <= '9'.ord.to_u8
    return nil unless (flag + 1).value == 0
    (ch - '0'.ord.to_u8).to_i32
  end

  private def self.env_u64(name : String) : UInt64?
    ptr = Gcry::OS.getenv(name)
    return nil if ptr.null?
    parse_u64_cstr(ptr)
  end

  private def self.parse_u64_cstr(ptr : UInt8*) : UInt64
    value = 0_u64
    while (c = ptr.value) != 0
      break if c < '0'.ord.to_u8 || c > '9'.ord.to_u8
      value = value * 10_u64 + (c - '0'.ord.to_u8).to_u64
      ptr += 1
    end
    value
  end

  # :nodoc:
  def self.malloc(size : LibC::SizeT) : Void*
    Crystal.trace :gc, "malloc", size: size do
      check_fork_poison!
      if @@gcry_ready
        Gcry.default_heap.malloc(size)
      else
        bootstrap_malloc(size, clear: true)
      end
    end
  end

  # :nodoc:
  def self.malloc_atomic(size : LibC::SizeT) : Void*
    Crystal.trace :gc, "malloc", size: size, atomic: 1 do
      check_fork_poison!
      if @@gcry_ready
        Gcry.default_heap.malloc_atomic(size)
      else
        bootstrap_malloc(size, clear: false)
      end
    end
  end

  # :nodoc:
  def self.realloc(pointer : Void*, size : LibC::SizeT) : Void*
    Crystal.trace :gc, "realloc", size: size do
      realloc_impl(pointer, size)
    end
  end

  private def self.realloc_impl(pointer : Void*, size : LibC::SizeT) : Void*
    check_fork_poison!
    if @@gcry_ready
      # One lookup for the whole call: the heap answers null for a pointer it
      # does not own, which is the LibC bootstrap era's.
      fresh = Gcry.default_heap.realloc_owned(pointer, size)
      return fresh unless fresh.null?
      # Emptied chunks are index-removed then munmapped post-STW. A mark miss
      # (or racing flush) makes the pointer unowned while the address is still
      # in the historic heap span — LibC.realloc aborts "invalid pointer".
      if Gcry.default_heap.in_heap_span?(pointer)
        raise ArgumentError.new("GC.realloc: not a live gcry allocation" +
                                Gcry.default_heap.release_note(pointer.address))
      end
      bootstrap_realloc(pointer, size)
    else
      bootstrap_realloc(pointer, size)
    end
  end

  def self.collect
    Crystal.trace :gc, "collect" do
      return unless @@gcry_ready
      check_fork_poison!
      Gcry.default_heap.collect(release_warm: true)
    end
  end

  # Boehm-compatible: clear unused stack near SP (also GCRY_CLEAR_STACK on alloc).
  def self.clear_stack
    return unless @@gcry_ready
    Gcry.clear_stack
  end

  def self.collect_a_little : Int
    return 0 unless @@gcry_ready
    Gcry.default_heap.collect_a_little ? 1 : 0
  end

  # Nests like Boehm's `GC_disable`/`GC_enable` (a counter): collection resumes
  # when every `disable` is matched (`Heap#enable`). `enable` without an open
  # `disable` raises the message stdlib's `spec/std/gc_spec.cr` expects.
  def self.enable
    raise "GC is not disabled" unless @@gcry_ready && Gcry.default_heap.enable
  end

  def self.disable
    Gcry.default_heap.disable if @@gcry_ready
  end

  # Never raises. zlib (`Compress::Deflate`) and GMP (`BigInt`) install this
  # as their C allocator's free callback, so an exception here would unwind
  # through C frames. A pointer the heap will not free is ignored and counted
  # (`Heap#note_refused_free`); a pointer outside the heap's span is libc's —
  # the bootstrap era's, or a foreign one — and goes to `LibC.free`, which is
  # what `gc/none` does with every pointer. Anything else that escapes the
  # free path is a collector fault, and Boehm `ABORT`s on those too.
  def self.free(pointer : Void*) : Nil
    Crystal.trace :gc, "free" do
      free_impl(pointer)
    rescue
      # No `ex.message`: a virtual call over every exception class, typed in
      # Crystal's ivar-initializer pass because this is reachable from the
      # allocator, broke building the compiler with gcry
      # (`process_spec/regression/19_ivar_initializer_typing_spec.cr`).
      buf = uninitialized UInt8[Gcry::RawOut::LIMIT]
      len = Gcry::RawOut.append(buf.to_unsafe, 0, "gcry: an exception escaped the GC.free path, which cannot raise into its C callers (zlib, GMP); aborting\n")
      Gcry::RawOut.flush(buf.to_unsafe, len)
      LibC.abort
    end
  end

  private def self.free_impl(pointer : Void*) : Nil
    return if pointer.null?
    if @@gcry_ready
      heap = Gcry.default_heap
      result = heap.free_result(pointer)
      return if result.freed?
      unless result.unowned? && !heap.in_heap_span?(pointer)
        # Same class as realloc: an emptied+munmapped gcry block is not a libc
        # pointer, and glibc aborts on it.
        heap.note_refused_free(pointer, result)
        return
      end
    end
    bootstrap_free(pointer)
  end

  def self.is_heap_ptr(pointer : Void*) : Bool
    return false unless @@gcry_ready
    Gcry.default_heap.is_heap_ptr(pointer)
  end

  def self.add_finalizer(object : Reference) : Nil
    add_finalizer_impl(object)
  end

  def self.add_finalizer(object)
  end

  private def self.add_finalizer_impl(object : T) forall T
    return unless @@gcry_ready
    {% if flag?(:win32) %}
      gcry_register_finalizer(object.as(Void*), ->(ptr : Void*) { ptr.as(T).finalize })
    {% else %}
      Gcry.default_heap.add_finalizer(object.as(Void*)) do |ptr|
        ptr.as(T).finalize
      end
    {% end %}
  end

  def self.add_root(object : Reference)
    return unless @@gcry_ready
    Gcry.default_heap.add_root(Pointer(Void).new(object.object_id))
  end

  # Precise stack-map root (compiler / frame walker). No-op unless process GC
  # is ready; raises if called outside collect. See docs/STACK_MAPS.md.
  def self.mark_precise_root(pointer : Void*) : Nil
    return unless @@gcry_ready
    Gcry.default_heap.mark_precise_root(pointer)
  end

  def self.register_disappearing_link(pointer : Void**)
    return unless @@gcry_ready
    Gcry.default_heap.register_disappearing_link(pointer)
  end

  def self.stats : GC::Stats
    if @@gcry_ready
      h = Gcry.default_heap
      Stats.new(
        heap_size: h.heap_size,
        free_bytes: h.free_bytes,
        unmapped_bytes: h.unmapped_bytes,
        bytes_since_gc: h.bytes_since_gc,
        total_bytes: h.total_bytes,
      )
    else
      Stats.new(0, 0, 0, 0, 0)
    end
  end

  # Each field against Boehm's `GC_prof_stats_s` (bdwgc `gc.h`), which
  # `gc/boehm.cr` copies through verbatim:
  #
  # - `heap_size` / `free_bytes`: Boehm's `heapsize_full` / `free_bytes_full`
  #   include memory it unmapped but still holds reserved inside its heap.
  #   gcry keeps no such reservation — a released chunk is `munmap`ped and
  #   leaves the heap — so its mapped heap and free bytes are the whole answer.
  # - `unmapped_bytes`: **not** Boehm's quantity. Boehm's is the amount
  #   currently unmapped inside its reservation; gcry has none, and reports
  #   the cumulative bytes it has returned to the OS (`Heap#unmapped_bytes`,
  #   the same number `GC.stats` gives), which is what Crystal's
  #   `GC::Stats#unmapped_bytes` describes ("returned to the OS when shrinking").
  # - `bytes_since_gc`, `bytes_before_gc`, `bytes_reclaimed_since_gc`,
  #   `reclaimed_bytes_before_gc`, `expl_freed_bytes_since_gc`: the heap's
  #   counters of the same names, kept with Boehm's meanings.
  # - `non_gc_bytes`: Boehm's "bytes not considered candidates for
  #   collection" (its uncollectable allocations). gcry has no uncollectable
  #   allocation API; what it hands out and never collects is the libc memory
  #   `GC.malloc` returns before the heap is ready (`@@non_gc_bytes`).
  # - `gc_no`: completed collections (`Heap#collections`).
  # - `markers_m1`: Boehm's "marker threads, excluding the initiating one".
  #   gcry's collecting thread marks too, and `parallel_mark_workers - 1`
  #   helpers join it (`ensure_mark_worker_pool`), so `GCRY_PARALLEL_MARK=N`
  #   reports N - 1 and serial marking 0.
  # - `obtained_from_os_bytes`: everything gcry currently has mapped from the
  #   OS — heap chunks, the out-of-memory reserve, and the collector's own
  #   mapped metadata — exactly (`Gcry.os_mapped_bytes`, `src/gcry/os_memory.cr`).
  #   It is a current level, so it falls when chunks are released; Boehm's
  #   (`GC_our_mem_bytes`) only grows, because its unmapping keeps the address
  #   range reserved. Always `>= heap_size`.
  def self.prof_stats
    if @@gcry_ready
      h = Gcry.default_heap
      ProfStats.new(
        heap_size: h.heap_size,
        free_bytes: h.free_bytes,
        unmapped_bytes: h.unmapped_bytes,
        bytes_since_gc: h.bytes_since_gc,
        bytes_before_gc: h.bytes_before_gc,
        non_gc_bytes: non_gc_bytes,
        gc_no: h.collections,
        markers_m1: (h.parallel_mark_workers - 1).to_u64,
        bytes_reclaimed_since_gc: h.bytes_reclaimed_since_gc,
        reclaimed_bytes_before_gc: h.reclaimed_bytes_before_gc,
        expl_freed_bytes_since_gc: h.expl_freed_bytes_since_gc,
        obtained_from_os_bytes: Gcry.os_mapped_bytes,
      )
    else
      ProfStats.new(
        heap_size: 0_u64,
        free_bytes: 0_u64,
        unmapped_bytes: 0_u64,
        bytes_since_gc: 0_u64,
        bytes_before_gc: 0_u64,
        non_gc_bytes: non_gc_bytes,
        gc_no: 0_u64,
        markers_m1: 0_u64,
        bytes_reclaimed_since_gc: 0_u64,
        reclaimed_bytes_before_gc: 0_u64,
        expl_freed_bytes_since_gc: 0_u64,
        obtained_from_os_bytes: Gcry.os_mapped_bytes,
      )
    end
  end

  {% if flag?(:win32) %}
    # :nodoc:
    def self.beginthreadex(security : Void*, stack_size : LibC::UInt, start_address : Void* -> LibC::UInt, arglist : Void*, initflag : LibC::UInt, thrdaddr : LibC::UInt*) : LibC::HANDLE
      if (h = Gcry.default_heap?) && !h.heap_counters_atomic_pinned
        h.heap_counters_atomic = true
      end
      # Publish the birth root before the new thread can allocate or run.
      ret = LibC._beginthreadex(security, stack_size, start_address, arglist, initflag | 4_u32, thrdaddr)
      raise RuntimeError.from_errno("_beginthreadex") if ret.null?
      Gcry::Platform.stage_thread(ret.address)
      Gcry::ThreadBirthRoot.arm(ret.address, arglist)
      # Crystal stores the handle with `@system_handle = GC.beginthreadex(...)`,
      # i.e. after this returns, and the thread publishes itself on the thread
      # list from its own `Thread#start` as soon as it runs. Resumed first, it
      # could be listed with a zero handle, and a stop then suspended handle 0:
      # `SuspendThread on thread handle 0x0, error 6` in
      # `make thread-birth-fiber`, 1 run in 25 on windows-11-arm (2026-09-30).
      # The caller is always `Thread#init_handle`, so *arglist* is that
      # `Thread`: its handle is written here, before it can run, and Crystal's
      # own store afterwards writes the same value.
      pointerof(arglist.as(::Thread).@system_handle).value = ret.as(LibC::HANDLE)
      if initflag & 4_u32 == 0
        LibC.abort if LibC.ResumeThread(ret) == UInt32::MAX
      end
      ret.as(LibC::HANDLE)
    end
  {% elsif !flag?(:wasm32) %}
    # :nodoc:
    # Record the thread with gcry as soon as its handle exists. Crystal only
    # publishes a thread from inside its own `start`, so until then `stop_world`
    # neither suspends nor scans it (src/gcry/platform/thread_staging.cr).
    # Recording here does not cover the interval *inside* `pthread_create` —
    # doing that needs a trampoline on the new thread, which was tried and
    # crashed 8 runs in 10. The census reports what this placement leaves.
    def self.pthread_create(thread : Gcry::OS::PthreadT*, attr : Gcry::OS::PthreadAttrT*, start : Void* -> Void*, arg : Void*)
      {% if flag?(:gc_none) %}
        # **Before** the call, not after. A second thread is about to exist, and
        # the allocation counters are plain get/set until told otherwise —
        # `set(get + 1)` loses increments outright once two threads run it
        # (src/gcry/invariant.cr measured the process heap's counter permanently
        # behind in 3 runs of 40). Flipping after `pthread_create` returns
        # leaves a window in which the new thread is already allocating, and
        # leaves the flag's visibility to it unordered; setting it first is
        # published by the thread creation itself. Single-threaded programs
        # never reach here and pay nothing.
        #
        # What it costs, measured rather than assumed, because the comment on
        # `heap_counters_atomic` said the opposite:
        #   x86_64  `set(get + n)` is `mov; inc; xchg` — and `xchg` to memory is
        #           locked whether you ask or not — against a single `lock incq`
        #           for the atomic. The "cheap" path was never cheaper: three
        #           arms interleaved and pinned, mins 55.69 / 55.47 / 56.13 ns
        #           per allocation for plain / atomic / relaxed.
        #   aarch64 the other way: `ldar; add; stlr` against an `ldaxr/stlxr`
        #           retry loop (baseline codegen, no LSE). There the atomic path
        #           is genuinely more work, which is why this flips on a second
        #           thread rather than shipping on.
        if (h = Gcry.default_heap?) && !h.heap_counters_atomic_pinned
          h.heap_counters_atomic = true
        end
      {% end %}
      ret = Gcry::OS.pthread_create(thread, attr, start, arg)
      {% if flag?(:gc_none) %}
        if ret == 0
          Gcry::Platform.stage_thread(thread.value.unsafe_as(UInt64))
          # Crystal passes the `Thread` object itself as `arg`
          # (`crystal/system/unix/pthread.cr`: `arg: self.as(Void*)`), so the
          # object whose only other holder is the new thread's unscanned stack
          # is right here. Root it until the thread publishes itself
          # (src/gcry/thread_birth_root.cr).
          Gcry::ThreadBirthRoot.arm(thread.value.unsafe_as(UInt64), arg)
        end
      {% end %}
      ret
    end

    # :nodoc:
    # Both of these mean one thing to gcry: this handle's thread has ended.
    # Crystal calls `detach` from the dying thread's own `ensure` and `join`
    # from a joiner, and until 2026-09-12 neither was observed — so a birth
    # root was released only when `stop_world` found its thread on Crystal's
    # list, and a thread that published and exited between two collections
    # kept its root for the life of the process
    # (src/gcry/thread_birth_root.cr).
    #
    # The mark happens **before** the real call, so it is written while the
    # handle is still unambiguously this thread's: after `pthread_detach` the
    # handle is reusable, and a mark landing then could hit a slot `arm` had
    # already given to a new birth.
    #
    # What is deliberately **not** here: dropping the thread's staging
    # record. It belongs here logically — a dead thread is not a thread being
    # born, and leaving the record makes every later stop spin its whole
    # budget waiting for it — and shipping it crashes. See
    # `GCRY_THREAD_UNSTAGE_ON_DEATH`.
    def self.pthread_join(thread : Gcry::OS::PthreadT)
      {% if flag?(:gc_none) %}
        Gcry::Platform.unstage_on_death(thread.unsafe_as(UInt64))
        Gcry::ThreadBirthRoot.note_death(thread.unsafe_as(UInt64))
      {% end %}
      Gcry::OS.pthread_join(thread, nil)
    end

    # :nodoc:
    def self.pthread_detach(thread : Gcry::OS::PthreadT)
      {% if flag?(:gc_none) %}
        Gcry::Platform.unstage_on_death(thread.unsafe_as(UInt64))
        Gcry::ThreadBirthRoot.note_death(thread.unsafe_as(UInt64))
      {% end %}
      Gcry::OS.pthread_detach(thread)
    end
  {% end %}

  # :nodoc:
  def self.current_thread_stack_bottom : {Void*, Void*}
    if @@gcry_ready
      Gcry.default_heap.current_thread_stack_bottom
    else
      {Pointer(Void).null, Pointer(Void).null}
    end
  end

  # :nodoc:
  # What gcry does with a stack bottom it is told about, and why it needs no
  # per-thread table: every collection re-derives every thread's bottom from
  # the fiber that thread is running at the stop, and never trusts a stored one.
  #   - The collecting thread: `Heap#scan_mutator_stack` scans up to
  #     `Fiber.current.@stack.bottom` (`collect_scan.cr`), and the
  #     `before_collect` hook in `GC.init` refreshes `Heap#stack_bottom` from
  #     the same place before any scan.
  #   - Every other thread: `Heap#scan_other_thread_stacks` reads
  #     `thread.@current_fiber.@stack.bottom`, and the stack-bounds snapshot
  #     taken in `stop_world` for frames below the fiber (`collect_scan.cr`).
  # So a bottom stored for another thread would never be read. What a stored
  # value is still read for is the calling thread's own — the
  # `current_thread_stack_bottom` fallback when the OS will not report
  # bounds, and crash diagnostics — so only a bottom for `Thread.current` is
  # kept, and one for another thread no longer overwrites it (until
  # 2026-10-05 it did, unconditionally). `process_spec` covers the scan half.
  #
  # Crystal 1.21's ExecutionContext never calls this; the legacy `-Dwithout_mt`
  # scheduler calls the one-argument form on every swap, always for the
  # running thread, which is the one thing it can mean there.
  {% if !flag?(:without_mt) %}
    def self.set_stackbottom(thread : Thread, stack_bottom : Void*)
      return unless @@gcry_ready
      Gcry.default_heap.set_stackbottom(stack_bottom) if thread.same?(Thread.current?)
    end
  {% else %}
    def self.set_stackbottom(stack_bottom : Void*)
      Gcry.default_heap.set_stackbottom(stack_bottom) if @@gcry_ready
    end
  {% end %}

  {% unless flag?(:win32) %}
    # :nodoc:
    # The signals the stop-the-world uses, answered from the same constants
    # the handlers are installed with (`platform/stw_signals.cr`).
    # `Crystal::System::Thread.sig_suspend` / `sig_resume` defer to these when
    # `GC` defines them, and `Process` spawn unblocks exactly these in the child.
    # On Darwin gcry stops threads through Mach and installs no handler of its
    # own; the pair is then the one Crystal's `init_suspend_resume` installed.
    def self.sig_suspend : Signal
      Signal.new(Crystal::System::Thread::GC_STW_SIG_SUSPEND)
    end

    # :nodoc:
    def self.sig_resume : Signal
      Signal.new(Crystal::System::Thread::GC_STW_SIG_RESUME)
    end
  {% end %}

  # :nodoc:
  # Not under `-Dwithout_mt`, as in `gc/boehm.cr`. There `Fiber#run` still
  # calls `unlock_read` once per new fiber while the legacy scheduler never
  # calls `lock_read`, so forwarding the pair drove the heap's reader count
  # negative and the next `GC.collect` spun in `write_lock` forever — the first
  # `spawn` made every later collection hang (2026-10-05, also at HEAD).
  def self.lock_read
    {% unless flag?(:without_mt) %}
      Gcry.default_heap.lock_read if @@gcry_ready
    {% end %}
  end

  # :nodoc:
  def self.unlock_read
    {% unless flag?(:without_mt) %}
      Gcry.default_heap.unlock_read if @@gcry_ready
    {% end %}
  end

  # :nodoc:
  def self.lock_write
    Gcry.default_heap.lock_write if @@gcry_ready
  end

  # :nodoc:
  def self.unlock_write
    Gcry.default_heap.unlock_write if @@gcry_ready
  end

  # :nodoc:
  def self.push_stack(stack_top, stack_bottom) : Nil
    return unless @@gcry_ready
    Gcry.default_heap.push_stack(stack_top, stack_bottom)
  end

  # :nodoc:
  def self.before_collect(&block) : Nil
    Gcry.default_heap.before_collect(&block)
  end

  # :nodoc:
  # Suspends other OS threads (Monitor / extra schedulers) for a safe mark–sweep.
  def self.stop_world : Nil
    Gcry.default_heap.stop_world if @@gcry_ready
  end

  # :nodoc:
  def self.start_world : Nil
    Gcry.default_heap.start_world if @@gcry_ready
  end

  private def self.bootstrap_malloc(size : LibC::SizeT, clear : Bool) : Void*
    ptr = LibC.malloc(size)
    raise Gcry::OutOfMemoryError.new("bootstrap malloc failed") if ptr.null?
    ptr.as(UInt8*).clear(size) if clear
    non_gc_add(libc_usable_size(ptr))
    ptr
  end

  private def self.bootstrap_realloc(pointer : Void*, size : LibC::SizeT) : Void*
    old = pointer.null? ? 0_u64 : libc_usable_size(pointer)
    ptr = LibC.realloc(pointer, size)
    raise Gcry::OutOfMemoryError.new("bootstrap realloc failed") if ptr.null? && size != 0
    # A failed realloc raised above with *pointer* untouched; past here the old
    # block is gone (moved, resized, or freed by a zero-size realloc).
    non_gc_sub(old)
    non_gc_add(libc_usable_size(ptr)) unless ptr.null?
    ptr
  end

  # Every pointer `free` sends to libc. Outside the heap's span it is the
  # bootstrap era's — or a foreign libc pointer handed to `GC.free` by mistake,
  # which `non_gc_sub` saturates against rather than wrapping.
  private def self.bootstrap_free(pointer : Void*) : Nil
    non_gc_sub(libc_usable_size(pointer))
    LibC.free(pointer)
  end

  private def self.non_gc_bytes : UInt64
    Atomic::Ops.load(pointerof(@@non_gc_bytes), LLVM::AtomicOrdering::Monotonic, false)
  end

  private def self.non_gc_add(bytes : UInt64) : Nil
    Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Add, pointerof(@@non_gc_bytes), bytes,
      LLVM::AtomicOrdering::Monotonic, false)
  end

  private def self.non_gc_sub(bytes : UInt64) : Nil
    loop do
      cur = non_gc_bytes
      nxt = cur > bytes ? cur - bytes : 0_u64
      _, ok = Atomic::Ops.cmpxchg(pointerof(@@non_gc_bytes), cur, nxt,
        LLVM::AtomicOrdering::Monotonic, LLVM::AtomicOrdering::Monotonic)
      return if ok
    end
  end

  private def self.libc_usable_size(pointer : Void*) : UInt64
    {% if flag?(:darwin) %}
      LibGcryUsableSize.malloc_size(pointer).to_u64
    {% elsif flag?(:win32) %}
      LibGcryUsableSize._msize(pointer).to_u64
    {% else %}
      LibGcryUsableSize.malloc_usable_size(pointer).to_u64
    {% end %}
  end
end

# How big libc made a block, so `GC.prof_stats.non_gc_bytes` can take back on
# free exactly what it counted on malloc. One name per supported libc.
lib LibGcryUsableSize
  {% if flag?(:darwin) %}
    fun malloc_size(ptr : Void*) : LibC::SizeT
  {% elsif flag?(:win32) %}
    fun _msize(ptr : Void*) : LibC::SizeT
  {% else %}
    fun malloc_usable_size(ptr : Void*) : LibC::SizeT
  {% end %}
end

{% if flag?(:win32) %}
  # The C boundary breaks recursive type inference through Windows runtime mutex
  # finalizers -> collector locks -> exceptions -> IOCP initializers.
  fun gcry_register_finalizer(object : Void*, callback : Void* ->) : Nil
    if heap = Gcry.default_heap?
      heap.add_finalizer(object, callback)
    end
  end
{% end %}
