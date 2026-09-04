{% if flag?(:linux) %}
  require "./platform/linux_roots"
  require "./platform/linux_stack"
  require "./platform/linux_softdirty"
  require "./platform/linux_stw"
  require "./platform/linux_pagemap"
  require "./platform/linux_proc_sp"
  require "./platform/linux_thread_census"
  require "./platform/linux_address_space"
  require "./platform/linux_fork"
{% elsif flag?(:darwin) %}
  require "./platform/darwin_stubs"
  require "./platform/darwin_roots"
  require "./platform/darwin_stack"
  require "./platform/darwin_stw"
  require "./platform/linux_fork"
{% end %}

require "./platform/thread_staging"
require "./mark"
require "./roots"
require "./stack_maps"
require "./finalizer"

module Gcry
  class Heap
    DEFAULT_GC_THRESHOLD = 4194304_u64 # 4 MiB — library / conservative
    # Boehm-shaped sizing for the process heap: after each collection the next
    # threshold is the live bytes the sweep just measured, times a factor,
    # clamped. Allocation between collections then scales with the live set,
    # so a small live set collects often and cheaply and a large one does not
    # thrash; the warm-retention budget follows it, so what one cycle
    # allocates is what the sweep keeps. `GCRY_THRESHOLD` pins a fixed
    # threshold and disables this; `GCRY_THRESHOLD_FACTOR` is the factor in
    # percent (default 100).
    ADAPTIVE_THRESHOLD_MIN =  8388608_u64 # 8 MiB
    ADAPTIVE_THRESHOLD_MAX = 67108864_u64 # 64 MiB
    property adaptive_threshold : Bool = false
    property adaptive_threshold_pct : UInt64 = 100_u64
    property warm_retain_follows_threshold : Bool = false

    private def adapt_threshold_after_sweep : Nil
      return unless @adaptive_threshold
      live = @size_class_live_bytes &+ (@large_mapped_bytes > @large_free_bytes ? @large_mapped_bytes - @large_free_bytes : 0_u64)
      want = live &* @adaptive_threshold_pct // 100_u64
      want = ADAPTIVE_THRESHOLD_MIN if want < ADAPTIVE_THRESHOLD_MIN
      want = ADAPTIVE_THRESHOLD_MAX if want > ADAPTIVE_THRESHOLD_MAX
      @gc_threshold = want
      @empty_chunk_warm_retain = want if @warm_retain_follows_threshold
    end

    # EC_PARALLELISM>1: 32 MiB majors storm under HTTP (~150+/20s). 64 MiB
    # cut Kemal EC4 /json ~47k→~53k (d=20); 128 MiB no further win.
    PROCESS_GC_THRESHOLD_PARALLEL  = 67108864_u64 # 64 MiB
    DEFAULT_NURSERY_THRESHOLD      =   524288_u64 # 512 KiB minor
    MIN_ADAPTIVE_NURSERY_THRESHOLD =    65536_u64 # 64 KiB floor
    MAX_ADAPTIVE_NURSERY_THRESHOLD =  8388608_u64 # 8 MiB cap — prevents unbounded growth
    NURSERY_SURVIVAL_HISTORY       =           10 # ring buffer for adaptive threshold
    TARGET_SURVIVAL_PCT            =       50_u64
    DEFAULT_INCREMENTAL_WORK       =         1024
    MAX_AUTO_INCREMENTAL_SLICES    =            4 # slices per alloc when debt is high
    STATIC_ROOT_REFRESH_INTERVAL   =       64_u64 # majors between /proc/self/maps refresh

    getter collections : UInt64 = 0_u64
    getter minor_collections : UInt64 = 0_u64
    getter major_collections : UInt64 = 0_u64
    getter last_pause_ns : UInt64 = 0_u64
    getter max_pause_ns : UInt64 = 0_u64
    getter total_pause_ns : UInt64 = 0_u64
    getter pause_count : UInt64 = 0_u64
    # Boehm-shaped prof counters (updated around collections / free).
    getter bytes_before_gc : UInt64 = 0_u64
    getter bytes_reclaimed_since_gc : UInt64 = 0_u64
    getter reclaimed_bytes_before_gc : UInt64 = 0_u64
    getter expl_freed_bytes_since_gc : UInt64 = 0_u64
    getter? enabled : Bool = true
    property gc_threshold : UInt64 = DEFAULT_GC_THRESHOLD
    # Library tests free manually — auto minor is opt-in (process GC enables it).
    property nursery_threshold : UInt64 = UInt64::MAX
    property incremental_work : Int32 = DEFAULT_INCREMENTAL_WORK
    # When true, auto major uses collect_a_little slices instead of full STW.
    # ON on Linux (page-dirty barrier makes incremental sound), OFF on Darwin
    # (lacks soft-dirty — incremental would crash under pointer churn).
    # The property default is always false; gc_override.cr sets the platform
    # default at process-GC boot. Override via `heap.incremental_auto = true`
    # or `GCRY_INCREMENTAL` / `GCRY_DISABLE_INCREMENTAL` env vars.
    property incremental_auto : Bool = false
    # When true, fully free size-class chunks beyond empty_chunk_retain are
    # munmap'd (excess) or kept dormant with MADV_DONTNEED (within retain).
    # Library default false; process GC enables adaptive release.
    property release_empty_chunks : Bool = false
    # Bytes of fully-free chunks to keep mapped+warm (no DONTNEED, no munmap)
    # for reuse. Takes priority over empty_chunk_retain. Opt-in via
    # GCRY_EMPTY_CHUNK_WARM_RETAIN — thr middle path vs KEEP_CHUNKS.
    property empty_chunk_warm_retain : UInt64 = 0_u64
    # Bytes of fully-free chunks to keep dormant (DONTNEED) for reuse.
    property empty_chunk_retain : UInt64 = DEFAULT_EMPTY_CHUNK_RETAIN
    # MADV_DONTNEED free pages in partially-live chunks after major (Linux).
    # Partial-page MADV_DONTNEED on sparse chunks (opt-in — STW cost).
    property madvise_free_pages : Bool = false
    # Mostly-empty reclaim (Linux research): high-free-ratio non-empty chunks
    # get post-STW free-page advice WITHOUT HOLED freelist rebuild.
    # Opt-in via GCRY_MOSTLY_EMPTY=1. Mutual exclusion with madvise_free_pages.
    property mostly_empty_release : Bool = false
    # Qualify when live_payload * 100 <= usable_payload * pct (default 25%).
    property mostly_empty_max_live_pct : UInt32 = 25_u32
    # Max free-page bytes advised per major (0 = unlimited).
    property mostly_empty_budget : UInt64 = 0_u64
    # false = MADV_FREE (preserve content / freelist); true = unlink + DONTNEED.
    property mostly_empty_dontneed : Bool = false
    getter mostly_empty_bytes : UInt64 = 0_u64
    getter mostly_empty_chunks : UInt64 = 0_u64
    # Tight small-heap growth (alloc locality): prefer newest chunk's freelist
    # so older chunks can go fully empty → munmap. Opt-in / Linux research;
    # see GCRY_TIGHT_GROW. Not TLAB.
    property tight_grow : Bool = false
    # Collect once before mapping a new size-class chunk when freelist empty
    # and the small heap is already sparse (see tight_grow_gc_pct).
    property tight_grow_gc : Bool = true
    # small_free*100 >= small_mapped*pct → allow GC-before-grow (default 35).
    property tight_grow_gc_pct : UInt32 = 35_u32
    getter tight_grow_collects : UInt64 = 0_u64
    getter tight_grow_prefer_allocs : UInt64 = 0_u64
    getter tight_grow_maps : UInt64 = 0_u64
    getter dormant_chunk_bytes : UInt64 = 0_u64
    # Fully-dormant size-class chunks skipped in sweep (no block walk).
    getter sweep_dormant_skips : UInt64 = 0_u64
    getter dontneed_bytes : UInt64 = 0_u64
    # Bytes the HOLED free-page walk alone released (`GCRY_PAGE_DONTNEED=1`);
    # `dontneed_bytes` also counts the dormant flush every configuration runs.
    getter page_release_bytes : UInt64 = 0_u64
    # Page-release ranges that did not lie inside the chunk they were computed
    # from. `release_free_pages_in_chunk` only ever checked the range against
    # the chunk's own `data_start`/`data_end`, which is a self-consistency check
    # — it says nothing if the header those came from is not a live chunk's.
    # A `madvise(MADV_DONTNEED)` that lands outside the heap zeroes memory gcry
    # does not own.
    getter madvise_range_rejects : UInt64 = 0_u64

    # Chunks still reachable from `@chunks` that the ledger says were already
    # released. `unlink_chunk` runs inside the detach that precedes every
    # release, so this should be impossible — and a crash in
    # `update_heap_bounds_after_unmap`, eight bytes into a released chunk,
    # says it is not. Only counted when a ledger or guard is recording.
    getter released_chunks_still_linked : UInt64 = 0_u64

    # Research only: close the Monitor gate inside `stop_world` (after
    # `@roots_lock` is taken) instead of before it — the ordering that
    # deadlocked on aarch64.
    property monitor_gate_late_close : Bool = false

    # Research only: flush empty chunks without `@alloc_lock`, which is what it
    # did before 2026-08-24.
    property empty_flush_unlocked : Bool = false

    # Hold off automatic collection for a window a caller cannot be interrupted
    # in. `MonitorGate` uses it: the Monitor is never signal-suspended, so a
    # stop waits for it by spinning on a busy bit — and a collection started
    # inside that window would wait for the mutex the spinner holds.
    def suppress_collect_enter : Nil
      @suppress_collect.add(1)
    end

    def suppress_collect_leave : Nil
      @suppress_collect.sub(1)
    end

    # Research only: skip the check and issue the syscall anyway, which is what
    # it did before 2026-08-23.
    property madvise_unchecked : Bool = false
    # Research only (`GCRY_LARGE_RELEASE_FROM_BASE=1`): restore the pre-2026-09-03
    # lower bound in the large-freelist page release, which started the range at
    # the chunk base and so covered the chunk's own header page. It exists so
    # `make large-freelist-madvise` has a positive control — a guard that can
    # only ever report zero proves nothing.
    property large_release_from_base : Bool = false
    # When false (default for library heaps), only object-base pointers are marked.
    # Process GC keeps this false; GCRY_INTERIOR=1 enables interiors for C embeds.
    property allow_interior_pointers : Bool = false
    # Follow candidates whose *value* is not word-aligned. Crystal-emitted
    # references are aligned, so the default drops misaligned words cheaply
    # before find_block. But an interior pointer into a byte buffer
    # (`str.to_unsafe + 3`) is a legitimate misaligned root that bdwgc would
    # honour via GC_base. Root-completeness knob — see docs/SOUND-DEFAULTS.md.
    # GCRY_SOUND=1 turns it on; GCRY_ALIGNED_CANDIDATES=1 forces it back off.
    property scan_unaligned_candidates : Bool = false
    # Reject ambient root candidates (stack/static) whose payload type_id looks
    # absurd. Heap-scan marks stay ungated so Array/Hash buffers remain reachable.
    # Process GC default-on; GCRY_DISABLE_TYPE_ID_GATE=1 escapes.
    property type_id_gate : Bool = false
    # When true with type_id_gate, also gate Stack/Thread ambient roots (RSS
    # trade-off; unsafe for Channel buffers — see mark_root_candidate).
    property type_id_gate_stacks : Bool = false
    getter type_id_root_rejects : UInt64 = 0_u64
    # Per-source breakdown of ambient-root rejects. Combined with
    # type_id_root_rejects: stack + static + thread == total.
    # Reset each major collection. Use these to attribute false roots to the
    # specific scan phase (fiber/mutator stack, BSS/data segment, TLS).
    getter type_id_stack_rejects : UInt64 = 0_u64
    getter type_id_static_rejects : UInt64 = 0_u64
    getter type_id_thread_rejects : UInt64 = 0_u64
    # type_id_root_rejections that were later revisited and would have passed —
    # useful for tuning the upper-bound heuristic (false negatives == UAF risk).
    # When non-zero in production, the gate is too strict and the upper bound
    # (1_000_000) needs to grow or the layout-aware gate must take over.
    getter type_id_root_false_negatives : UInt64 = 0_u64
    # Precise scan via Gcry::Layout (type_id → pointer offsets). Unknown → conservative.
    property layout_precise : Bool = true
    getter layout_precise_scans : UInt64 = 0_u64
    # Large chunks the sweep found published but not yet filled in. Non-zero
    # means a mutator was suspended between `map_chunk` and `set_used`.
    getter sweep_large_uninitialised : UInt64 = 0_u64
    # Same tell on the small path: a zeroed header (size 0, flags 0) inside a
    # size-class chunk is a mutator frozen mid-`refill_size_class`. The sweep
    # treats the chunk as live instead of reclaiming blocks that never lived.
    getter sweep_small_uninitialised : UInt64 = 0_u64
    # Chunks the bitmap sweep left untouched because an allocation cursor was
    # on them — the cursor analogue of `sweep_small_uninitialised`. Nonzero is
    # normal (one per class per cycle at most); it is here so a silence is
    # readable rather than assumed.
    getter sweep_cursor_pinned : UInt64 = 0_u64
    # Cursor-held empty chunks the after-world sweep retired, so they could
    # reach the release path. Its twin above must not be the only one that
    # moves: a `pinned` that grows while this stays zero is a chunk nobody will
    # ever release, which is what it meant until 2026-09-04.
    getter sweep_cursor_retired : UInt64 = 0_u64
    # Large blocks offered to the cache while already on a freelist, and blocks
    # taken off a freelist that were not FREE. Either one is the same memory
    # reaching two owners.
    getter large_cached_twice : UInt64 = 0_u64
    getter large_taken_used : UInt64 = 0_u64
    # `GCRY_DYING_AUDIT_MIN_BYTES` — ignore dying blocks smaller than this, so
    # the once-per-collection address-space walk can be aimed at a size.
    property dying_audit_min_bytes : UInt64 = 0_u64
    # Hash-kind objects whose own body was word-scanned alongside the entry
    # walk. Silence here would mean the collision guard is not engaged.
    getter layout_hash_bodies : UInt64 = 0_u64
    # When true, load `.llvm_stackmaps` and mark_precise_root.
    # Opt-in: GCRY_PRECISE_STACK=1 (hybrid) or =2 (exclusive). See STACK_MAPS.md.
    property precise_stack_roots : Bool = false
    # When true with precise_stack_roots: skip conservative mutator / other-thread
    # stack word scans. Parked fibers still word-scanned unless
    # precise_stack_fibers_exclusive (GCRY_PRECISE_FIBERS=1). Research — UAF risk.
    property precise_stack_exclusive : Bool = false
    # When true with exclusive: parked fibers use leaf window (or 0 = precise
    # only) instead of full top→bottom word scan. See GCRY_PRECISE_FIBERS.
    property precise_stack_fibers_exclusive : Bool = false
    # Bytes of parked active stack (from stack_top toward bottom) to still
    # word-scan under fibers_exclusive. Default 8 KiB — FP-fill alone misses
    # stack slots outside tiny [rsp,fp) spans (exclusive_fiber_smoke SEGV).
    # Escape: GCRY_PRECISE_FIBER_LEAF=0 for maps+fill-only research.
    property precise_stack_fiber_leaf_bytes : UInt64 = 8192_u64
    # When fibers_exclusive: also word-scan each FP-chain frame body
    # (additive with LEAF). Default on for exclusivef research.
    property precise_stack_fiber_fp_fill : Bool = true
    # When true: skip FP-fill on frames with a non-empty stackmap. Research —
    # acik UAF (map hit ≠ complete lives). Default false = fill every frame.
    # See GCRY_FIBER_FP_FILL_MISS_ONLY.
    property precise_stack_fiber_fp_fill_miss_only : Bool = false
    getter precise_stack_roots_marked : UInt64 = 0_u64
    getter parked_fp_fill_frames : UInt64 = 0_u64
    getter parked_fp_fill_bytes : UInt64 = 0_u64
    getter parked_fp_fill_skipped_frames : UInt64 = 0_u64
    getter parked_fp_fill_skipped_bytes : UInt64 = 0_u64
    # Research: first-mark attribution by root source (GCRY_LIVE_ATTR=1).
    # Stack/Static/Thread/Precise = ambient seeds; Heap = edge closure.
    property live_attr_roots : Bool = false
    # Optional: first-mark counts for one type_id (GCRY_LIVE_ATTR_WATCH_TID).
    # acik idle-drain: TCPSocket ≈ 441 in tip exclusive bin.
    property live_attr_watch_tid : Int32 = 0
    getter first_mark_stack_objects : UInt64 = 0_u64
    getter first_mark_stack_bytes : UInt64 = 0_u64
    getter first_mark_stack_atomic_bytes : UInt64 = 0_u64
    getter first_mark_parked_objects : UInt64 = 0_u64
    getter first_mark_parked_bytes : UInt64 = 0_u64
    getter first_mark_parked_atomic_bytes : UInt64 = 0_u64
    getter first_mark_static_objects : UInt64 = 0_u64
    getter first_mark_static_bytes : UInt64 = 0_u64
    getter first_mark_static_atomic_bytes : UInt64 = 0_u64
    getter first_mark_thread_objects : UInt64 = 0_u64
    getter first_mark_thread_bytes : UInt64 = 0_u64
    getter first_mark_thread_atomic_bytes : UInt64 = 0_u64
    getter first_mark_precise_objects : UInt64 = 0_u64
    getter first_mark_precise_bytes : UInt64 = 0_u64
    getter first_mark_precise_atomic_bytes : UInt64 = 0_u64
    getter first_mark_heap_objects : UInt64 = 0_u64
    getter first_mark_heap_bytes : UInt64 = 0_u64
    getter first_mark_heap_atomic_bytes : UInt64 = 0_u64
    getter first_mark_watch_stack : UInt64 = 0_u64
    getter first_mark_watch_parked : UInt64 = 0_u64
    getter first_mark_watch_static : UInt64 = 0_u64
    getter first_mark_watch_thread : UInt64 = 0_u64
    getter first_mark_watch_precise : UInt64 = 0_u64
    getter first_mark_watch_heap : UInt64 = 0_u64
    getter layout_conservative_scans : UInt64 = 0_u64
    # When true, scan writable process mappings as roots (needed as process GC).
    property scan_static_roots : Bool = false
    # Default `true`, except under headerless, where the setter below explains
    # why a nursery cannot exist and the initial value must agree with it.
    {% if flag?(:gcry_headerless) %}
      getter nursery_enabled : Bool = false
    {% else %}
      getter nursery_enabled : Bool = true
    {% end %}

    def nursery_enabled=(value : Bool) : Bool
      {% if flag?(:gcry_headerless) %}
        # Phase 7.3: nursery chunks are header-based and excluded from bitmap
        # chunks, so a headerless heap cannot run one. Enabling it put a
        # freelist-era allocator under objects with no header — the
        # thread_block_audit `lives-minor` arm hung inside its address-space
        # audit for exactly this reason. Silently off, never on.
        @nursery_enabled = false
      {% else %}
        @nursery_enabled = value
      {% end %}
      refresh_fast_path
      @nursery_enabled
    end

    # Adaptive nursery threshold: adjusted after each minor based on the
    # survival rate of the last N minors. When survival is below the target
    # (50%), the threshold shrinks to collect earlier; above, it grows to
    # reduce collection frequency. Clamped to [MIN_ADAPTIVE_NURSERY_THRESHOLD,
    # MAX_ADAPTIVE_NURSERY_THRESHOLD]. Disable with GCRY_DISABLE_ADAPTIVE_NURSERY=1.
    property adaptive_nursery : Bool = true
    # Ring buffer of nursery alloc bytes before each minor (last N entries).
    @nursery_alloc_history = StaticArray(UInt64, NURSERY_SURVIVAL_HISTORY).new(0_u64)
    # Ring buffer of surviving nursery bytes after each minor.
    @nursery_survival_history = StaticArray(UInt64, NURSERY_SURVIVAL_HISTORY).new(0_u64)
    # Current index in the ring buffers.
    @nursery_history_pos : Int32 = 0
    # Number of entries recorded so far.
    @nursery_history_count : Int32 = 0
    getter nursery_survival_bytes : UInt64 = 0_u64
    getter nursery_alloc_before_minor : UInt64 = 0_u64
    getter nursery_survival_rate_pct : UInt64 = 100_u64
    # Process GC: Crystal 1.21+ always has a Monitor (SYSMON) thread even at
    # ExecutionContext parallelism 1. Without STW + scanning that thread's
    # current fiber stack, live objects are swept → heap corruption under load.
    property stop_the_world : Bool = false
    # Torture: collect every N allocations (0 = off). Process: GCRY_STRESS=1.
    property stress_every : Int32 = 0
    @alloc_ops : UInt64 = 0_u64

    getter unmapped_bytes : UInt64 = 0_u64
    # Last major STW phase timings (ns) — for /gc-stats and tuning.
    getter last_phase_clear_ns : UInt64 = 0_u64
    # Parked-fiber stack scrub (inside STW roots window; split for Parallel A/B).
    getter last_phase_scrub_ns : UInt64 = 0_u64
    getter last_phase_roots_ns : UInt64 = 0_u64
    getter last_phase_static_ns : UInt64 = 0_u64
    getter last_phase_stacks_ns : UInt64 = 0_u64
    getter last_phase_mark_ns : UInt64 = 0_u64
    getter last_phase_sweep_ns : UInt64 = 0_u64
    # Collect orchestration (ns) — EC>1 thr outliers: SpinLock wait / STW stop-start / flush.
    getter last_phase_post_stw_wait_ns : UInt64 = 0_u64
    getter last_phase_stw_stop_ns : UInt64 = 0_u64
    getter last_phase_stw_start_ns : UInt64 = 0_u64
    getter last_phase_flush_ns : UInt64 = 0_u64
    getter max_post_stw_wait_ns : UInt64 = 0_u64
    getter post_stw_wait_total_ns : UInt64 = 0_u64
    getter post_stw_wait_count : UInt64 = 0_u64
    getter collect_coalesced : UInt64 = 0_u64
    # Other-thread stack scans clamped to captured RSP (vs full pthread range).
    getter sp_clamp_hits : UInt64 = 0_u64
    getter sp_clamp_fallbacks : UInt64 = 0_u64
    # Candidate words read out of a *suspended* thread's GP registers, last
    # collect. Zero here does not mean "those registers held nothing" — it is
    # also what a platform that never reports them looks like, which is exactly
    # how Darwin dropped live objects until 2026-08-11 (`each_thread_greg` was an
    # empty stub while this scan called it). The two readings are worth
    # separating from the outside, so `bench/greg_roots.cr` gates on it.
    getter thread_greg_candidates : UInt64 = 0_u64
    # Execution-context structures pinned explicitly by `scan_thread_roots`
    # (schedulers, run queues, event loop, stack pool), last collect. Same
    # reading problem as the counter above, and a sharper one: the whole pin
    # block sits behind a macro gate on `Thread.@execution_context`, so on a
    # compiler that does not declare that ivar it compiles out entirely and the
    # only coverage left is the conservative Thread body scan — which the
    # comment on that block already records as insufficient (Kemal EC4 SEGV
    # @ …0008). Zero and "compiled out" are indistinguishable without this.
    getter ec_root_pins : UInt64 = 0_u64
    # Pointer-bearing ivars of the Parallel EC structures that the pin block
    # could *not* cover. Wide ones it can — a Proc, a Tuple,
    # `(Fiber::ExecutionContext | Nil)` get every word of the slot marked — so
    # this is the shape with no sound answer left: pointer-bearing and narrower
    # than a pointer. Zero on Crystal 1.21.0, and `make scheduler-roots` asserts
    # it stays zero, because an upstream ivar of that shape is a root the block
    # would otherwise drop without a word about it.
    getter ec_root_unpinned_ivars : UInt64 = 0_u64
    # Execution-context queue audit (`GCRY_EC_QUEUE_AUDIT=1`, default off).
    # `slots` is per-collect — it says the walk engaged, and a walk that silently
    # covered nothing is the failure mode every gate in this milestone is about.
    # `faults` is **cumulative on purpose**: it is evidence of a corruption that
    # already happened, and a per-collect reset would erase it by the next
    # collection, which is exactly what makes the soak SEGV unbisectable today.
    # Split by structure so "the walk engaged" can be told apart from "the walk
    # engaged on the half that happened to be busy": the ring and the global list
    # are populated by different traffic, and a harness that only ever fills one
    # would report coverage it does not have.
    getter ec_queue_audit_ring_slots : UInt64 = 0_u64
    getter ec_queue_audit_list_slots : UInt64 = 0_u64
    getter ec_queue_audit_faults : UInt64 = 0_u64
    # The word the most recent fault was reported for. Cumulative like the count:
    # it is the evidence, and it is also what makes a gate able to say *which*
    # slot was rejected rather than only that something was.
    getter ec_queue_audit_last_fault : UInt64 = 0_u64
    # Walk the Parallel EC run queues inside STW and check every slot is a live
    # Fiber. Off by default: bounded, but it is inside the pause.
    property ec_queue_audit : Bool = false

    # Overwrite a block's payload when it is freed (`GCRY_POISON_FREED=1`).
    # Default off — it is a memset per freed block. What it buys is the
    # difference between a crash on `0x7f1700000149`, which three sessions have
    # argued about, and a crash on `0xdeadf2eedeadf2ee`, which says
    # use-after-free and nothing else. Every small free funnels through
    # `push_size_class_free`; large blocks are poisoned at their own site.
    property poison_freed : Bool = false
    getter poisoned_blocks : UInt64 = 0_u64
    # Parked-fiber scan starts raised to the stack's low-water mark. Whether the
    # skip engages at all is not obvious from the outside: it needs multi-mutator
    # STW, which is `Thread` count > 2, and a fat app can sit right on that
    # boundary and cross it between collections. Without these you can only infer
    # engagement from a benchmark delta.
    # Research only (GCRY_STW_TEST_STALL_MS, default 0): hold the world stopped
    # inside the thread-stacks phase. It exists so the STW watchdog has a run it
    # is *expected* to fire on — a watchdog whose green is reachable without ever
    # seeing it trigger says nothing. Never ship non-zero.
    property stw_test_stall_ms : UInt64 = 0_u64

    # Research only (`GCRY_PAGE_RELEASE_TEST_STALL_MS`, default 0): sleep
    # between building the free-page mask and the release syscalls, so the
    # window a mutator can allocate into becomes wide enough to measure.
    property page_release_test_stall_ms : UInt64 = 0_u64

    # `GCRY_MOSTLY_EMPTY_UNLINK=1` — research arm: unlink the free-only runs
    # from the class freelist while keeping `MADV_FREE`, so the unlink can be
    # measured apart from the syscall change `MOSTLY_EMPTY_MODE=dontneed`
    # makes at the same time.
    property mostly_empty_unlink : Bool = false

    # Research only: hold the **suspend** phase, which is a different one and the
    # only one the aarch64 hang has ever been seen in. `stw_test_stall_ms`
    # stalls thread-stacks, so it cannot exercise the report that names the
    # thread being waited for. Never ship non-zero.
    property stw_test_suspend_stall_ms : UInt64 = 0_u64

    getter low_water_skips : UInt64 = 0_u64
    getter low_water_skipped_bytes : UInt64 = 0_u64
    # Occupancy after last major (size-class chunks only).
    getter size_class_chunk_count : UInt64 = 0_u64
    getter fully_free_chunk_bytes : UInt64 = 0_u64
    getter released_chunk_bytes : UInt64 = 0_u64
    getter size_class_live_bytes : UInt64 = 0_u64
    # Kept size-class chunk fill histogram (live_payload / usable_payload).
    getter chunk_fill_lt25 : UInt64 = 0_u64
    getter chunk_fill_lt50 : UInt64 = 0_u64
    getter chunk_fill_lt75 : UInt64 = 0_u64
    getter chunk_fill_ge75 : UInt64 = 0_u64

    # High end of the stack (stack grows down). Null disables stack scanning.
    @stack_bottom : Void* = Pointer(Void).null
    @roots = Roots::Set.new
    # Serializes Roots::Set mutate vs STW: stop_world must not freeze a thread
    # mid-add_root/delete_root (half-linked / freed node → SEGV on @roots.each).
    @roots_lock = Crystal::SpinLock.new
    # Serializes post-STW munmap/madvise vs the next collect's stop_world.
    # pthread mutex (not SpinLock): under Parallel, SpinLock waiters burned a
    # whole EC worker for hundreds of ms while another flushes — ~8–11s of
    # wait in a 20s Kemal /json run. Embedded LibC mutex — no GC malloc at boot.
    @post_stw_mutex = uninitialized LibC::PthreadMutexT
    @mark_stack = MarkStack.new
    @finalizers = Finalizers::Registry.new
    @before_collect_callbacks = [] of -> Nil
    @collecting = false
    @running_finalizers = false
    @incremental_marking = false
    @inc_active = false
    @world_stopped = false
    # Thread that called stop_world — may allocate / take GC locks during STW.
    # Other threads (notably SYSMON, which we do not signal-suspend) must wait.
    @stw_owner : Thread? = nil
    # The same identity as `@stw_owner`, as a plain word.
    #
    # `chunk_containing` skips `@index_lock` while the world is stopped, on the
    # grounds that only the collector can be touching the chunk index then. Two
    # threads are documented exceptions to that in this same codebase: the EC
    # Monitor is signal-exempt and keeps running, and a thread that has not
    # published itself is neither suspended nor stopped. If either allocates
    # during a stop it reads the index unlocked while the sweep is calling
    # `index_remove` / `index_insert`, and a binary search over a shifting array
    # yields a garbage `ChunkHeader*`.
    #
    # `GCRY_INDEX_AUDIT=1` counts exactly that: an unlocked index read, during a
    # stop, by someone who is not the thread that stopped it. Comparing pthread
    # ids rather than `Thread.current` keeps the audit off the object graph.
    @stw_owner_pthread = 0_u64

    # `GCRY_INDEX_AUDIT=1`. Off by default: it costs a `pthread_self` on the
    # unlocked lookup path.
    property index_audit : Bool = false
    getter index_audit_runs : UInt64 = 0_u64
    # Index entries whose range starts inside the previous entry's, and
    # collections where the index and `@chunks` disagreed on how many chunks
    # exist. Either one means an address can resolve through a chunk record
    # that no longer describes it.
    getter index_overlaps : UInt64 = 0_u64
    getter index_count_mismatch : UInt64 = 0_u64
    # Releases refused because a chunk that is still indexed lived inside the
    # range. Non-zero means gcry was about to unmap live memory.
    getter release_hit_live : UInt64 = 0_u64
    # True while the post-STW dormant pass is walking. It takes no lock, so a
    # mutator reviving a dormant chunk during it is the window that would let
    # `MADV_DONTNEED` zero live objects.
    @dormant_flush_active = false
    getter dormant_revive_during_flush : UInt64 = 0_u64

    # Research only: clear `@world_stopped` after the resume loop rather than
    # before it, which is what `start_world` did until 2026-08-22.
    property stw_late_clear : Bool = false

    # Unlocked chunk-index reads during a stop, by a thread that is not the one
    # that stopped the world. Non-zero means the assumption `chunk_containing`
    # documents does not hold.
    getter index_unlocked_foreign : UInt64 = 0_u64
    # The same, counted for the collector itself, so a zero above is
    # distinguishable from an audit that never ran.
    getter index_unlocked_owner : UInt64 = 0_u64
    # The last foreign reader's pthread id, so the two candidate threads can be
    # told apart by name after the world restarts instead of by inference.
    getter index_unlocked_foreign_id : UInt64 = 0_u64

    # Cache reads whose index, bounds and array did not agree, and which fell
    # through to the binary search rather than trusting any of them. Non-zero is
    # the race being live; it must never turn into a returned chunk again.
    getter index_cache_torn : UInt64 = 0_u64

    # `GCRY_UNMAP_GUARD=1` — release a chunk with `mprotect(PROT_NONE)` instead
    # of `munmap`, and keep a record of it.
    #
    # A write into released heap memory faults either way, but an unmapped
    # region can only be described as "in no live chunk": the report cannot say
    # which chunk it was, how big, which release path let it go, or when. Under
    # the guard the address is still ours, so the report names all four. The
    # cost is address space, not memory — the pages are dropped by `PROT_NONE`
    # just as `munmap` drops them.
    #
    # Research only, and never a default: the address space is never reused, so
    # a long-running program under this knob will exhaust it.
    getter? unmap_guard : Bool = false
    getter? release_ledger : Bool = false

    # Arming zeroes the length column, because that column is the read
    # protocol: `guarded_release_at` skips a slot whose length is zero, which
    # is how a report walks past a record another thread is still writing.
    # `uninitialized` gives no such guarantee.
    def unmap_guard=(v : Bool) : Bool
      clear_guard_lengths if v
      @unmap_guard = v
    end

    # Record every chunk release without holding the address space, so a fault
    # on memory that has since been remapped can still name what used to be
    # there. See the note on `@guard_ring`.
    def release_ledger=(v : Bool) : Bool
      clear_guard_lengths if v
      @release_ledger = v
    end

    private def clear_guard_lengths : Nil
      i = 0
      while i < UNMAP_GUARD_SLOTS
        @guard_len[i] = 0_u64
        i += 1
      end
    end

    # Research only: raw-write a line for every large chunk mapped, so a range
    # the ledger names on a fault can be traced back to the allocation that
    # created it. The ledger says what was released; this says what it was.
    property trace_large : Bool = false

    # Which door a large chunk left by. The ledger names the *release*, which is
    # always the trim — but a chunk reaches the trim either because the sweep
    # found it unmarked or because someone called `GC.free` on it, and those are
    # different defects with different owners.
    getter large_cached_by_sweep : UInt64 = 0_u64
    getter large_cached_by_free : UInt64 = 0_u64

    # Live blocks found inside a page run at the moment it was about to be
    # released. The live-page mask is built by reading every block header with
    # no lock, and the `madvise` goes out afterwards — so a block allocated in
    # between is live memory in a range about to be dropped. Counting it is
    # binary where a crash-rate A/B is not: either a live block is in the run or
    # it is not.
    getter page_release_live_blocks : UInt64 = 0_u64
    # Runs skipped because that re-read found a live block. Without the
    # re-read they were released with the object still in them.
    getter page_release_skipped_runs : UInt64 = 0_u64
    # Chunks whose free-only page runs were taken off the class freelist
    # before the release syscall. Zero here means the unlink never ran and
    # a clean gate says nothing.
    getter page_release_unlinked_chunks : UInt64 = 0_u64

    # Research only: release a page run without re-reading its headers, which
    # is what it did before 2026-08-24.
    property page_release_unchecked : Bool = false

    # Research only: let the Darwin free-page walk visit bitmap-allocated
    # chunks, which is what it did before the stand-down in
    # `flush_pending_page_release_chunks`. The walk builds its free-page mask
    # from `BlockHeader.free?`, and on a bitmap chunk that flag is whatever
    # the carve left there — the streaming sweep never writes it — so the mask
    # bears no relation to occupancy. `make darwin-bitmap-page-release` uses
    # this to show what the stand-down is standing down from.
    property page_release_bitmap_walk : Bool = false

    # How many threads are inside `realloc`'s copy right now, and how many
    # collections have begun while at least one was. This measures the *window*
    # rather than its consequences: a crash-rate A/B cannot separate a 5 %
    # defect from a 2 % one without hundreds of runs, but a collection that
    # starts while a raw buffer is being copied into is either happening or it
    # is not.
    @realloc_copy_depth = Atomic(Int32).new(0)
    getter realloc_collect_overlaps : UInt64 = 0_u64

    protected def realloc_copy_enter : Nil
      @realloc_copy_depth.add(1)
    end

    protected def realloc_copy_leave : Nil
      @realloc_copy_depth.sub(1)
    end

    protected def note_realloc_overlap : Nil
      @realloc_collect_overlaps &+= 1 if @realloc_copy_depth.get > 0
    end

    # Research only: trim the large cache without `@alloc_lock`, which is what
    # it did before 2026-08-23 (src/gcry/heap.cr `trim_large_cache`).
    property trim_unlocked : Bool = false

    # Research only: let a mutator's trim `munmap` on the spot instead of
    # queueing the chunks for the collector, which is what it did before
    # 2026-08-23. That is the arm `bench/dormant_flush_race.cr` needs to stay
    # evidence: the post-STW flush walks read and write chunk headers holding
    # nothing, so a mutator that unmaps underneath them writes into a chunk
    # that is gone.
    property trim_immediate : Bool = false

    # Research only: hold the suspend phase open *after* the wait loop has
    # finished, which is what CI showed on aarch64 — `phase=suspend` with the
    # breadcrumb already cleared. `GCRY_STW_TEST_SUSPEND_STALL_MS` cannot
    # produce that shape: it stalls before the loop, with a thread named.
    property stw_test_postsuspend_stall_ms : UInt64 = 0_u64

    # Research only: hold the stop open after `PHASE_STOPPED` is entered — the
    # span that used to be reported as `suspend` and is where the aarch64 hangs
    # land. A phase with no control is a phase nobody has seen fire.
    property stw_test_stopped_stall_ms : UInt64 = 0_u64

    # Research only: stall between entering PHASE_SUSPEND and the first
    # `note_suspend` — the handshake and the locks the stop takes before it
    # suspends anyone. That is the region a stale breadcrumb used to report as
    # "every thread acknowledged".
    property stw_test_presuspend_stall_ms : UInt64 = 0_u64

    UNMAP_GUARD_SLOTS = 8192

    @guard_base = uninitialized StaticArray(UInt64, UNMAP_GUARD_SLOTS)
    @guard_len = uninitialized StaticArray(UInt64, UNMAP_GUARD_SLOTS)
    @guard_kind = uninitialized StaticArray(UInt8, UNMAP_GUARD_SLOTS)
    @guard_gen = uninitialized StaticArray(UInt64, UNMAP_GUARD_SLOTS)
    # First eight bytes of the released block's user data, captured while it is
    # still mapped. Under the ledger the range is handed back to the kernel, so
    # by the time a fault reports on it there is nothing left to read — the
    # identity has to be taken at release time or not at all. For a Crystal
    # reference the low four bytes are the type_id.
    @guard_tag = uninitialized StaticArray(UInt64, UNMAP_GUARD_SLOTS)
    # **Atomic, because every writer is a mutator and none of them holds a
    # lock.** `guard_release` runs from `GC.free` → `trim_large_cache` on
    # whichever thread frees, and the old code read this counter twice — once
    # to test it against the capacity, once to index with. Two frees racing
    # there index slot `UNMAP_GUARD_SLOTS`, which is an `IndexError` raised
    # inside a worker thread, and `Thread.new` stores that exception until
    # `join` instead of printing it. That is the whole of the
    # `dormant_flush_race` silent-hang family: the worker dies without a word,
    # the counter it was going to bump never arrives, and every waiter spins
    # forever (20 hangs of 66 children on two cores, 0 of 48 with this fixed
    # and the harness counting a dead worker).
    @guard_slot = Atomic(Int32).new(0)
    # Ledger mode: the same record, without holding the address space. The
    # guard answers "what was here" by never giving the mapping back, which
    # costs address space and — measured on 2026-08-23 — changes the defect it
    # was pointed at: 14 clean runs under the guard against roughly 2 in 12
    # without it. A fault that needs the range to be *reused* cannot happen
    # while the guard is preventing reuse. So record and unmap anyway, and
    # accept that the memory may be someone else's by the time the report is
    # read.
    # Same race, same fix: the ring cursor is bumped by whichever mutator
    # frees, and two of them sharing a slot lose one record and leave the other
    # half-written. The total is what the cursor counts; the ring index is that
    # total modulo the capacity.
    @guard_ring = Atomic(UInt64).new(0_u64)
    @guard_overflows = Atomic(UInt64).new(0_u64)

    def guard_overflows : UInt64
      @guard_overflows.get
    end

    # How many slots the guard has taken. Without this, "the guarded arm did
    # not crash" cannot be told apart from "the guard filled up early and the
    # arm was the baseline".
    def guard_slots_used : UInt64
      if @unmap_guard
        slot = @guard_slot.get
        (slot > UNMAP_GUARD_SLOTS ? UNMAP_GUARD_SLOTS : slot).to_u64
      else
        total = @guard_ring.get
        total > UNMAP_GUARD_SLOTS ? UNMAP_GUARD_SLOTS.to_u64 : total
      end
    end

    GUARD_KIND_EMPTY_CHUNK = 0_u8
    GUARD_KIND_LARGE       = 1_u8

    # Hold a released range unmapped-but-unreturned for N collections before
    # giving it back to the kernel.
    #
    # `GCRY_UNMAP_GUARD=1` — which never calls `munmap` at all — took the
    # acikturkiye crash from 3 of 6 to 0 of 11 with the guard verified engaged.
    # That says the crash needs the address handed back, but not *how long*
    # after the release the danger lasts. This bounds it: if holding a range
    # for one collection is enough, whatever still refers to it is dropped by
    # the next mark, and that is a much smaller place to look than "somewhere".
    #
    # `mprotect(PROT_NONE)` first, so the pages are returned to the OS exactly
    # as `munmap` would return them and only the address stays reserved — the
    # cost is address space, not RSS.
    QUARANTINE_SLOTS = 4096
    @q_base = uninitialized StaticArray(UInt64, QUARANTINE_SLOTS)
    @q_len = uninitialized StaticArray(UInt64, QUARANTINE_SLOTS)
    @q_gen = uninitialized StaticArray(UInt64, QUARANTINE_SLOTS)
    @q_head = 0
    @q_count = 0
    # `GCRY_RELEASE_QUARANTINE=<collections>`; 0 disables.
    property release_quarantine : UInt64 = 0_u64
    getter quarantined_releases : UInt64 = 0_u64
    getter quarantine_forced_drains : UInt64 = 0_u64

    def quarantine_held : UInt64
      @q_count.to_u64
    end

    # Returns true when the caller must not unmap: the range is held here.
    protected def quarantine_release(base : UInt64, len : UInt64) : Bool
      return false if @release_quarantine == 0
      if @q_count >= QUARANTINE_SLOTS
        # Full. Give the oldest back now rather than growing without bound;
        # counted, because a quarantine that is always full is not a
        # quarantine and its zero would not mean anything.
        i = @q_head
        LibC.munmap(Pointer(Void).new(@q_base[i]), LibC::SizeT.new(@q_len[i]))
        @q_head = (i + 1) % QUARANTINE_SLOTS
        @q_count -= 1
        @quarantine_forced_drains &+= 1
      end
      # Drop the pages; keep the address.
      LibC.mprotect(Pointer(Void).new(base), LibC::SizeT.new(len), LibC::PROT_NONE)
      i = (@q_head + @q_count) % QUARANTINE_SLOTS
      @q_base[i] = base
      @q_len[i] = len
      @q_gen[i] = @collections
      @q_count += 1
      @quarantined_releases &+= 1
      true
    end

    # Give back everything held for at least `@release_quarantine` collections.
    # Entries are appended in collection order, so the head is always the
    # oldest and the walk can stop at the first one that is too young.
    protected def drain_release_quarantine : Nil
      return if @release_quarantine == 0
      while @q_count > 0
        i = @q_head
        break if @collections - @q_gen[i] < @release_quarantine
        LibC.munmap(Pointer(Void).new(@q_base[i]), LibC::SizeT.new(@q_len[i]))
        @q_head = (i + 1) % QUARANTINE_SLOTS
        @q_count -= 1
      end
    end

    # Direct-mapped record of "this base is currently released", so a release
    # can ask whether the same base is being let go twice.
    #
    # The question is worth asking because everything else has come back
    # negative. In the acikturkiye crash the dying block is unreferenced by
    # every measure gcry has — no marked parent, no root, no thread outside the
    # stopped set — and yet a mutator writes into its range afterwards. A
    # release that runs twice over one base explains that without any of them:
    # the first is correct, the kernel hands the same address back to the next
    # `mmap`, and the second unmaps a chunk that is alive and whose owner has
    # every right to be writing into it.
    #
    # Keyed on `base >> 12` and O(1) at both ends, because the alternative —
    # walking the 8192-slot ring on every map and every release — is slow
    # enough to change the timing of the very race it is looking for.
    # Collisions lose a record; they never invent one.
    RELEASE_MAP_SLOTS = 8192
    @rel_base = uninitialized StaticArray(UInt64, RELEASE_MAP_SLOTS)
    @rel_live = uninitialized StaticArray(Bool, RELEASE_MAP_SLOTS)
    # Which path released the base. A double release is only actionable once
    # you know which two paths raced; the pair names the bug.
    @rel_kind = uninitialized StaticArray(UInt8, RELEASE_MAP_SLOTS)
    @rel_booted = false
    # Bases released while an earlier release of the same base had not been
    # cancelled by a remap.
    getter release_double : UInt64 = 0_u64
    # Released bases the kernel handed back to a later `mmap`. Silence here
    # would mean the cancel side never fires and the counter above is unread.
    getter release_remapped : UInt64 = 0_u64
    # `GCRY_ALWAYS_CLEAR=1`: zero every allocation, including the ones whose
    # bytes are already believed to be zero.
    property always_clear : Bool = false

    private def release_map_slot(base : UInt64) : Int32
      ((base >> 12) % RELEASE_MAP_SLOTS).to_i32
    end

    private def release_map_boot : Nil
      return if @rel_booted
      @rel_booted = true
      i = 0
      while i < RELEASE_MAP_SLOTS
        @rel_base[i] = 0_u64
        @rel_live[i] = false
        @rel_kind[i] = 0_u8
        i += 1
      end
    end

    # Bytes actually handed to the mark as static roots, and the least any
    # collection has handed it. The ranges the parser finds are one thing; what
    # survives `each_static_range_excluding_heap` is what the mark sees, and a
    # collection that scans far less than the others is a collection where the
    # globals were not roots.
    getter static_scanned_last : UInt64 = 0_u64
    getter static_scanned_min : UInt64 = UInt64::MAX
    getter static_scanned_max : UInt64 = 0_u64

    protected def note_static_scanned(bytes : UInt64) : Nil
      @static_scanned_last = bytes
      @static_scanned_min = bytes if bytes < @static_scanned_min
      # Report a collapse where it happens. A child that dies of a missed root
      # never reaches the line that prints these counters, so a counter read at
      # exit is a counter read only on the runs that had nothing to say.
      if @static_scanned_max > 0 && bytes * 2 < @static_scanned_max
        @static_scanned_drops &+= 1
        if @static_scanned_drops == 1
          buf = uninitialized UInt8[224]
          len = 0
          len = RawOut.append(buf.to_unsafe, len, "gcry: static roots collapsed to ")
          len = RawOut.append_u64(buf.to_unsafe, len, bytes)
          len = RawOut.append(buf.to_unsafe, len, " bytes from ")
          len = RawOut.append_u64(buf.to_unsafe, len, @static_scanned_max)
          len = RawOut.append(buf.to_unsafe, len, " — globals are not roots this collection. collection ")
          len = RawOut.append_u64(buf.to_unsafe, len, @collections)
          len = RawOut.append(buf.to_unsafe, len, "\n")
          RawOut.flush(buf.to_unsafe, len)
        end
      end
      @static_scanned_max = bytes if bytes > @static_scanned_max
    end

    getter static_scanned_drops : UInt64 = 0_u64

    protected def note_release_base(base : UInt64, kind : UInt8 = 0_u8) : Nil
      release_map_boot
      i = release_map_slot(base)
      if @rel_live[i] && @rel_base[i] == base
        @release_double &+= 1
        if @release_double == 1
          buf = uninitialized UInt8[256]
          len = 0
          len = RawOut.append(buf.to_unsafe, len,
            "gcry: released base 0x")
          len = RawOut.append_hex(buf.to_unsafe, len, base)
          len = RawOut.append(buf.to_unsafe, len,
            " a second time with no remap in between — the second unmap takes a live chunk. collection ")
          len = RawOut.append_u64(buf.to_unsafe, len, @collections)
          len = RawOut.append(buf.to_unsafe, len, ", first kind ")
          len = RawOut.append_u64(buf.to_unsafe, len, @rel_kind[i].to_u64)
          len = RawOut.append(buf.to_unsafe, len, ", second kind ")
          len = RawOut.append_u64(buf.to_unsafe, len, kind.to_u64)
          len = RawOut.append(buf.to_unsafe, len, "\n")
          RawOut.flush(buf.to_unsafe, len)
        end
      end
      @rel_base[i] = base
      @rel_live[i] = true
      @rel_kind[i] = kind
    end

    # Is this base currently recorded as released? O(1), against
    # `guarded_release_at`'s linear walk of up to 8192 slots.
    #
    # The distinction is not academic. `update_heap_bounds_after_unmap` asked
    # the linear form **once per chunk**, on a walk the trimmer runs in a loop,
    # so turning the ledger on to observe a race slowed the thing being
    # observed past its own harness deadline: `large_cache_race` children went
    # from ~1 s to ~114 s and the gate read 20 of 20 "failures" that were all
    # timeouts. An instrument that changes the answer is not an instrument.
    protected def released_base_recorded?(base : UInt64) : Bool
      return false unless @rel_booted
      i = release_map_slot(base)
      @rel_live[i] && @rel_base[i] == base
    end

    # The kernel gave this base back, so the release recorded against it is
    # spent. Called from `map_chunk`.
    protected def note_map_base(base : UInt64) : Nil
      release_map_boot
      i = release_map_slot(base)
      if @rel_live[i] && @rel_base[i] == base
        @rel_live[i] = false
        @release_remapped &+= 1
      end
    end

    # Returns true when the region was guarded (caller must not munmap it).
    # The first user word of a large chunk: past the chunk header and the block
    # header. Read before anything releases the range.
    private def guard_user_tag(base : UInt64, len : UInt64, kind : UInt8) : UInt64
      return 0_u64 unless kind == GUARD_KIND_LARGE
      off = ChunkHeader::SIZE.to_u64 &+ BlockHeader::SIZE.to_u64
      return 0_u64 if len <= off &+ 8
      Pointer(UInt64).new(base &+ off).value
    end

    protected def guard_release(base : UInt64, len : UInt64, kind : UInt8) : Bool
      ThreadListWatch.check(base, len, ThreadListWatch::SITE_RELEASE)
      note_release_base(base, kind) if @release_ledger || @unmap_guard
      unless @unmap_guard
        return false unless @release_ledger
        # Ring, not a bounded list: a ledger that fills up stops recording the
        # recent releases, which are the ones a fault is about.
        i = (@guard_ring.add(1_u64) % UNMAP_GUARD_SLOTS).to_i32
        @guard_base[i] = base
        @guard_kind[i] = kind
        @guard_gen[i] = @collections
        @guard_tag[i] = guard_user_tag(base, len, kind)
        # Length last, and that is the read protocol: `guarded_release_at`
        # tests `addr < base + len`, so a slot whose length is not in yet
        # matches nothing and a concurrent report skips it instead of naming a
        # half-written region.
        @guard_len[i] = len
        # False: the caller still unmaps. The record is the whole contribution.
        return false
      end
      # Claim, then check. One atomic read-modify-write instead of the read
      # that used to happen twice — the capacity test and the index have to be
      # the same value or two racing frees write slot `UNMAP_GUARD_SLOTS`.
      i = @guard_slot.add(1)
      if i >= UNMAP_GUARD_SLOTS
        # Park the counter at the capacity so a long run cannot wrap it, and
        # so `guard_slots_used` keeps reading the truth.
        @guard_slot.set(UNMAP_GUARD_SLOTS)
        @guard_overflows.add(1_u64)
        return false
      end
      # Read the identity *before* the mprotect. Reading it after faults on
      # every guarded release, because the range it reads is the one just made
      # PROT_NONE. Committed once as 46060bc and then lost to an over-broad
      # `git checkout <older> -- src/gcry/collect.cr` during an unrelated
      # backout; the crash it causes was chased for several rounds afterwards
      # and briefly read as a double free.
      tag = guard_user_tag(base, len, kind)
      # PROT_NONE drops the pages exactly as munmap would; what it keeps is the
      # mapping's identity, which is the whole point.
      if LibC.mprotect(Pointer(Void).new(base), LibC::SizeT.new(len), LibC::PROT_NONE) != 0
        # The slot is claimed and this release did not happen: leave it with a
        # zero length so the walk steps over it.
        @guard_len[i] = 0_u64
        return false
      end
      @guard_base[i] = base
      @guard_kind[i] = kind
      @guard_gen[i] = @collections
      @guard_tag[i] = tag
      @guard_len[i] = len
      true
    end

    # For the SIGSEGV report: which released region holds *addr*, if any.
    def guarded_release_at(addr : UInt64) : {UInt64, UInt64, UInt8, UInt64, UInt64}?
      limit = guard_slots_used
      i = 0
      while i < limit
        base = @guard_base[i]
        if addr >= base && addr < base + @guard_len[i]
          return {base, @guard_len[i], @guard_kind[i], @guard_gen[i], @guard_tag[i]}
        end
        i += 1
      end
      nil
    end

    # The same question the SIGSEGV report asks of a fault address, asked of a
    # pointer the allocator has just refused to own.
    #
    # "not a live gcry allocation" is a symptom — it says the chunk left the
    # index, never which release path took it or when. On 2026-08-29 that
    # message was the only thing a default-arm `dormant_flush_race` worker left
    # behind before it died, and it named nothing. Empty when neither the guard
    # nor the ledger is armed, so this costs a refused pointer one nil check.
    def release_note(addr : UInt64) : String
      if g = guarded_release_at(addr)
        base, glen, kind, gen, tag = g
        path = kind == GUARD_KIND_LARGE ? "large-object release" : "empty size-class chunk release"
        note = " — the chunk was RELEASED: base 0x#{base.to_s(16)}, #{glen} bytes, #{path}, " \
               "at collection #{gen} (#{@collections - gen} since); the pointer is " \
               "#{addr - base} bytes into it"
        note += ", first user word at release 0x#{tag.to_s(16)}" unless tag == 0
        return note
      end

      # No release on record — and with the guard armed there is no release
      # path that does not pass through `guard_release`, so the refusal has to
      # be explained by where the chunk went instead. Off the list *and* out of
      # the index *and* not yet released is one specific state and it has one
      # owner: a chunk a mutator detached in `trim_large_cache` and queued for
      # the collector, which is off both structures and still mapped until
      # `flush_pending_large_release` runs. Asking the queue directly is the
      # difference between naming that window and inferring it.
      listed = Pointer(ChunkHeader).null
      each_chunk do |chunk|
        lo = ChunkHeader.data_start(chunk).address
        hi = ChunkHeader.data_end(chunk).address
        listed = chunk if addr >= lo && addr < hi
      end
      " — no release on record; bounds [0x#{@heap_min.to_s(16)}, 0x#{@heap_max.to_s(16)}), " \
      "span [0x#{@heap_span_lo.to_s(16)}, 0x#{@heap_span_hi.to_s(16)}), " \
      "#{@chunk_index_count} indexed chunks; in bounds: " \
      "#{addr >= @heap_min && addr < @heap_max}; on @chunks: " \
      "#{listed.null? ? "no" : "yes, base 0x#{listed.address.to_s(16)}"}; " \
      "second lookup: #{chunk_containing(addr).nil? ? "still nil" : "found"}" \
      "#{large_chain_note(addr)}"
    end

    # Is *addr* inside a large chunk that is detached and waiting, either on the
    # collector's release queue or in a large-cache bucket? Both chains are
    # linked through the blocks' own `next_free`, both are only mutated under
    # `@alloc_lock`, and this walks them without it — a bounded, read-only walk
    # in a process that is already raising. Every chunk on either chain is still
    # mapped by construction, so the header reads are safe where a read of a
    # released range would fault.
    private def large_chain_note(addr : UInt64) : String
      if base = large_chain_hit(@pending_large_release, addr)
        return "; the chunk is on the collector's release queue, detached and " \
               "not yet unmapped — base 0x#{base.to_s(16)}, " \
               "#{@pending_large_release_bytes} bytes queued in total"
      end
      b = 0
      while b < LARGE_FREE_BUCKETS
        if base = large_chain_hit(@large_freelists[b], addr)
          return "; the chunk is in large-cache bucket #{b} — base 0x#{base.to_s(16)}"
        end
        b += 1
      end
      "; on neither the release queue nor a large-cache bucket"
    end

    private def large_chain_hit(chain : Void*, addr : UInt64) : UInt64?
      user = chain
      steps = 0
      while user && steps < 1_000_000
        header = BlockHeader.large_header_from_user(user)
        chunk = (header.as(UInt8*) - ChunkHeader::SIZE).as(ChunkHeader*)
        base = chunk.as(Void*).address
        return base if addr >= base && addr < base &+ chunk.value.mapped_bytes
        user = header.value.next_free
        steps += 1
      end
      nil
    end

    # Research only: the pre-2026-08-22 last-chunk cache — the index read twice,
    # no containment check, and the unsynchronised invalidation that made the
    # second read see `-1`.
    property index_cache_unchecked : Bool = false

    # EC1 post-STW sweep/flush: block SYSMON map_chunk while `@chunks` is rebuilt
    # and empties are queued for munmap (same cooperative spin as STW).
    @block_other_heap = false
    # Serializes collect vs fiber context swap (ExecutionContext takes read lock).
    @gc_lock = Crystal::RWLock.new
    @heap_min : UInt64 = UInt64::MAX
    @heap_max : UInt64 = 0_u64
    # Monotonic span of every address ever mapped — never shrinks on munmap.
    # Used by GC.realloc/free to refuse LibC fallback after empty-chunk release
    # tightened @heap_min/@heap_max around a dangling pointer.
    # Public for `SegvReport`: a crash handler has to be able to say whether the
    # faulting address was ever in this heap's span at all.
    getter heap_span_lo : UInt64 = UInt64::MAX
    getter heap_span_hi : UInt64 = 0_u64
    @minor_only = false # mark filter during minor GC
    # Fully free size-class chunks queued in STW; munmap outside (like large trim).
    @pending_empty_chunks : ChunkHeader* = Pointer(ChunkHeader).null
    # Large chunks a *mutator* detached in `trim_large_cache`: off `@chunks` and
    # out of the index, but still mapped. Only the collector thread releases
    # them, in `flush_pending_large_release`, because it is also the thread that
    # walks `@chunks` after `start_world` — chained through `next_free` so the
    # chunks' `next` stays intact for a walk already in flight.
    @pending_large_release : Void* = Pointer(Void).null
    @pending_large_release_bytes : UInt64 = 0_u64
    # Large chunks the in-STW sweep decided to recycle. Inserting into
    # `@large_freelists` needs `@alloc_lock`-quiescence the pause cannot have
    # (a suspended mutator may be frozen mid-cache/mid-take under that lock),
    # so the sweep queues them here — linked through their own headers'
    # `next_free`, the `@pending_large_release` pattern — and
    # `flush_pending_large_cache` inserts them under the lock after
    # `start_world`.
    @pending_large_cache : Void* = Pointer(Void).null
    # True while one of the post-STW `flush_pending_*` passes is walking
    # `@chunks`. Set and cleared under `@alloc_lock`, which is what makes it
    # useful: a mutator holding the lock and seeing it false knows no walk can
    # start before it lets go, so it can unmap on the spot. Seeing it true, it
    # queues instead. The walk itself still takes no lock, so allocation is not
    # stalled across its syscalls.
    @live_chunk_walk = false
    # Instruments for `bench/dormant_flush_race.cr`: how many walks ran, and
    # how many mutator trims the flag actually diverted into the queue.
    getter live_walk_spans : UInt64 = 0_u64
    getter live_walk_queued : UInt64 = 0_u64
    getter live_walk_direct : UInt64 = 0_u64
    # Set during STW when sweep will run after start_world (see sweep_after_world?).
    @lazy_sweep_pending = false
    getter? soft_dirty_armed : Bool = false
    @soft_dirty_probed = false
    @soft_dirty_works = false
    # Skip dirty-page scan when dirty/total pages exceed this percent (0 = never use).
    property soft_dirty_max_pct : Int32 = 25
    getter soft_dirty_page_scans : UInt64 = 0_u64
    getter soft_dirty_fallbacks : UInt64 = 0_u64
    # Last minor: dirty and total heap pages seen by the fraction check (0 if unused).
    getter last_soft_dirty_pages : UInt64 = 0_u64
    getter last_soft_dirty_total : UInt64 = 0_u64
    # After a high-dirty fallback, skip soft-dirty until the next major.
    @soft_dirty_skip_until_major = false

    def enable : Nil
      @enabled = true
    end

    def disable : Nil
      @enabled = false
    end

    def add_root(pointer : Void*) : Nil
      # World-stopped collector thread may mutate without the lock (single-threaded
      # STW). Otherwise serialize against stop_world acquiring @roots_lock first.
      if @world_stopped
        @roots.add(pointer)
      else
        @roots_lock.sync { @roots.add(pointer) }
      end
    end

    def delete_root(pointer : Void*) : Bool
      if @world_stopped
        @roots.delete(pointer)
      else
        @roots_lock.sync { @roots.delete(pointer) }
      end
    end

    # Walk the explicit root set **without** `@roots_lock`. For the crash
    # reporter only (`Gcry::PoisonHolders`): a signal handler cannot take that
    # lock, because the thread it interrupted may be the one holding it, and a
    # crash report that deadlocks is worse than one that reads a half-linked
    # node. Best effort by construction, like every other read `SegvReport` does.
    def unsafe_each_root(& : Void* ->) : Nil
      @roots.each { |pointer| yield pointer }
    end

    def set_stackbottom(stack_bottom : Void*) : Nil
      @stack_bottom = stack_bottom
    end

    def stack_bottom : Void*
      @stack_bottom
    end

    # Used when constructing a thread's main Fiber. Must return *this* OS
    # thread's stack high address — a single global `@stack_bottom` is wrong
    # for the Monitor (SYSMON) thread and makes other-thread scans no-ops.
    def current_thread_stack_bottom : {Void*, Void*}
      if bounds = Platform.current_pthread_stack_bounds
        return {Pointer(Void).null, bounds[1]}
      end
      {Pointer(Void).null, @stack_bottom}
    end

    def before_collect(&block : -> Nil) : Nil
      @before_collect_callbacks << block
    end

    def add_finalizer(object : Void*, callback : Finalizers::Callback) : Nil
      return if object.null?
      header = BlockHeader.from_user(object)
      BlockHeader.set_finalizer(header)
      @finalizers.add(object, callback)
      Trace.finalizer("register", object)
    end

    def add_finalizer(object : Void*, &block : Finalizers::Callback) : Nil
      add_finalizer(object, block)
    end

    def finalizer_entry_count : Int32
      @finalizers.entry_count
    end

    def finalizer_link_count : Int32
      @finalizers.link_count
    end

    # Research/spec only: make the registration index give up its table, the
    # way a refused `malloc` inside `index_grow` does. The fallback it leaves
    # behind is load-bearing — `notice_reclaim` has to scan instead — and it
    # cannot be reached from a spec any other way.
    def debug_finalizer_index_give_up : Nil
      @finalizers.debug_index_give_up
    end

    def debug_finalizer_index_cap : Int32
      @finalizers.index_cap
    end

    def register_disappearing_link(link : Void**, object : Void* = Pointer(Void).null) : Nil
      referent = object
      if referent.null?
        referent = link.value
      end
      return if referent.null?

      if (found = find_object_with_chunk(referent))
        header, chunk = found
        # The chunk-aware user pointer: `user_from` is identity under headerless
        # and would hand back a large object's header slot as its referent.
        referent = user_of(chunk, header)
        BlockHeader.set_disappearing(header)
      end
      @finalizers.register_disappearing_link(link, referent)
    end

    def live?(pointer : Void*) : Bool
      return false if pointer.null?
      found = find_object_with_chunk(pointer)
      return false unless found
      header, chunk = found
      # `find_object` already required occupancy; this re-asks the same
      # authority rather than the header flag, which is stale on a bitmap chunk
      # and absent under headerless.
      block_allocated?(chunk, header)
    end

    # ExecutionContext Monitor must not run process STW — it would signal-suspend
    # the mutator and re-introduce GCRY_STRESS resume deadlocks.
    # Compare via `@name` ivar (no String alloc); Thread.current? for early boot.
    private def monitor_thread? : Bool
      thread = Thread.current?
      return false unless thread
      name = thread.@name
      !name.nil? && name == "SYSMON"
    end

    # Parallel worker bootstrap: `Thread#start` → `Fiber::new` → malloc before
    # `@current_fiber` is installed. Collecting on that thread raises
    # `Thread#current_fiber cannot be nil` inside Crystal's raise path
    # (Kemal EC4 + low GCRY_THRESHOLD: END_OF_STACK at boot).
    private def thread_not_ready_for_collect? : Bool
      thread = Thread.current?
      return true unless thread
      thread.@current_fiber.nil?
    end

    # Full major collection (resets any in-progress incremental cycle).
    # `coalesce`: if true and a peer collect already cleared the debt while we
    # waited on the post-STW mutex, skip (Parallel EC alloc storms).
    def collect(scan_stack : Bool = true, roots : Array(Void*)? = nil, *, coalesce : Bool = false) : Nil
      return if @destroyed
      return if @collecting
      return if monitor_thread?
      return if thread_not_ready_for_collect?

      # Snapshot the mutator's callee-saved registers before any collector frame
      # can save them into its own (src/gcry/birth_grace.cr). Armed knob only.
      note_collect_entry_regs if @birth_grace
      abort_incremental
      Trace.collect_start(major: true)
      run_collection(major: true, scan_stack: scan_stack, roots: roots, coalesce: coalesce)
      Trace.collect_end(self, major: true)
      Invariant.after_collect(self)
    end

    # Young-generation collection. Scans roots + old objects for nursery pointers
    # (no compiler write barrier required).
    def minor_collect(scan_stack : Bool = true, roots : Array(Void*)? = nil, *, coalesce : Bool = false) : Nil
      return if @destroyed
      return if @collecting
      return if monitor_thread?
      return if thread_not_ready_for_collect?
      return unless @nursery_enabled

      abort_incremental
      Trace.collect_start(major: false)
      run_collection(major: false, scan_stack: scan_stack, roots: roots, coalesce: coalesce)
      Trace.collect_end(self, major: false)
    end

    # Incremental major mark slice (Boehm-style collect_a_little).
    # With a page-dirty barrier, termination re-scans dirty pages so stores into
    # already-scanned objects are not missed (sounder than plain SATB without barriers).
    # Returns true when a full cycle (mark+sweep) has completed.
    def collect_a_little(work_units : Int32 = DEFAULT_INCREMENTAL_WORK) : Bool
      return false if @destroyed
      return false if @collecting
      return false if @running_finalizers
      return false if monitor_thread?
      return false if thread_not_ready_for_collect?

      started = monotonic_ns
      unless @inc_active
        begin_incremental(scan_stack: true, roots: nil)
      end

      # If begin_incremental couldn't arm a barrier, inc_active stays false
      # and we bail out so the alloc path falls through to a full STW collect.
      return false unless @inc_active

      lock_post_stw
      finished = false
      begin
        @collecting = true
        @incremental_marking = true
        begin
          lock_write
          stop_world_quiescing_roots
          # This slice is the third place a bitmap chunk gets swept — the
          # `sweep(major: true)` below runs inside this same stopped world —
          # so the two in-flight roots have to be offered here as well, or a
          # mutator frozen between its `occ` store and the caller receiving
          # the pointer has its block reclaimed under it. Cheap: one pointer
          # and 96 static-array loads.
          mark_large_alloc_in_flight
          mark_bitmap_alloc_in_flight
          mark_loop_budget(work_units)
          if @mark_stack.empty?
            # Sound termination: rematerialize edges from dirty pages, then continue.
            if scan_dirty_pages_for_pointers(nursery_only: false)
              mark_loop_budget(work_units)
            end
          end
          if @mark_stack.empty?
            enqueue_unreachable_finalizers
            sweep(major: true)
            @bytes_since_gc.set(0_u64)
            @nursery_alloc_bytes.set(0_u64)
            @expl_freed_bytes_since_gc = 0_u64
            @collections += 1
            @major_collections += 1
            if (@major_collections % STATIC_ROOT_REFRESH_INTERVAL) == 0
              Platform.invalidate_static_root_cache
            end
            @soft_dirty_skip_until_major = false
            @inc_active = false
            @incremental_marking = false
            finished = true
            arm_page_barrier_after_collect if @nursery_enabled || @incremental_auto
          end
        ensure
          start_world
          unlock_write
          unless @inc_active
            @mark_stack.clear
            @incremental_marking = false
          end
          record_pause(started)
        end

        if finished
          @suppress_collect.add(1)
          begin
            flush_pending_empty_chunks
            flush_pending_large_cache
            flush_pending_large_release
            trim_large_cache(defer: false)
          ensure
            @suppress_collect.sub(1)
          end
        end
        @collecting = false
      ensure
        # Ensure flag clears even if flush raised.
        @collecting = false
        unlock_post_stw
      end

      if finished
        @running_finalizers = true
        begin
          @finalizers.run_pending
        ensure
          @running_finalizers = false
        end
      end
      finished
    end

    def reset_pause_stats : Nil
      @last_pause_ns = 0_u64
      @max_pause_ns = 0_u64
      @total_pause_ns = 0_u64
      @pause_count = 0_u64
      @pause_ring_len = 0
      @pause_ring_pos = 0
      PAUSE_RING_SIZE.times { |i| @pause_ring[i] = 0_u64 }
      PAUSE_HDR_BUCKETS.times { |i| @pause_hdr[i] = 0_u64 }
    end

    # Approximate percentile over the last up to PAUSE_RING_SIZE pauses (ns).
    # Safe to call outside collect (sorts a stack copy). Returns 0 if no samples.
    def pause_percentile_ns(pct : Float64) : UInt64
      n = @pause_ring_len
      return 0_u64 if n <= 0

      tmp = StaticArray(UInt64, PAUSE_RING_SIZE).new(0_u64)
      n.times { |i| tmp[i] = @pause_ring[i] }

      # Insertion sort — n ≤ 64, allocation-free.
      (1...n).each do |i|
        key = tmp[i]
        j = i - 1
        while j >= 0 && tmp[j] > key
          tmp[j + 1] = tmp[j]
          j -= 1
        end
        tmp[j + 1] = key
      end

      # Nearest-rank: index = ceil(pct/100 * n) - 1
      rank = ((pct / 100.0) * n).ceil.to_i32 - 1
      rank = 0 if rank < 0
      rank = n - 1 if rank >= n
      tmp[rank]
    end

    def note_explicit_free(payload : UInt64) : Nil
      @expl_freed_bytes_since_gc += payload
    end

    # Block header for an address in a managed chunk, including FREE blocks.
    # Prefer find_object for mutator-facing queries (rejects FREE).
    # What this heap knows about an arbitrary address, for a crash handler. Reads
    # a handful of words and reports what they said — the heap may be
    # mid-mutation, which is usually why anyone is asking.
    def debug_block_info(pointer : Void*)
      header = find_block(pointer)
      unless header
        return {found: false, free: false, size: 0_u32, flags: 0_u32,
                first_word: 0_u64, offset: 0_u64}
      end
      user = diag_user(header)
      addr = pointer.address
      offset = addr >= user.address ? addr - user.address : 0_u64
      first = diag_payload(header) >= 8 ? user.as(UInt64*).value : 0_u64
      {found:      true,
       free:       !diag_allocated?(header),
       size:       diag_payload(header),
       flags:      diag_flags(header),
       first_word: first,
       offset:     offset}
    end

    # `find_block` plus the chunk it resolved through.
    #
    # The mark path needs both: the chunk is what indexes the mark bitmap, and
    # re-deriving it with a second `chunk_containing` per candidate is the cost
    # that took a 2026-08-01 experiment to 56.3% of Boehm. `find_block` is a
    # thin wrapper so every existing caller is unaffected.
    def find_block_with_chunk(pointer : Void*) : {BlockHeader*, ChunkHeader*}?
      return nil if pointer.null?
      addr = pointer.address
      return nil if @heap_max == 0 || addr < @heap_min || addr >= @heap_max

      chunk = chunk_containing(addr)
      return nil unless chunk

      if ChunkHeader.large?(chunk)
        header = ChunkHeader.large_header(chunk)
        user = ChunkHeader.large_user(chunk).address
        finish = user + header.value.size
        # Accept the header slot too: interior scans and `find_object` hand back
        # the header, and under headerless it sits outside [user, finish).
        return {header, chunk} if addr >= header.address && addr < finish
        return nil
      end

      class_index = chunk.value.size_class.to_i32
      return nil if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      block_bytes = @block_bytes[class_index]
      # Not `chunk.address + ChunkHeader::SIZE`: a size-class chunk's blocks
      # start after its bitmaps, and `owns_user_pointer?` (heap.cr) derives the
      # same address the same way. If these two ever disagree, a valid pointer
      # starts reporting "not a gcry allocation" through GC.free/realloc — see
      # the spec that pins them together.
      data_start = ChunkHeader.data_start(chunk).address
      return nil if addr < data_start

      offset = addr - data_start
      header_addr = data_start + Heap.block_ordinal(offset, @block_magic[class_index]) * block_bytes
      return nil if header_addr + block_bytes > chunk.address + chunk.value.mapped_bytes

      {Pointer(BlockHeader).new(header_addr), chunk}
    end

    # Kept as the shape every existing caller expects. The division it used to
    # carry — `offset // block_bytes`, once per accepted candidate word, the
    # single most expensive arithmetic op on the mark hot path — is now a magic
    # reciprocal inside `find_block_with_chunk`.
    def find_block(pointer : Void*) : BlockHeader*?
      found = find_block_with_chunk(pointer)
      return nil unless found
      found[0]
    end

    def find_object(pointer : Void*) : BlockHeader*?
      found = find_object_with_chunk(pointer)
      return nil unless found
      found[0]
    end

    # Same, keeping the chunk `find_block_with_chunk` already resolved. Callers
    # that go on to push onto the mark stack need it (Phase 7.6) and would
    # otherwise re-resolve it.
    def find_object_with_chunk(pointer : Void*) : {BlockHeader*, ChunkHeader*}?
      found = find_block_with_chunk(pointer)
      return nil unless found
      header, chunk = found
      # `block_allocated?`, not `BlockHeader.free?`: on a bitmap chunk the
      # header's FREE flag is stale for every block the streaming sweep
      # reclaimed, and trusting it here resurrects reclaimed blocks into `occ`.
      return nil unless block_allocated?(chunk, header)
      {header, chunk}
    end

    protected def maybe_collect : Nil
      return unless @enabled
      return if @collecting
      return if @running_finalizers
      return if @suppress_collect.get > 0
      return if monitor_thread?
      return if thread_not_ready_for_collect?

      @alloc_ops &+= 1
      if @stress_every > 0 && (@alloc_ops % @stress_every.to_u64) == 0
        collect(coalesce: true)
        return
      end

      if @nursery_enabled && @nursery_alloc_bytes.get >= @nursery_threshold
        minor_collect(coalesce: true)
        return
      end

      # Keep draining an in-progress incremental cycle even if under threshold.
      if @inc_active
        collect_a_little(@incremental_work)
        return
      end

      # Early incremental kick-in (BEFORE the hard threshold): when we cross
      # 75% of `gc_threshold`, start the incremental cycle right away so by
      # the time `bytes_since_gc` actually reaches `gc_threshold` the mark
      # phase has had dozens of allocations to drain. This keeps the final
      # STW slice (sweep) short even at high allocation pressure.
      # Guarded by `bytes_since_gc >= gc_threshold / 4` so an idle path that
      # just happened to cross 75% doesn't repeatedly enter a barely-empty
      # incremental cycle.
      bsg = @bytes_since_gc.get
      if @incremental_auto &&
         bsg >= (@gc_threshold >> 2) &&
         bsg >= (@gc_threshold - (@gc_threshold >> 2))
        collect_a_little(@incremental_work)
        return
      end

      return if bsg < @gc_threshold

      # Threshold crossed: try incremental one more time. If the cycle
      # finishes here we skip STW entirely; otherwise only the final sweep
      # lands inside STW.
      if @incremental_auto && collect_a_little(@incremental_work)
        return
      end

      collect(coalesce: true)
    end

    protected def destroy_collector : Nil
      flush_pending_empty_chunks
      flush_pending_large_cache
      flush_pending_large_release
      during_live_chunk_walk do
        flush_pending_dormant_chunks
        flush_pending_page_release_chunks
      end
      abort_incremental
      @roots_lock.sync { @roots.clear }
      @mark_stack.destroy
      @finalizers.clear
      @before_collect_callbacks.clear
      @heap_min = UInt64::MAX
      @heap_max = 0_u64
      @heap_span_lo = UInt64::MAX
      @heap_span_hi = 0_u64
      @collections = 0_u64
      @minor_collections = 0_u64
      @major_collections = 0_u64
      @stack_bottom = Pointer(Void).null
      @nursery_alloc_bytes.set(0_u64)
      @bytes_since_gc.set(0_u64)
      @unmapped_bytes = 0_u64
      @bytes_before_gc = 0_u64
      @bytes_reclaimed_since_gc = 0_u64
      @reclaimed_bytes_before_gc = 0_u64
      @expl_freed_bytes_since_gc = 0_u64
      @size_class_chunk_count = 0_u64
      @fully_free_chunk_bytes = 0_u64
      @released_chunk_bytes = 0_u64
      @size_class_live_bytes = 0_u64
      @chunk_fill_lt25 = 0_u64
      @chunk_fill_lt50 = 0_u64
      @chunk_fill_lt75 = 0_u64
      @chunk_fill_ge75 = 0_u64
      @soft_dirty_armed = false
      @soft_dirty_probed = false
      @soft_dirty_works = false
      @soft_dirty_page_scans = 0_u64
      @soft_dirty_fallbacks = 0_u64
      @last_soft_dirty_pages = 0_u64
      @last_soft_dirty_total = 0_u64
      @soft_dirty_skip_until_major = false
      disarm_mprotect_barrier if @barrier_backend.mprotect?
      @barrier_backend = Platform::BarrierBackend::None
      @barrier_dirty_rescans = 0_u64
      @barrier_full_fallbacks = 0_u64
      destroy_blacklist
      reset_pause_stats
    end

    protected def note_mapped(chunk : ChunkHeader*) : Nil
      base = chunk.address
      finish = base + chunk.value.mapped_bytes
      # Under `@index_lock`, because `update_heap_bounds_after_unmap` reads the
      # index and assigns these under it: without the lock this widen can land
      # between that read and its store and be lost, which shuts a live chunk
      # out of the heap bounds.
      @index_lock.sync do
        @heap_min = base if base < @heap_min
        @heap_max = finish if finish > @heap_max
        @heap_span_lo = base if base < @heap_span_lo
        @heap_span_hi = finish if finish > @heap_span_hi
      end
    end

    # Record nursery survival from the just-completed minor collection. Updates
    # the ring buffer and the cached survival-rate. Also adjusts the nursery
    # threshold via the adaptive-nursery policy when @adaptive_nursery is true.
    private def note_nursery_survival : Nil
      before = @nursery_alloc_before_minor
      survived = @nursery_survival_bytes
      return if before == 0 && survived == 0

      pos = @nursery_history_pos
      @nursery_alloc_history[pos] = before
      @nursery_survival_history[pos] = survived
      @nursery_history_pos = (pos + 1) % NURSERY_SURVIVAL_HISTORY
      @nursery_history_count += 1 if @nursery_history_count < NURSERY_SURVIVAL_HISTORY

      # Compute average survival rate across recorded history.
      total_alloc = 0_u64
      total_survived = 0_u64
      count = @nursery_history_count
      NURSERY_SURVIVAL_HISTORY.times do |i|
        next if i >= count
        total_alloc += @nursery_alloc_history[i]
        total_survived += @nursery_survival_history[i]
      end
      @nursery_survival_rate_pct = if total_alloc > 0 && total_survived <= total_alloc
                                     (total_survived * 100_u64) // total_alloc
                                   elsif total_survived > total_alloc
                                     100_u64
                                   else
                                     0_u64
                                   end

      # Adaptive threshold adjustment: tune the nursery threshold so the
      # survival rate stays near TARGET_SURVIVAL_PCT (50%).
      adjust_nursery_threshold if @adaptive_nursery && count > 0
    end

    # Adjust nursery_threshold based on the moving-average survival rate.
    # - Survival > target: the nursery is too small → grow threshold.
    # - Survival < target: the nursery is too large / too much survives → shrink.
    # Clamped to [MIN_ADAPTIVE_NURSERY_THRESHOLD, MAX_ADAPTIVE_NURSERY_THRESHOLD].
    # Always respects an explicit (non-default) GCRY_NURSERY threshold unless
    # adaptive is explicitly enabled.
    private def adjust_nursery_threshold : Nil
      thr = @nursery_threshold
      return if thr == UInt64::MAX || thr == 0
      rate = @nursery_survival_rate_pct
      if rate > TARGET_SURVIVAL_PCT
        # Survival above target: grow threshold by 25%
        thr = thr + (thr >> 2)
      elsif rate < TARGET_SURVIVAL_PCT / 2
        # Survival well below target (25%): shrink threshold by 25%
        thr = thr - (thr >> 2)
      end
      # Clamp
      thr = MIN_ADAPTIVE_NURSERY_THRESHOLD if thr < MIN_ADAPTIVE_NURSERY_THRESHOLD
      thr = MAX_ADAPTIVE_NURSERY_THRESHOLD if thr > MAX_ADAPTIVE_NURSERY_THRESHOLD
      @nursery_threshold = thr
    end

    protected def update_heap_bounds_after_unmap : Nil
      @last_chunk_idx = -1
      @last_chunk_lo = 0_u64
      @last_chunk_hi = 0_u64

      # Read the bounds off the **chunk index**, not by walking `@chunks`.
      #
      # The walk was the defect. `unlink_chunk` removes a chunk from the index
      # before anything unmaps it, but the `@chunks` list is mutated under two
      # different locks — `unlink_chunk` under `@alloc_lock`, and `map_chunk`
      # from `refill_size_class` under the size-class freelist lock — so a
      # prepend racing an unlink can leave a removed chunk reachable through
      # `next`. This walk then dereferenced it after `munmap`:
      #
      #   Gcry::Heap#update_heap_bounds_after_unmap
      #   Gcry::Heap#trim_large_cache<UInt64>
      #   ~procProc(Thread, Nil)
      #
      # faulting on the chunk's own base — `ChunkHeader.next`, offset 0 — with
      # the report saying "in a range gcry RELEASED and unmapped ... at
      # collection 0", i.e. the explicit free path, no collection involved.
      # (`bench/log/linux/2026-08-25-aarch64-large-cache-locked-arm`.)
      #
      # The index answers the same question without following a pointer the
      # other thread may have freed: it is a flat array, sorted by base, of
      # chunks that are by construction still mapped, and it is guarded by one
      # lock that nothing takes `@alloc_lock` inside. Chunks do not overlap, so
      # the lowest base is the first entry and the highest end is the last —
      # O(1) instead of O(chunks), and no `next` chain at all.
      #
      # A chunk mapped while this runs is safe either way: `map_chunk` inserts
      # into the index before `note_mapped` publishes its bounds, so either it
      # is in the array this reads, or its own publication lands after the
      # store below and survives.
      # Read *and* store under the one lock. Reading the index and then storing
      # outside it leaves the same window the old walk had: `note_mapped`
      # widens the bounds for a chunk mapped in between, and the store
      # overwrites it — a chunk outside `[@heap_min, @heap_max)` is one
      # `find_block` answers `nil` for, so its objects are swept while live.
      # `note_mapped` takes the same lock for the same four fields.
      lo = UInt64::MAX
      hi = 0_u64
      @index_lock.sync do
        count = @chunk_index_count
        if count > 0
          first = (@chunk_index + 0).value
          last = (@chunk_index + (count - 1)).value
          lo = first.address
          hi = last.address &+ last.value.mapped_bytes
        end
        @heap_min = lo
        @heap_max = hi
      end
    end

    private def init_post_stw_mutex : Nil
      # Fresh mutex (also used after fork — parent copy may be locked/undefined).
      LibC.pthread_mutex_init(pointerof(@post_stw_mutex), Pointer(LibC::PthreadMutexattrT).null)
    end

    private def lock_post_stw : Nil
      LibC.pthread_mutex_lock(pointerof(@post_stw_mutex))
    end

    private def try_lock_post_stw : Bool
      LibC.pthread_mutex_trylock(pointerof(@post_stw_mutex)) == 0
    end

    private def unlock_post_stw : Nil
      LibC.pthread_mutex_unlock(pointerof(@post_stw_mutex))
    end

    private def debt_under_threshold?(major : Bool) : Bool
      if major
        @bytes_since_gc.get < @gc_threshold
      else
        @nursery_alloc_bytes.get < @nursery_threshold
      end
    end

    private def note_post_stw_wait(wait_ns : UInt64) : Nil
      @last_phase_post_stw_wait_ns = wait_ns
      @post_stw_wait_total_ns += wait_ns
      @post_stw_wait_count += 1
      @max_post_stw_wait_ns = wait_ns if wait_ns > @max_post_stw_wait_ns
    end

    # Acquire post-STW mutex. When *coalesce*, never sleep on the mutex: the
    # `@collecting=false`→`unlock` window lets every EC worker enter
    # `run_collection` and pile up (~11s wait / 20s wrk). Failed trylock →
    # skip; next `maybe_collect` retries after the holder finishes. Returns
    # false if skipped without holding the lock.
    private def acquire_post_stw(coalesce : Bool, cols_before : UInt64, major : Bool) : Bool
      t_wait = monotonic_ns
      if coalesce
        unless try_lock_post_stw
          @collect_coalesced += 1
          note_post_stw_wait(monotonic_ns - t_wait)
          return false
        end
      else
        lock_post_stw
      end
      note_post_stw_wait(monotonic_ns - t_wait)
      true
    end

    # The mutator's stack pointer as the collector was entered. Everything below
    # it is the collector's own frames — including, when `GCRY_BIRTH_GRACE` is
    # searching for who holds a block, that search's own parameters. An
    # instrument that scans the stack has to be able to exclude itself.
    getter collect_entry_sp : UInt64 = 0_u64

    # See `Heap#alloc_large`: the block a stopped mutator is mid-way through
    # allocating. Marked like any explicit root; `mark_impl` ignores it while
    # the header is still FREE (the cache path before `set_used_large`).
    private def mark_large_alloc_in_flight : Nil
      user = @large_alloc_in_flight
      return if user.null?
      mark_explicit_root(user)
    end

    # `GCRY_POST_MARK_SPIN`. Research control only; see the spin site.
    property post_mark_spin : UInt64 = 0_u64

    # Thin on purpose, and the body is never inlined into it: every frame a
    # collection pushes — the body's own large, heavily inlined frame included
    # — then lies *below* the SP captured here, where the scrubs can reach it.
    # With the body inlined, its frame sat above the captured SP, so the
    # previous cycle's mark batches survived there, were re-established at the
    # same address next cycle, and were scanned as mutator stack before this
    # cycle overwrote them. Measured: 40 stale stack seeds retaining a 44k
    # object web on gc_phases under `-Dgcry_headerless`.
    private def run_collection(major : Bool, scan_stack : Bool, roots : Array(Void*)?, coalesce : Bool = false) : Nil
      @collect_entry_sp = Roots.hardware_stack_pointer.address
      # Everything below the SP is dead here, and it is last cycle's collector
      # residue. Zero it before this cycle's scan chain overlays and scans it.
      collect_scrub
      run_collection_body(major, scan_stack, roots, coalesce)
      # The frames this cycle just used are dead below the SP again. Zero them
      # so nothing between now and the next entry scans them as live.
      collect_scrub
    end

    @[NoInline]
    private def run_collection_body(major : Bool, scan_stack : Bool, roots : Array(Void*)?, coalesce : Bool) : Nil
      cols_before = @collections
      # Hold post-STW mutex through flush so Parallel EC cannot stop_world
      # mid-munmap. Auto-collect: trylock or skip (no waiter pile-up).
      return unless acquire_post_stw(coalesce, cols_before, major)

      begin
        # World is running here: pthread_create asks libc for a stack, which is
        # exactly what must not happen once threads are frozen.
        StwWatchdog.ensure_started if @stop_the_world
        # Auto-collect coalescing: peer finished while we acquired — skip STW.
        if coalesce && @collections > cols_before && debt_under_threshold?(major)
          @collect_coalesced += 1
          return
        end

        # Pause timer starts after mutex wait so p50/p99 reflect STW work only.
        started = monotonic_ns
        @collecting = true
        # Generational mark skips old objects; old→young edges come from
        # scan_old_for_nursery_pointers (soft-dirty pages when armed, else full
        # old walk). Finalizers/WeakRef must not treat unmarked old as dead
        # (see unmarked_live_object?).
        @minor_only = !major
        begin
          # Start mark helpers before write-lock / STW (library heaps only; process
          # STW keeps the pool empty — Crystal threads would freeze with the world).
          ensure_mark_worker_pool if @parallel_mark_workers > 1

          # Block fiber swaps, then suspend other OS threads.
          # stop_world_quiescing_roots: no mutator frozen mid-add/delete_root.
          lock_write
          t0 = monotonic_ns
          stop_world_quiescing_roots
          @last_phase_stw_stop_ns = monotonic_ns - t0
          @thread_list_last_major = major
          ThreadListWatch.new_cycle
          probe_thread_list_header("the suspension")
          StwWatchdog.enter(StwWatchdog::PHASE_FLUSH)
          flush_all_tlabs
          probe_thread_list_header("the TLAB flush")
          # TLAB-off USED stash → freelist before mark (unscanned thread locals).
          flush_all_alloc_batches
          probe_thread_list_header("the alloc-batch flush")
          # USED-on-freelist can remain after mid-`tlab_alloc_small` STW; unlink
          # those nodes before mark/sweep (see scrub_freelists / unlink_freelist_range).
          scrub_freelists
          probe_thread_list_header("the freelist scrub")
          note_collection_begin
          StwWatchdog.enter(StwWatchdog::PHASE_CLEAR)
          @mark_stack.clear

          t0 = monotonic_ns
          if major
            clear_all_marks
          else
            clear_nursery_marks
          end
          @last_phase_clear_ns = monotonic_ns - t0
          StwWatchdog.enter(StwWatchdog::PHASE_ROOTS)

          t0 = monotonic_ns
          @before_collect_callbacks.each(&.call)
          # Explicit roots: no type_id_gate (must keep raw Pointer buffers for
          # realloc pin / add_root); still respect allow_interior_pointers.
          reset_mutator_seen
          @roots.each { |ptr| mark_explicit_root(ptr) }
          mark_large_alloc_in_flight
          mark_bitmap_alloc_in_flight
          roots.try &.each { |ptr| mark_explicit_root(ptr) }
          mark_metadata_roots
          # Fiber scrub timed separately (Parallel A/B); excluded from roots_ns.
          t_scrub = monotonic_ns
          scrub_parked_fiber_stacks if scan_stack
          scrub_ns = monotonic_ns - t_scrub
          @last_phase_scrub_ns = scrub_ns
          # Fiber objects + suspended stacks (once; not also via push_gc_roots).
          scan_all_fiber_roots if scan_stack
          # Research arms: stacks `Fiber.unsafe_each` does not yield
          # (src/gcry/unowned_stack_roots.cr). Off by default.
          scan_unowned_stacks if scan_stack
          scan_thread_roots if scan_stack && @stop_the_world
          @last_phase_roots_ns = monotonic_ns - t0 - scrub_ns
          StwWatchdog.enter(StwWatchdog::PHASE_STATIC)

          t0 = monotonic_ns
          if @scan_static_roots
            scanned = 0_u64
            Platform.scan_static_roots do |low, high|
              each_static_range_excluding_heap(low, high) do |a, b|
                scanned += b.address - a.address
                Roots.scan_range_chunked(a, b, safe: true) { |candidate| mark_root_candidate(candidate, source: RootSource::Static) }
              end
            end
            note_static_scanned(scanned)
          end
          @last_phase_static_ns = monotonic_ns - t0
          StwWatchdog.enter(StwWatchdog::PHASE_STACKS)
          if (stall = @stw_test_stall_ms) > 0
            ts = uninitialized LibC::Timespec
            ts.tv_sec = typeof(ts.tv_sec).new(stall // 1000)
            ts.tv_nsec = typeof(ts.tv_nsec).new((stall % 1000) * 1_000_000)
            rem = uninitialized LibC::Timespec
            LibC.nanosleep(pointerof(ts), pointerof(rem))
          end

          t0 = monotonic_ns
          if scan_stack
            scan_mutator_stack
            scan_other_thread_stacks
          end
          @last_phase_stacks_ns = monotonic_ns - t0
          StwWatchdog.enter(StwWatchdog::PHASE_MARK)

          # Conservatively find nursery pointers from old objects.
          # Official path: page-dirty remembered set (soft-dirty / mprotect).
          scan_old_for_nursery_pointers unless major

          t0 = monotonic_ns
          mark_loop
          # EXPERIMENT (GCRY_BIRTH_GRACE=1): *after* the mark, so a newborn block
          # that nothing reached is visible as such. Reports what it saved, then
          # marks it and drains again — the point is to name the block the
          # collector was about to take, not only to keep the process alive.
          if @birth_grace
            mark_birth_grace_roots
            mark_loop
          end
          @last_phase_mark_ns = monotonic_ns - t0
          probe_thread_list_header("the mark", expect_marked: true)
          StwWatchdog.enter(StwWatchdog::PHASE_FINALIZERS)

          # Claiming FREE mid-alloc blocks during mark can leave USED-on-freelist;
          # drop them before sweep / empty-chunk unlink.
          scrub_freelists
          probe_thread_list_header("the post-mark freelist scrub", expect_marked: true)

          # Finalizers / WeakRef: one index pass (no Proc — that mallocs mid-STW).
          enqueue_unreachable_finalizers

          # For minor collections, snapshot nursery alloc bytes and reset survival
          # counter before sweep accumulates surviving nursery payload.
          if !major
            @nursery_alloc_before_minor = @nursery_alloc_bytes.get
            @nursery_survival_bytes = 0_u64
          end

          reset_birth_grace if @birth_grace

          # `GCRY_POST_MARK_SPIN=<n>`: pure delay between mark and sweep, no
          # bookkeeping of any kind. The control the birth-grace arms needed:
          # every arm that walks a table here takes the crash rate to zero, and
          # every arm that does not leaves it at the control rate — including
          # one that roots a null pointer. If a bare spin does the same, the
          # grace was never keeping anything alive.
          if (n = @post_mark_spin) > 0
            i = 0_u64
            while i < n
              Intrinsics.pause
              i &+= 1
            end
          end

          # Mark completeness, in the only window where the answer exists: the
          # mark is final and nothing has been reclaimed yet (GCRY_MARK_AUDIT=1,
          # src/gcry/mark_audit.cr). Off by default — O(live heap) in the pause.
          # Sampled, because the full audit is O(live heap) *inside the pause*
          # and that is not a neutral instrument: with it on, the acikturkiye
          # crash stops happening (87,750 requests, 0 missed edges, no crash),
          # so its zero was only ever measured on runs that did not crash.
          # `GCRY_MARK_AUDIT_EVERY=N` runs it on one collection in N, which is
          # the only way its answer and that crash can be observed together.
          if @mark_audit && (@mark_audit_every <= 1_u64 || @collections % @mark_audit_every == 0)
            run_mark_audit
          end
          audit_chunk_index if @index_audit

          # The same window, one question narrower: is a block of the watched
          # type about to be swept, and if so what still holds its address?
          # (GCRY_THREAD_BLOCK_AUDIT=1, src/gcry/thread_block_audit.cr). Gated
          # separately from `mark_audit` on purpose — the arm has to run on CI
          # steps whose budget will not carry an O(live heap) walk per
          # collection as well.
          audit_dying_type_blocks(major) if @thread_block_audit

          # Lazy sweep (Parallel reclaim-off): end STW before reclaim so pause
          # excludes O(heap) phase_sweep; sweep runs under freelist locks.
          @lazy_sweep_pending = sweep_after_world?
          StwWatchdog.enter(StwWatchdog::PHASE_SWEEP)
          unless @lazy_sweep_pending
            t0 = monotonic_ns
            sweep(major: major, after_world: false)
            @last_phase_sweep_ns = monotonic_ns - t0
          end

          if major
            @bytes_since_gc.set(0_u64)
            @nursery_alloc_bytes.set(0_u64)
            @expl_freed_bytes_since_gc = 0_u64
            @major_collections += 1
            if (@major_collections % STATIC_ROOT_REFRESH_INTERVAL) == 0
              Platform.invalidate_static_root_cache
            end
            # Next minor starts a fresh soft-dirty window after a major.
            @soft_dirty_skip_until_major = false
            unless @lazy_sweep_pending
              arm_page_barrier_after_collect if @nursery_enabled || @incremental_auto
            end
          else
            @nursery_alloc_bytes.set(0_u64)
            @minor_collections += 1
            unless @lazy_sweep_pending
              # Record nursery survival statistics for adaptive threshold.
              note_nursery_survival
              arm_page_barrier_after_collect
            end
          end
          @collections += 1
        ensure
          t0 = monotonic_ns
          StwWatchdog.enter(StwWatchdog::PHASE_RESUME)
          start_world
          @last_phase_stw_start_ns = monotonic_ns - t0
          unlock_write
          @minor_only = false
          @mark_stack.clear
          record_pause(started)
        end

        # Keep @collecting true through post-STW flush so GCRY_STRESS / auto
        # collect cannot re-enter while we still hold the post-STW mutex (non-
        # recursive) or munmap mid-peer-collect.
        @suppress_collect.add(1)
        begin
          # EC1 lazy: pin stw_owner + block SYSMON while rebuilding `@chunks`
          # and munmapping empties (Parallel lazy does not relink / munmap).
          ec1_lazy = @lazy_sweep_pending && !multi_mutator_threads?
          if ec1_lazy
            @stw_owner = Thread.current if @stw_owner.nil?
            @block_other_heap = true
          end
          begin
            if @lazy_sweep_pending
              t0 = monotonic_ns
              # The lazy sweep walks `@chunks` with the mutators running, same
              # as the flush passes below — and it was the one that kept
              # `make dormant-flush-race` red after those were fixed.
              during_live_chunk_walk { sweep(major: major, after_world: true) }
              @last_phase_sweep_ns = monotonic_ns - t0
              @lazy_sweep_pending = false
              if major
                arm_page_barrier_after_collect if @nursery_enabled || @incremental_auto
              else
                note_nursery_survival
                arm_page_barrier_after_collect
              end
            end

            t_flush = monotonic_ns
            # Munmap outside STW — empty chunks + excess large freelist (reuse common).
            # Still under post-STW mutex so the next collect cannot stop_world here.
            flush_pending_empty_chunks
            # Anything held long enough goes back to the kernel here, on the
            # collector, outside the walks (`GCRY_RELEASE_QUARANTINE`).
            drain_release_quarantine
            # Mutator-detached large chunks: release before the walks below start.
            # In-STW-recycled large chunks into the cache first — under
            # `@alloc_lock`, which means something again now.
            flush_pending_large_cache
            flush_pending_large_release
            during_live_chunk_walk do
              # DORMANT madvise outside STW — kernel VM lock contention avoided.
              flush_pending_dormant_chunks
              # Partial-chunk free-page madvise outside STW (HOLED / Darwin all-chunk walk).
              flush_pending_page_release_chunks
              # Mostly-empty (SPARSE): MADV_FREE or bounded unlink+DONTNEED; no HOLED rebuild.
              flush_pending_mostly_empty_chunks
            end
            # Anything a mutator queued while the walks were running.
            flush_pending_large_release
            # Large freelist: Darwin MADV_FREE_REUSABLE; Linux MADV_FREE (content until reclaim).
            release_large_freelist_pages
            trim_large_cache(defer: false)
            @last_phase_flush_ns = monotonic_ns - t_flush
          ensure
            if ec1_lazy
              @block_other_heap = false
              @stw_owner = nil
            end
          end

          if major
            # Adaptive large-cache retain: grow when hit rate is high, shrink when low.
            # Resets counters each major so the policy tracks the current working set.
            total_large = @large_cache_hits + @large_cache_misses
            if total_large > 0
              hit_pct = (@large_cache_hits * 100) // total_large
              current = @large_cache_retain
              # current == 0 means cache disabled (Linux process default); do not
              # grow from zero — 0×2 would stay 0 anyway, but skip makes intent clear.
              if hit_pct > 50 && current > 0 && current < LARGE_CACHE_LIMIT
                # Good reuse: double retain (capped at limit).
                @large_cache_retain = {current * 2, LARGE_CACHE_LIMIT}.min
              elsif hit_pct < 10 && current > 1048576_u64 # 1 MiB floor
                # Poor reuse: halve retain (floor at 1 MiB).
                @large_cache_retain = {current >> 1, 1048576_u64}.max
              end
            end
            @large_cache_hits = 0_u64
            @large_cache_misses = 0_u64
          end
        ensure
          @suppress_collect.sub(1)
        end
      ensure
        @collecting = false
        unlock_post_stw
      end

      adapt_threshold_after_sweep if major
      @running_finalizers = true
      begin
        @finalizers.run_pending
      ensure
        @running_finalizers = false
      end
    end

    private def monotonic_ns : UInt64
      Clock.monotonic_ns
    end

    private def record_pause(started_ns : UInt64) : Nil
      now = monotonic_ns
      # Saturate on clock backward jump — checked UInt64 subtract raises
      # "Arithmetic overflow" (seen in Linux CI at_exit after STW).
      elapsed = now >= started_ns ? now - started_ns : 0_u64
      @last_pause_ns = elapsed
      @max_pause_ns = elapsed if elapsed > @max_pause_ns
      @total_pause_ns += elapsed
      @pause_count += 1
      @pause_ring[@pause_ring_pos] = elapsed
      @pause_ring_pos = (@pause_ring_pos + 1) % PAUSE_RING_SIZE
      @pause_ring_len += 1 if @pause_ring_len < PAUSE_RING_SIZE
      # HDR bucket: floor(log2(elapsed)) clamped to [0, PAUSE_HDR_BUCKETS-1].
      # 0 ns and very small pauses still need a bucket → use msb of (elapsed | 1).
      bucket = elapsed < 1_u64 ? 0 : bucket_for(elapsed)
      @pause_hdr[bucket] += 1
    end

    @[AlwaysInline]
    private def bucket_for(elapsed_ns : UInt64) : Int32
      # Bit-scan reverse + saturate to PAUSE_HDR_BUCKETS - 1.
      v = elapsed_ns
      idx = 0
      while v >= 2
        v >>= 1
        idx += 1
        break if idx >= PAUSE_HDR_BUCKETS - 1
      end
      idx
    end

    # HDR-based percentile over ALL recorded pauses (not bounded by ring size).
    # `pct` is in [0.0, 100.0]; returns 0 when no samples are recorded.
    def pause_percentile_hdr_ns(pct : Float64) : UInt64
      return 0_u64 if @pause_count == 0
      # Rank of the target sample in the cumulative distribution.
      # Linear interpolation between adjacent samples so p99.9 lands inside a
      # bucket instead of snapping to its high edge.
      total = @pause_count.to_f64
      rank = (pct / 100.0) * total
      rank = 0.0 if rank < 0.0
      target = rank
      cum = 0.0
      chosen = 0_u64
      chosen_high = 0_u64
      PAUSE_HDR_BUCKETS.times do |i|
        cnt = @pause_hdr[i].to_f64
        next if cnt <= 0
        if cum + cnt >= target
          # Bucket bounds: [2^i, 2^(i+1)). Interpolate inside the bucket based
          # on where the rank falls within the bucket mass.
          lo = 1_u64 << i
          hi = i + 1 < PAUSE_HDR_BUCKETS - 1 ? (1_u64 << (i + 1)) - 1_u64 : 1_u64 << (PAUSE_HDR_BUCKETS - 1)
          within = (target - cum) / cnt
          span = (hi.to_f64 - lo.to_f64) + 1.0
          chosen = lo + (within * span).to_u64
          # Clamp into [lo, hi].
          chosen = lo if chosen < lo
          chosen = hi if chosen > hi
          return chosen
        end
        cum += cnt
        chosen_high = (1_u64 << (i + 1)) - 1_u64
      end
      chosen_high
    end

    # Snapshot the HDR histogram (counts per power-of-two bucket, ns). Useful
    # for `/metrics`-style scrapers that want full distribution not just
    # percentiles.
    def pause_hdr_snapshot : StaticArray(UInt64, PAUSE_HDR_BUCKETS)
      out = StaticArray(UInt64, PAUSE_HDR_BUCKETS).new(0_u64)
      PAUSE_HDR_BUCKETS.times { |i| out[i] = @pause_hdr[i] }
      out
    end

    private def note_collection_begin : Nil
      @reclaimed_bytes_before_gc = @bytes_reclaimed_since_gc
      @bytes_before_gc = @bytes_since_gc.get
      @bytes_reclaimed_since_gc = 0_u64
      @layout_precise_scans = 0_u64
      @layout_conservative_scans = 0_u64
      @precise_stack_roots_marked = 0_u64
      @parked_fp_fill_frames = 0_u64
      @parked_fp_fill_bytes = 0_u64
      @parked_fp_fill_skipped_frames = 0_u64
      @parked_fp_fill_skipped_bytes = 0_u64
      @first_mark_stack_objects = 0_u64
      @first_mark_stack_bytes = 0_u64
      @first_mark_stack_atomic_bytes = 0_u64
      @first_mark_parked_objects = 0_u64
      @first_mark_parked_bytes = 0_u64
      @first_mark_parked_atomic_bytes = 0_u64
      @first_mark_static_objects = 0_u64
      @first_mark_static_bytes = 0_u64
      @first_mark_static_atomic_bytes = 0_u64
      @first_mark_thread_objects = 0_u64
      @first_mark_thread_bytes = 0_u64
      @first_mark_thread_atomic_bytes = 0_u64
      @first_mark_precise_objects = 0_u64
      @first_mark_precise_bytes = 0_u64
      @first_mark_precise_atomic_bytes = 0_u64
      @first_mark_heap_objects = 0_u64
      @first_mark_heap_bytes = 0_u64
      @first_mark_heap_atomic_bytes = 0_u64
      @first_mark_watch_stack = 0_u64
      @first_mark_watch_parked = 0_u64
      @first_mark_watch_static = 0_u64
      @first_mark_watch_thread = 0_u64
      @first_mark_watch_precise = 0_u64
      @first_mark_watch_heap = 0_u64
      @type_id_root_rejects = 0_u64
      @type_id_stack_rejects = 0_u64
      @type_id_static_rejects = 0_u64
      @type_id_thread_rejects = 0_u64
      @type_id_root_false_negatives = 0_u64
      @sp_clamp_hits = 0_u64
      @sp_clamp_fallbacks = 0_u64
      @thread_greg_candidates = 0_u64
      @ec_root_pins = 0_u64
      @ec_root_unpinned_ivars = 0_u64
      @ec_queue_audit_ring_slots = 0_u64
      @ec_queue_audit_list_slots = 0_u64
      @low_water_skips = 0_u64
      @low_water_skipped_bytes = 0_u64
    end

    # Returns true when a page-dirty barrier backend is available.
    # Incremental mark is unsound without barrier re-scan — live objects
    # written into already-scanned pages between slices would be swept.
    private def incremental_barrier_possible? : Bool
      !select_barrier_backend.none?
    end

    private def begin_incremental(scan_stack : Bool, roots : Array(Void*)?) : Nil
      # Without a page-dirty barrier, incremental mark is unsound when a
      # concurrent mutator can write pointers into already-scanned pages
      # between slices (process GC with @stop_the_world).  Single-threaded
      # library heaps are safe only when the caller never mutates the object
      # graph between slices — we allow it for backward compat with specs.
      if @stop_the_world && !incremental_barrier_possible?
        return
      end

      @collecting = true
      @incremental_marking = true
      @inc_active = true
      @minor_only = false
      begin
        lock_write
        stop_world_quiescing_roots
        note_collection_begin
        @mark_stack.clear
        clear_all_marks
        @before_collect_callbacks.each(&.call)
        @roots.each { |ptr| mark_explicit_root(ptr) }
        mark_large_alloc_in_flight
        mark_bitmap_alloc_in_flight
        roots.try &.each { |ptr| mark_explicit_root(ptr) }
        mark_metadata_roots
        scrub_parked_fiber_stacks if scan_stack
        scan_all_fiber_roots if scan_stack
        scan_thread_roots if scan_stack && @stop_the_world
        if @scan_static_roots
          Platform.scan_static_roots do |low, high|
            each_static_range_excluding_heap(low, high) do |a, b|
              Roots.scan_range_chunked(a, b, safe: true) { |candidate| mark_root_candidate(candidate, source: RootSource::Static) }
            end
          end
        end
        if scan_stack
          scan_mutator_stack
          scan_other_thread_stacks
        end
        # Arm page-dirty barrier for mutator writes between incremental slices.
        arm_page_barrier_after_collect
      ensure
        start_world
        unlock_write
        @collecting = false
      end
    end

    private def abort_incremental : Nil
      return unless @inc_active
      @inc_active = false
      @incremental_marking = false
      @mark_stack.clear
      disarm_mprotect_barrier if @barrier_backend.mprotect?
      @barrier_backend = Platform::BarrierBackend::None
      @soft_dirty_armed = false
    end
  end
end

require "./collect_stw"
require "./collect_scan"
require "./collect_mark"
require "./collect_sweep"
require "./barrier"
require "./blacklist"
