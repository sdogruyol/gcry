{% if flag?(:linux) %}
  require "./platform/linux_roots"
  require "./platform/linux_stack"
  require "./platform/linux_softdirty"
  require "./platform/linux_stw"
  require "./platform/linux_fork"
{% elsif flag?(:darwin) %}
  require "./platform/darwin_stubs"
  require "./platform/darwin_roots"
  require "./platform/darwin_stack"
  require "./platform/darwin_stw"
  require "./platform/linux_fork"
{% end %}

require "./mark"
require "./roots"
require "./finalizer"

module Gcry
  class Heap
    DEFAULT_GC_THRESHOLD =  4194304_u64 # 4 MiB — library / conservative
    PROCESS_GC_THRESHOLD = 33554432_u64 # 32 MiB — empty munmap + two-pass reclaim
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
    # Bytes of fully-free chunks to keep dormant (DONTNEED) for reuse.
    property empty_chunk_retain : UInt64 = DEFAULT_EMPTY_CHUNK_RETAIN
    # MADV_DONTNEED free pages in partially-live chunks after major (Linux).
    # Partial-page MADV_DONTNEED on sparse chunks (opt-in — STW cost).
    property madvise_free_pages : Bool = false
    getter dormant_chunk_bytes : UInt64 = 0_u64
    # Fully-dormant size-class chunks skipped in sweep (no block walk).
    getter sweep_dormant_skips : UInt64 = 0_u64
    getter dontneed_bytes : UInt64 = 0_u64
    # When false (default for library heaps), only object-base pointers are marked.
    # Process GC keeps this false; GCRY_INTERIOR=1 enables interiors for C embeds.
    property allow_interior_pointers : Bool = false
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
    getter layout_conservative_scans : UInt64 = 0_u64
    # When true, scan writable process mappings as roots (needed as process GC).
    property scan_static_roots : Bool = false
    # Ring buffer for heap range observations (raw bytes, not headroom-inflated).
    # On each major we record the heap range in bitmap-bytes; the average × 25 %
    # becomes the adaptive headroom for the next interval.
    BITMAP_GROWTH_HISTORY_CAPACITY = 16
    @bitmap_growth_history = StaticArray(UInt64, BITMAP_GROWTH_HISTORY_CAPACITY).new(0_u64)
    @bitmap_growth_count : Int32 = 0
    @bitmap_growth_pos : Int32 = 0
    # Cached adaptive headroom (in bitmap-bytes), recomputed after each major.
    # Read by `ensure_bitmap_covers` on the allocation hot path — must be O(1).
    @bitmap_headroom_bytes : UInt64 = 0

    property nursery_enabled : Bool = true
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
    @heap_span_lo : UInt64 = UInt64::MAX
    @heap_span_hi : UInt64 = 0_u64
    @minor_only = false # mark filter during minor GC
    # Fully free size-class chunks queued in STW; munmap outside (like large trim).
    @pending_empty_chunks : ChunkHeader* = Pointer(ChunkHeader).null
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

    def register_disappearing_link(link : Void**, object : Void* = Pointer(Void).null) : Nil
      referent = object
      if referent.null?
        referent = link.value
      end
      return if referent.null?

      if header = find_object(referent)
        referent = BlockHeader.user_from(header)
        BlockHeader.set_disappearing(header)
      end
      @finalizers.register_disappearing_link(link, referent)
    end

    def live?(pointer : Void*) : Bool
      return false if pointer.null?
      header = find_object(pointer)
      return false unless header
      !BlockHeader.free?(header)
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
            trim_large_cache
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
    def find_block(pointer : Void*) : BlockHeader*?
      return nil if pointer.null?
      addr = pointer.address
      return nil if @heap_max == 0 || addr < @heap_min || addr >= @heap_max

      chunk = chunk_containing(addr)
      return nil unless chunk

      if ChunkHeader.large?(chunk)
        header = ChunkHeader.data_start(chunk).as(BlockHeader*)
        finish = BlockHeader.user_from(header).address + header.value.size
        return header if addr >= header.address && addr < finish
        return nil
      end

      class_index = chunk.value.size_class.to_i32
      return nil if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      block_bytes = @block_bytes[class_index]
      data_start = chunk.address + ChunkHeader::SIZE
      return nil if addr < data_start

      offset = addr - data_start
      header_addr = data_start + (offset // block_bytes) * block_bytes
      return nil if header_addr + block_bytes > chunk.address + chunk.value.mapped_bytes

      Pointer(BlockHeader).new(header_addr)
    end

    def find_object(pointer : Void*) : BlockHeader*?
      header = find_block(pointer)
      return nil unless header
      return nil if BlockHeader.free?(header)
      header
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
      flush_pending_dormant_chunks
      flush_pending_page_release_chunks
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
      @heap_min = base if base < @heap_min
      @heap_max = finish if finish > @heap_max
      @heap_span_lo = base if base < @heap_span_lo
      @heap_span_hi = finish if finish > @heap_span_hi
      ensure_bitmap_covers(@heap_min, @heap_max)
    end

    protected def ensure_bitmap_covers(lo : UInt64, hi : UInt64) : Nil
      return if lo >= hi || lo == UInt64::MAX
      bm = @mark_bitmap
      return unless bm
      # 1 bit per word-aligned address → bytes_needed = (range / 8).
      range_bytes = (hi - lo) >> 3
      # Adaptive headroom: cached from last major (recomputed outside hot path).
      headroom = @bitmap_headroom_bytes
      headroom = @small_chunk_bytes >> 3 if headroom < (@small_chunk_bytes >> 3)
      needed = range_bytes + headroom
      if bm.base_addr != lo || !bm.covers?(lo, hi)
        bm.relocate(lo, needed) do |base, base_addr, cap_bits|
          @mark_bitmap_base = base.address
          @mark_bitmap_base_addr = base_addr
          @mark_bitmap_cap_bits = cap_bits
        end
      elsif bm.capacity_bytes < needed
        bm.relocate(lo, needed) do |base, base_addr, cap_bits|
          @mark_bitmap_base = base.address
          @mark_bitmap_base_addr = base_addr
          @mark_bitmap_cap_bits = cap_bits
        end
      end
    end

    # Record a heap range observation (bytes, not headroom-inflated).
    # Called after each major collect with the current `range_bytes`.
    # Also recomputes the cached `@bitmap_headroom_bytes`.
    private def note_bitmap_growth(actual_range_bytes : UInt64) : Nil
      @bitmap_growth_history[@bitmap_growth_pos] = actual_range_bytes
      @bitmap_growth_pos = (@bitmap_growth_pos + 1) % BITMAP_GROWTH_HISTORY_CAPACITY
      @bitmap_growth_count += 1 if @bitmap_growth_count < BITMAP_GROWTH_HISTORY_CAPACITY
      # Recompute cached headroom: 25 % of the running average of raw heap
      # range observations. Done once per major — never on the allocation path.
      avg_range = compute_bitmap_growth_avg
      @bitmap_headroom_bytes = avg_range > 0 ? (avg_range >> 3) : (@small_chunk_bytes >> 3)
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

    # Average of recorded growth history entries (0 if none).
    private def compute_bitmap_growth_avg : UInt64
      return 0_u64 if @bitmap_growth_count == 0
      sum = 0_u64
      count = @bitmap_growth_count
      BITMAP_GROWTH_HISTORY_CAPACITY.times do |i|
        sum += @bitmap_growth_history[i] if i < count
      end
      sum // count.to_u64
    end

    protected def update_heap_bounds_after_unmap : Nil
      @last_chunk_idx = -1
      @last_chunk_lo = 0_u64
      @last_chunk_hi = 0_u64
      # Single pass to recompute bounds, then one call to ensure_bitmap_covers
      # (avoids O(N) `note_mapped` per chunk → O(N) `ensure_bitmap_covers`).
      lo = UInt64::MAX
      hi = 0_u64
      each_chunk do |chunk|
        base = chunk.address
        finish = base + chunk.value.mapped_bytes
        lo = base if base < lo
        hi = finish if finish > hi
      end
      @heap_min = lo
      @heap_max = hi
      ensure_bitmap_covers(lo, hi)
      # After bounds are tightened, check whether the bitmap has grown
      # well beyond the current need and shrink it if so.  Threshold:
      # capacity > 1.2 × needed  OR  capacity > needed + 1 MiB (absolute waste).
      # This runs outside STW (called from flush_pending_empty_chunks,
      # trim_large_cache, and reclaim_empty_chunk) so the syscall cost is
      # tolerable.
      if hi > lo && lo != UInt64::MAX
        bm = @mark_bitmap
        if bm
          needed = ((hi - lo) >> 3) + @bitmap_headroom_bytes
          waste = bm.capacity_bytes > needed ? bm.capacity_bytes - needed : 0_u64
          if waste > needed / 5 || waste > 1048576_u64 # 1.2× OR >1 MiB waste
            bm.shrink_to_fit!(needed)
            @mark_bitmap_base = bm.base.as(UInt64*).address
            @mark_bitmap_base_addr = bm.base_addr
            @mark_bitmap_cap_bits = bm.capacity_bytes * 8_u64
          end
        end
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

    private def run_collection(major : Bool, scan_stack : Bool, roots : Array(Void*)?, coalesce : Bool = false) : Nil
      cols_before = @collections
      # Hold post-STW mutex through flush so Parallel EC cannot stop_world
      # mid-munmap. Auto-collect: trylock or skip (no waiter pile-up).
      return unless acquire_post_stw(coalesce, cols_before, major)

      begin
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
          flush_all_tlabs
          # TLAB-off USED stash → freelist before mark (unscanned thread locals).
          flush_all_alloc_batches
          # USED-on-freelist can remain after mid-`tlab_alloc_small` STW; unlink
          # those nodes before mark/sweep (see scrub_freelists / unlink_freelist_range).
          scrub_freelists
          note_collection_begin
          @mark_stack.clear

          t0 = monotonic_ns
          if major
            clear_all_marks
          else
            clear_nursery_marks
          end
          @last_phase_clear_ns = monotonic_ns - t0

          t0 = monotonic_ns
          @before_collect_callbacks.each(&.call)
          # Explicit roots: no type_id_gate (must keep raw Pointer buffers for
          # realloc pin / add_root); still respect allow_interior_pointers.
          @roots.each { |ptr| mark_explicit_root(ptr) }
          roots.try &.each { |ptr| mark_explicit_root(ptr) }
          mark_metadata_roots
          # Fiber scrub timed separately (Parallel A/B); excluded from roots_ns.
          t_scrub = monotonic_ns
          scrub_parked_fiber_stacks if scan_stack
          scrub_ns = monotonic_ns - t_scrub
          @last_phase_scrub_ns = scrub_ns
          # Fiber objects + suspended stacks (once; not also via push_gc_roots).
          scan_all_fiber_roots if scan_stack
          scan_thread_roots if scan_stack && @stop_the_world
          @last_phase_roots_ns = monotonic_ns - t0 - scrub_ns

          t0 = monotonic_ns
          if @scan_static_roots
            Platform.scan_static_roots do |low, high|
              each_static_range_excluding_heap(low, high) do |a, b|
                Roots.scan_range(a, b, safe: true) { |candidate| mark_root_candidate(candidate, source: RootSource::Static) }
              end
            end
          end
          @last_phase_static_ns = monotonic_ns - t0

          t0 = monotonic_ns
          if scan_stack
            scan_mutator_stack
            scan_other_thread_stacks
          end
          @last_phase_stacks_ns = monotonic_ns - t0

          # Conservatively find nursery pointers from old objects.
          # Official path: page-dirty remembered set (soft-dirty / mprotect).
          scan_old_for_nursery_pointers unless major

          t0 = monotonic_ns
          mark_loop
          @last_phase_mark_ns = monotonic_ns - t0

          # Claiming FREE mid-alloc blocks during mark can leave USED-on-freelist;
          # drop them before sweep / empty-chunk unlink.
          scrub_freelists

          # Finalizers / WeakRef: one index pass (no Proc — that mallocs mid-STW).
          enqueue_unreachable_finalizers

          # For minor collections, snapshot nursery alloc bytes and reset survival
          # counter before sweep accumulates surviving nursery payload.
          if !major
            @nursery_alloc_before_minor = @nursery_alloc_bytes.get
            @nursery_survival_bytes = 0_u64
          end

          # Lazy sweep (Parallel reclaim-off): end STW before reclaim so pause
          # excludes O(heap) phase_sweep; sweep runs under freelist locks.
          @lazy_sweep_pending = sweep_after_world?
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
              sweep(major: major, after_world: true)
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
            # DORMANT madvise outside STW — kernel VM lock contention avoided.
            flush_pending_dormant_chunks
            # Partial-chunk free-page madvise outside STW (HOLED / Darwin all-chunk walk).
            flush_pending_page_release_chunks
            # Large freelist: Darwin MADV_FREE_REUSABLE; Linux MADV_FREE (content until reclaim).
            release_large_freelist_pages
            trim_large_cache
            @last_phase_flush_ns = monotonic_ns - t_flush
          ensure
            if ec1_lazy
              @block_other_heap = false
              @stw_owner = nil
            end
          end

          # After a major collect, record the heap range observation so the
          # adaptive headroom in `ensure_bitmap_covers` stays tight.
          # We record the raw range_bytes (not headroom-inflated) to avoid a
          # positive-feedback loop where headroom drives up the running average.
          if major
            range_bytes = @heap_max > @heap_min ? ((@heap_max - @heap_min) >> 3) : 0_u64
            note_bitmap_growth(range_bytes)

            # Adaptive large-cache retain: grow when hit rate is high, shrink when low.
            # Resets counters each major so the policy tracks the current working set.
            total_large = @large_cache_hits + @large_cache_misses
            if total_large > 0
              hit_pct = (@large_cache_hits * 100) // total_large
              current = @large_cache_retain
              if hit_pct > 50 && current < LARGE_CACHE_LIMIT
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

      @running_finalizers = true
      begin
        @finalizers.run_pending
      ensure
        @running_finalizers = false
      end
    end

    private def monotonic_ns : UInt64
      ts = uninitialized LibC::Timespec
      LibC.clock_gettime(LibC::CLOCK_MONOTONIC, pointerof(ts))
      ts.tv_sec.to_u64 * 1_000_000_000_u64 + ts.tv_nsec.to_u64
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
      @type_id_root_rejects = 0_u64
      @type_id_stack_rejects = 0_u64
      @type_id_static_rejects = 0_u64
      @type_id_thread_rejects = 0_u64
      @type_id_root_false_negatives = 0_u64
      @sp_clamp_hits = 0_u64
      @sp_clamp_fallbacks = 0_u64
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
        roots.try &.each { |ptr| mark_explicit_root(ptr) }
        mark_metadata_roots
        scrub_parked_fiber_stacks if scan_stack
        scan_all_fiber_roots if scan_stack
        scan_thread_roots if scan_stack && @stop_the_world
        if @scan_static_roots
          Platform.scan_static_roots do |low, high|
            each_static_range_excluding_heap(low, high) do |a, b|
              Roots.scan_range(a, b, safe: true) { |candidate| mark_root_candidate(candidate, source: RootSource::Static) }
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
