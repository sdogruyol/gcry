# Reopens Crystal's `GC` module under `-Dgc_none`, forwarding to Gcry.

{% if flag?(:linux) && flag?(:gnu) %}
  lib LibC
    $__libc_stack_end : Void*
  end
{% end %}

module GC
  @@gcry_ready = false
  @@gcry_enabled = true
  # Set when fork child cannot reinit (GCRY_DISABLE_ATFORK=1 or install failed).
  @@after_fork_child = false
  @@handle_fork = true

  def self.init : Nil
    Crystal::System::Thread.init_suspend_resume
    # Capture SP in the suspend handler so other-thread scans skip below-SP.
    unless env_flag_one?("GCRY_DISABLE_SP_CLAMP")
      Gcry::Platform.install_stw_sp_capture
    end

    Gcry::Platform.init_staging
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
      heap.blacklist_enabled = true
      # Large cache on Darwin starts at 1 MiB (adaptive can grow to LARGE_CACHE_LIMIT
      # if hit-rate warrants it). mach_vm reclaim already punches holes on free,
      # so a fat cache is wasteful; 1 MiB floor avoids mmap churn for the common case.
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
      heap.blacklist_enabled = true
      # Large-object freelist: no retain (was 4 MiB floor, adaptive → 32 MiB).
      # Escape: GCRY_LARGE_CACHE=<bytes> (adaptive may grow from a non-zero floor).
      heap.large_cache_retain = 0_u64
    {% end %}
    # type_id_gate on *static* ambient roots (BSS false hits). Stack/thread
    # roots stay ungated: Channel/Deque buffers and similar raw allocations
    # fail the type_id heuristic and were dropped → Log::AsyncDispatcher SEGV
    # under frequent collect. Escape to also gate stacks: GCRY_TYPE_ID_GATE=1.
    # Heap scan still uses mark_candidate (no gate) for Array/Hash buffers.
    heap.type_id_gate = true
    heap.type_id_gate_stacks = false
    # Page blacklist: previously off on Darwin (freelist abandonment spiral under
    # all-conservative scanning). Re-enabled in P2.3 era now that layout-precise
    # scans cut false root hits sharply — the abandon spiral is unlikely.
    # Escape: GCRY_DISABLE_BLACKLIST=1.
    # (blacklist_enabled set in the Darwin/Linux branches above.)
    heap.allow_interior_pointers = false
    heap.layout_precise = true
    # Avoid mid-boot collections until env config runs.
    heap.gc_threshold = UInt64::MAX

    {% if flag?(:linux) && flag?(:gnu) %}
      heap.set_stackbottom(LibC.__libc_stack_end)
    {% elsif flag?(:darwin) %}
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
      heap.set_stackbottom(Fiber.current.@stack.bottom)
      # Arm the crash reporter here rather than above: Crystal installs its own
      # SIGSEGV handler after GC.init and does not chain, so anything installed
      # earlier is discarded. See Gcry::SegvReport.install_if_requested.
      Gcry::SegvReport.install_if_requested
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

    @@gcry_ready = true
    apply_env_config(heap)

    # Fork: reinit locks/STW in the child (opt out with GCRY_DISABLE_ATFORK=1).
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
    if @@handle_fork
      Gcry.default_heap.after_fork_child_reinit
      @@after_fork_child = false
      unless env_flag_one?("GCRY_DISABLE_SP_CLAMP")
        Gcry::Platform.install_stw_sp_capture
      end
    else
      @@after_fork_child = true
    end
  end

  private def self.check_fork_poison! : Nil
    if @@after_fork_child
      raise "gcry: GC after fork is unsupported without atfork reinit (unset GCRY_DISABLE_ATFORK); see docs/POLICY.md"
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
  # (First cut says: less than expected. Kemal /json is ~1pp of throughput and
  # no RSS movement — see docs/SOUND-DEFAULTS.md. Whether that makes sound the
  # right *default* is a separate call, and needs more than one host.)
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

  # Use LibC.getenv — Crystal's ENV uses `once` + Fiber, unavailable in GC.init.
  private def self.apply_env_config(heap : Gcry::Heap) : Nil
    # First: whole-class root-completeness profile. Individual knobs below
    # override it, so this must run before them.
    apply_sound_profile(heap) if env_flag_one?("GCRY_SOUND")

    if env_flag_one?("GCRY_DISABLE_AUTO")
      heap.gc_threshold = UInt64::MAX
    elsif thr = env_u64("GCRY_THRESHOLD")
      heap.gc_threshold = thr unless thr == 0
    else
      # Lower major threshold (16 MiB) halves the dense-live growth window
      # under fat apps on Darwin. Linux stays at 32 MiB (PROCESS_GC_THRESHOLD)
      # — 16 MiB regressed acikturkiye thr by ~20pp via excessive major cycling.
      {% if flag?(:darwin) %}
        heap.gc_threshold = 16_u64 * 1024_u64 * 1024_u64
      {% else %}
        heap.gc_threshold = Gcry::Heap::PROCESS_GC_THRESHOLD
      {% end %}
      # Parallel EC: raise major threshold (see PROCESS_GC_THRESHOLD_PARALLEL).
      # Explicit GCRY_THRESHOLD above wins; EC1/default unchanged.
      if (ec = env_u64("EC_PARALLELISM")) && ec > 1
        heap.gc_threshold = Gcry::Heap::PROCESS_GC_THRESHOLD_PARALLEL
        # Contended alloc/free counters need Atomic RMW.
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
    elsif nursery = env_u64("GCRY_NURSERY")
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
    end
    if warm = env_u64("GCRY_EMPTY_CHUNK_WARM_RETAIN")
      heap.empty_chunk_warm_retain = warm
    end

    if env_flag_one?("GCRY_DISABLE_MADVISE")
      heap.madvise_free_pages = false
    elsif env_flag_one?("GCRY_PAGE_DONTNEED")
      # Sparse-chunk free-page release (HOLED + post-STW madvise).
      heap.madvise_free_pages = true
    end

    {% if flag?(:darwin) %}
      # Darwin: MADV_FREE_REUSABLE drops RSS; enable free-page release.
      # (MADV_DONTNEED on Darwin does NOT drop RSS — advisory only.)
      if env_flag_one?("GCRY_DISABLE_MADVISE") || env_flag_one?("GCRY_DISABLE_PAGE_RELEASE")
        heap.madvise_free_pages = false
      else
        heap.madvise_free_pages = true
        # flush_pending_page_release_chunks also walks ALL chunks on Darwin
        # (not just HOLED) for more aggressive RSS recovery.
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
        # LibC.getenv only — ENV[] allocates and can SEGV during GC.init.
        mode = LibC.getenv("GCRY_MOSTLY_EMPTY_MODE")
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

    if env_flag_one?("GCRY_INTERIOR")
      heap.allow_interior_pointers = true
    end

    # Follow misaligned candidate *values* (interiors into byte buffers).
    # Implied by GCRY_SOUND; GCRY_ALIGNED_CANDIDATES=1 forces the cheap
    # alignment filter back on so the two costs can be measured apart.
    if env_flag_one?("GCRY_UNALIGNED_CANDIDATES")
      heap.scan_unaligned_candidates = true
    end
    if env_flag_one?("GCRY_ALIGNED_CANDIDATES")
      heap.scan_unaligned_candidates = false
    end

    if env_flag_one?("GCRY_TYPE_ID_GATE")
      # Opt into pre-fix behavior: gate stack/thread ambient roots too.
      heap.type_id_gate = true
      heap.type_id_gate_stacks = true
    end

    if env_flag_one?("GCRY_DISABLE_TYPE_ID_GATE")
      heap.type_id_gate = false
      heap.type_id_gate_stacks = false
    end

    if env_flag_one?("GCRY_DISABLE_STATIC_ROOTS")
      heap.scan_static_roots = false
    end

    if env_flag_one?("GCRY_BLACKLIST")
      heap.blacklist_enabled = true
    end
    if env_flag_one?("GCRY_DISABLE_BLACKLIST")
      heap.blacklist_enabled = false
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
    # Must be ≥64 KiB and page-aligned.
    if chunk_bytes = env_u64("GCRY_CHUNK_BYTES")
      if chunk_bytes >= Gcry::Heap::MIN_SMALL_CHUNK_BYTES && (chunk_bytes % 4096_u64) == 0
        heap.small_chunk_bytes = chunk_bytes
      end
    end

    # Torture: collect every N allocs (CI / dogfood).
    if env_flag_one?("GCRY_STRESS")
      every = env_u64("GCRY_STRESS_EVERY") || 16_u64
      heap.stress_every = every.to_i32 if every > 0 && every <= Int32::MAX
    end

    # TLAB under Parallel is UNSUPPORTED (supported opt-in keeps TLAB off).
    # Knob retained for research / A/B only — emits a stderr warning.
    if env_flag_one?("GCRY_TLAB")
      warn_unsupported_env(
        "gcry: WARNING: GCRY_TLAB=1 is unsupported under Parallel EC " \
        "(supported path: TLAB off + lazy). Soft-soak/SEGV risk — see docs/POLICY.md\n"
      )
      heap.tlab_enabled = true
    end
    # TLAB-off: batch-pop N size-class nodes under freelist lock (USED stash).
    # Amortizes lock vs lazy sweep. Clamped 1..64; ignored when TLAB is on.
    if ab = env_u64("GCRY_ALLOC_BATCH")
      if ab >= 1 && ab <= 64
        heap.alloc_batch = ab.to_i32
      end
    end
    if pm = env_u64("GCRY_PARALLEL_MARK")
      heap.parallel_mark_workers = pm.to_i32 if pm >= 1 && pm <= 16
    end
    # Multi-mutator parked-fiber scan depth below stack_top (bytes). Default
    # 256 KiB (was 512); 0 = full guard→bottom (thr regresses).
    if lag = env_u64("GCRY_STW_STACK_LAG")
      heap.stw_multi_stack_lag = lag
    end
    # Escape hatch for the low-water skip on the lag-0 path. It preserves
    # semantics (untouched pages are zero), so this exists to A/B its cost and
    # to disable it on a kernel whose pagemap misbehaves.
    if env_flag_zero?("GCRY_STACK_LOW_WATER")
      heap.stack_low_water_scan = false
    end
    # Multi-mutator pthread map when SP is off the OS stack (on a pool fiber).
    # Default 256 KiB from stack high; 0 = full pthread mapping.
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
    Gcry::SegvReport.request if env_flag_one?("GCRY_SEGV_REPORT")
    # After mark, before sweep: does any marked object point at a block the
    # sweep is about to free? (src/gcry/mark_audit.cr). Off by default —
    # O(live heap) inside the pause.
    heap.mark_audit = true if env_flag_one?("GCRY_MARK_AUDIT")
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
    # Research only: keep the pthread stack-bounds snapshot at its initial size
    # instead of growing it, which is what a thread list longer than 64 used to
    # run into (src/gcry/platform/linux_stack.cr).
    Gcry::Platform.stack_bounds_nogrow = true if env_flag_one?("GCRY_STACK_BOUNDS_NOGROW")
    # Research only: refuse a BSS larger than 1 MiB as a root range, which is
    # what the maps parser did before 2026-08-22 and what
    # `make static-bss-roots` uses to show the block dying.
    Gcry::Platform.bss_size_cap = true if env_flag_one?("GCRY_STATIC_BSS_CAP")
    # Research only: a full staging table refuses the birth being handed in
    # rather than evicting the oldest, which is what it did before 2026-08-22
    # (src/gcry/platform/thread_staging.cr).
    Gcry::Platform.staged_no_evict = true if env_flag_one?("GCRY_STAGED_NO_EVICT")
    # Research only: let the dying-type audit walk every block on a minor
    # collection, where unmarked does not mean dying
    # (src/gcry/thread_block_audit.cr).
    heap.dying_audit_all_collections = true if env_flag_one?("GCRY_DYING_AUDIT_ALL_COLLECTIONS")
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
      Gcry::SegvReport.request
      Gcry::PoisonHolders.request
    end
    # Research only: stall inside the thread-stacks phase with the world stopped,
    # so the watchdog above has a positive control. Never ship non-zero — it
    # freezes every mutator for that long, on purpose.
    if st = env_u64("GCRY_STW_TEST_STALL_MS")
      heap.stw_test_stall_ms = st if st <= 60_000
    end
    # The same, for the suspend phase — the one the aarch64 hang lives in.
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
  # LibC.write avoids allocating during GC.init / apply_env_config.
  private def self.warn_unsupported_env(msg : String) : Nil
    LibC.write(2, msg.to_unsafe, LibC::SizeT.new(msg.bytesize))
  end

  private def self.env_flag_one?(name : String) : Bool
    flag = LibC.getenv(name)
    return false if flag.null?
    flag.value == '1'.ord.to_u8 && (flag + 1).value == 0
  end

  # For knobs that default *on*: only an explicit "0" turns them off.
  private def self.env_flag_zero?(name : String) : Bool
    flag = LibC.getenv(name)
    return false if flag.null?
    flag.value == '0'.ord.to_u8 && (flag + 1).value == 0
  end

  # Single ASCII digit env (e.g. GCRY_PRECISE_STACK=1|2). Nil if unset/invalid.
  private def self.env_digit(name : String) : Int32?
    flag = LibC.getenv(name)
    return nil if flag.null?
    ch = flag.value
    return nil unless ch >= '0'.ord.to_u8 && ch <= '9'.ord.to_u8
    return nil unless (flag + 1).value == 0
    (ch - '0'.ord.to_u8).to_i32
  end

  private def self.env_u64(name : String) : UInt64?
    ptr = LibC.getenv(name)
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
    check_fork_poison!
    if @@gcry_ready
      Gcry.default_heap.malloc(size)
    else
      bootstrap_malloc(size, clear: true)
    end
  end

  # :nodoc:
  def self.malloc_atomic(size : LibC::SizeT) : Void*
    check_fork_poison!
    if @@gcry_ready
      Gcry.default_heap.malloc_atomic(size)
    else
      bootstrap_malloc(size, clear: false)
    end
  end

  # :nodoc:
  def self.realloc(pointer : Void*, size : LibC::SizeT) : Void*
    check_fork_poison!
    if @@gcry_ready
      # Pointers from the LibC bootstrap era are not on the gcry heap.
      if !pointer.null? && !Gcry.default_heap.is_heap_ptr(pointer)
        # Emptied chunks are index-removed then munmapped post-STW. A mark miss
        # (or racing flush) makes is_heap_ptr false while the address is still
        # in the historic heap span — LibC.realloc aborts "invalid pointer".
        if Gcry.default_heap.in_heap_span?(pointer)
          raise ArgumentError.new("GC.realloc: not a live gcry allocation")
        end
        return bootstrap_realloc(pointer, size)
      end
      Gcry.default_heap.realloc(pointer, size)
    else
      bootstrap_realloc(pointer, size)
    end
  end

  def self.collect
    return unless @@gcry_ready
    check_fork_poison!
    Gcry.default_heap.collect
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

  def self.enable
    raise "GC is not disabled" unless !@@gcry_enabled
    @@gcry_enabled = true
    Gcry.default_heap.enable if @@gcry_ready
  end

  def self.disable
    @@gcry_enabled = false
    Gcry.default_heap.disable if @@gcry_ready
  end

  def self.free(pointer : Void*) : Nil
    return if pointer.null?
    if @@gcry_ready && Gcry.default_heap.is_heap_ptr(pointer)
      Gcry.default_heap.free(pointer)
    elsif @@gcry_ready && Gcry.default_heap.in_heap_span?(pointer)
      # Same class as realloc: emptied+munmapped gcry block is not a LibC ptr.
      raise ArgumentError.new("GC.free: not a live gcry allocation")
    else
      LibC.free(pointer)
    end
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
    Gcry.default_heap.add_finalizer(object.as(Void*)) do |ptr|
      ptr.as(T).finalize
    end
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

  def self.prof_stats
    if @@gcry_ready
      h = Gcry.default_heap
      ProfStats.new(
        heap_size: h.heap_size,
        free_bytes: h.free_bytes,
        unmapped_bytes: h.unmapped_bytes,
        bytes_since_gc: h.bytes_since_gc,
        bytes_before_gc: h.bytes_before_gc,
        non_gc_bytes: 0_u64,
        gc_no: h.collections,
        markers_m1: 0_u64,
        bytes_reclaimed_since_gc: h.bytes_reclaimed_since_gc,
        reclaimed_bytes_before_gc: h.reclaimed_bytes_before_gc,
        expl_freed_bytes_since_gc: h.expl_freed_bytes_since_gc,
        obtained_from_os_bytes: h.heap_size + h.unmapped_bytes,
      )
    else
      ProfStats.new(
        heap_size: 0_u64,
        free_bytes: 0_u64,
        unmapped_bytes: 0_u64,
        bytes_since_gc: 0_u64,
        bytes_before_gc: 0_u64,
        non_gc_bytes: 0_u64,
        gc_no: 0_u64,
        markers_m1: 0_u64,
        bytes_reclaimed_since_gc: 0_u64,
        reclaimed_bytes_before_gc: 0_u64,
        expl_freed_bytes_since_gc: 0_u64,
        obtained_from_os_bytes: 0_u64,
      )
    end
  end

  {% if flag?(:win32) %}
    # :nodoc:
    def self.beginthreadex(security : Void*, stack_size : LibC::UInt, start_address : Void* -> LibC::UInt, arglist : Void*, initflag : LibC::UInt, thrdaddr : LibC::UInt*) : LibC::HANDLE
      ret = LibC._beginthreadex(security, stack_size, start_address, arglist, initflag, thrdaddr)
      raise RuntimeError.from_errno("_beginthreadex") if ret.null?
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
    def self.pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*, start : Void* -> Void*, arg : Void*)
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
      ret = LibC.pthread_create(thread, attr, start, arg)
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
    def self.pthread_join(thread : LibC::PthreadT)
      LibC.pthread_join(thread, nil)
    end

    # :nodoc:
    def self.pthread_detach(thread : LibC::PthreadT)
      LibC.pthread_detach(thread)
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
  # Crystal 1.21+: default is ExecutionContext (`!without_mt`). Only the legacy
  # `-Dwithout_mt` scheduler uses the single-argument form. ExecutionContext
  # itself does not call this on fiber swap — see `before_collect` above.
  {% if !flag?(:without_mt) %}
    def self.set_stackbottom(thread : Thread, stack_bottom : Void*)
      Gcry.default_heap.set_stackbottom(stack_bottom) if @@gcry_ready
    end
  {% else %}
    def self.set_stackbottom(stack_bottom : Void*)
      Gcry.default_heap.set_stackbottom(stack_bottom) if @@gcry_ready
    end
  {% end %}
  # :nodoc:
  def self.lock_read
    Gcry.default_heap.lock_read if @@gcry_ready
  end

  # :nodoc:
  def self.unlock_read
    Gcry.default_heap.unlock_read if @@gcry_ready
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
    ptr
  end

  private def self.bootstrap_realloc(pointer : Void*, size : LibC::SizeT) : Void*
    ptr = LibC.realloc(pointer, size)
    raise Gcry::OutOfMemoryError.new("bootstrap realloc failed") if ptr.null? && size != 0
    ptr
  end
end
