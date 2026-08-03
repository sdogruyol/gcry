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
      # Parked fiber stacks carry stale pointer values from prior activations
      # — those become false roots during conservative scanning and inflate
      # retention (acikturkiye macOS: ~1.2 GiB live set, where much of it is
      # not real reachable). Default-on for macOS and Linux process GC.
      # Escape: GCRY_DISABLE_SCRUB_FIBERS=1.
      heap.scrub_fibers_enabled = true
      heap.blacklist_enabled = true
      # Large cache on Darwin starts at 1 MiB (adaptive can grow to LARGE_CACHE_LIMIT
      # if hit-rate warrants it). mach_vm reclaim already punches holes on free,
      # so a fat cache is wasteful; 1 MiB floor avoids mmap churn for the common case.
      heap.large_cache_retain = 1048576_u64
    {% else %}
      # Linux: 16 MiB dormant chunk retain budget (down from 64 MiB in v0.12.0,
      # up from a prior 8 MiB that regressed acikturkiye RSS+thr via mmap churn).
      heap.empty_chunk_retain = 16_u64 * 1024_u64 * 1024_u64
      # Linux: scrub parked fiber stacks to cut false retention from stale
      # pointer values on the stack. Proved: Kemal RSS 1.04× → 0.95×,
      # acikturkiye RSS 3.00× → 2.65×, throughput preserved.
      # Escape: GCRY_DISABLE_SCRUB_FIBERS=1.
      # Collect-time mutator clear_stack was measured and dropped (below-SP wipe
      # is outside the root-scan window; no durable thr/RSS win).
      heap.scrub_fibers_enabled = true
      heap.blacklist_enabled = true
      # Large-cache stays at Heap::DEFAULT_LARGE_CACHE_RETAIN (4 MiB). A 1 MiB
      # Linux floor was tried with HOLED default-on and did not help; adaptive
      # still grows on high hit-rate. Escape: GCRY_LARGE_CACHE=<bytes>.
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

  # Use LibC.getenv — Crystal's ENV uses `once` + Fiber, unavailable in GC.init.
  private def self.apply_env_config(heap : Gcry::Heap) : Nil
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
    {% end %}

    if env_flag_one?("GCRY_INTERIOR")
      heap.allow_interior_pointers = true
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
    # Parallel parked-fiber scrub window below saved SP (default 512).
    if fsb = env_u64("GCRY_FIBER_SCRUB_BYTES")
      heap.fiber_scrub_bytes = fsb if fsb >= 64 && fsb <= 8192
    end
    # Compiler stack maps (docs/STACK_MAPS.md). Section load is lazy on first
    # collect. Needs CRYSTAL_EMIT_STACKMAP=1 binaries for real hits.
    #   GCRY_PRECISE_STACK=1 — hybrid (precise + conservative stacks)
    #   GCRY_PRECISE_STACK=2 — exclusive (no conservative stack word scan)
    case env_digit("GCRY_PRECISE_STACK")
    when 1
      heap.precise_stack_roots = true
    when 2
      heap.precise_stack_roots = true
      heap.precise_stack_exclusive = true
      warn_unsupported_env("gcry: GCRY_PRECISE_STACK=2 exclusive — research only; incomplete maps can UAF\n")
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
    def self.pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*, start : Void* -> Void*, arg : Void*)
      LibC.pthread_create(thread, attr, start, arg)
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
