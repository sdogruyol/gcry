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
    DEFAULT_GC_THRESHOLD         =  4194304_u64 # 4 MiB — library / conservative
    PROCESS_GC_THRESHOLD         = 33554432_u64 # 32 MiB — empty munmap + two-pass reclaim
    DEFAULT_NURSERY_THRESHOLD    =   524288_u64 # 512 KiB minor
    DEFAULT_INCREMENTAL_WORK     =         1024
    MAX_AUTO_INCREMENTAL_SLICES  =            4 # slices per alloc when debt is high
    STATIC_ROOT_REFRESH_INTERVAL =       64_u64 # majors between /proc/self/maps refresh

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
    # Library default false (predictable tests); process GC leaves it off unless
    # GCRY_INCREMENTAL=1 (experimental without write barriers).
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
    getter dontneed_bytes : UInt64 = 0_u64
    # When false (default for library heaps), only object-base pointers are marked.
    # Process GC keeps this false; GCRY_INTERIOR=1 enables interiors for C embeds.
    property allow_interior_pointers : Bool = false
    # Reject ambient root candidates (stack/static) whose payload type_id looks
    # absurd. Heap-scan marks stay ungated so Array/Hash buffers remain reachable.
    # Process GC default-on; GCRY_DISABLE_TYPE_ID_GATE=1 escapes.
    property type_id_gate : Bool = false
    getter type_id_root_rejects : UInt64 = 0_u64
    # Precise scan via Gcry::Layout (type_id → pointer offsets). Unknown → conservative.
    property layout_precise : Bool = true
    getter layout_precise_scans : UInt64 = 0_u64
    getter layout_conservative_scans : UInt64 = 0_u64
    # When true, scan writable process mappings as roots (needed as process GC).
    property scan_static_roots : Bool = false
    property nursery_enabled : Bool = true
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
    getter last_phase_roots_ns : UInt64 = 0_u64
    getter last_phase_static_ns : UInt64 = 0_u64
    getter last_phase_stacks_ns : UInt64 = 0_u64
    getter last_phase_mark_ns : UInt64 = 0_u64
    getter last_phase_sweep_ns : UInt64 = 0_u64
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
    @mark_stack = MarkStack.new
    @finalizers = Finalizers::Registry.new
    @before_collect_callbacks = [] of -> Nil
    @collecting = false
    @running_finalizers = false
    @incremental_marking = false
    @inc_active = false
    @world_stopped = false
    # Serializes collect vs fiber context swap (ExecutionContext takes read lock).
    @gc_lock = Crystal::RWLock.new
    @heap_min : UInt64 = UInt64::MAX
    @heap_max : UInt64 = 0_u64
    @minor_only = false # mark filter during minor GC
    # Fully free size-class chunks queued in STW; munmap outside (like large trim).
    @pending_empty_chunks : ChunkHeader* = Pointer(ChunkHeader).null
    # After a successful clear_soft_dirty, minors may scan dirty pages only.
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
      @roots.add(pointer)
    end

    def delete_root(pointer : Void*) : Bool
      @roots.delete(pointer)
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

    # Full major collection (resets any in-progress incremental cycle).
    def collect(scan_stack : Bool = true, roots : Array(Void*)? = nil) : Nil
      return if @destroyed
      return if @collecting

      abort_incremental
      run_collection(major: true, scan_stack: scan_stack, roots: roots)
    end

    # Young-generation collection. Scans roots + old objects for nursery pointers
    # (no compiler write barrier required).
    def minor_collect(scan_stack : Bool = true, roots : Array(Void*)? = nil) : Nil
      return if @destroyed
      return if @collecting
      return unless @nursery_enabled

      abort_incremental
      run_collection(major: false, scan_stack: scan_stack, roots: roots)
    end

    # Incremental major mark slice (Boehm-style collect_a_little).
    # With a page-dirty barrier, termination re-scans dirty pages so stores into
    # already-scanned objects are not missed (sounder than plain SATB without barriers).
    # Returns true when a full cycle (mark+sweep) has completed.
    def collect_a_little(work_units : Int32 = DEFAULT_INCREMENTAL_WORK) : Bool
      return false if @destroyed
      return false if @collecting
      return false if @running_finalizers

      started = monotonic_ns
      unless @inc_active
        begin_incremental(scan_stack: true, roots: nil)
      end

      @collecting = true
      @incremental_marking = true
      finished = false
      begin
        lock_write
        stop_world
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
          @bytes_since_gc = 0_u64
          @nursery_alloc_bytes = 0_u64
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
        @collecting = false
        unless @inc_active
          @mark_stack.clear
          @incremental_marking = false
        end
        record_pause(started)
      end

      if finished
        flush_pending_empty_chunks
        trim_large_cache
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

    def find_object(pointer : Void*) : BlockHeader*?
      return nil if pointer.null?
      addr = pointer.address
      return nil if @heap_max == 0 || addr < @heap_min || addr >= @heap_max

      chunk = chunk_containing(addr)
      return nil unless chunk

      if ChunkHeader.large?(chunk)
        header = ChunkHeader.data_start(chunk).as(BlockHeader*)
        return nil if BlockHeader.free?(header)
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

      header = Pointer(BlockHeader).new(header_addr)
      return nil if BlockHeader.free?(header)
      header
    end

    protected def maybe_collect : Nil
      return unless @enabled
      return if @collecting
      return if @running_finalizers

      @alloc_ops &+= 1
      if @stress_every > 0 && (@alloc_ops % @stress_every.to_u64) == 0
        collect
        return
      end

      if @nursery_enabled && @nursery_alloc_bytes >= @nursery_threshold
        minor_collect
        return
      end

      # Keep draining an in-progress incremental cycle even if under threshold.
      if @inc_active
        collect_a_little(@incremental_work)
        return
      end

      return if @bytes_since_gc < @gc_threshold

      if @incremental_auto
        slices = 0
        while slices < MAX_AUTO_INCREMENTAL_SLICES
          finished = collect_a_little(@incremental_work)
          slices += 1
          break if finished
          break unless @inc_active
        end
      else
        collect
      end
    end

    protected def destroy_collector : Nil
      flush_pending_empty_chunks
      abort_incremental
      @roots.clear
      @mark_stack.destroy
      @finalizers.clear
      @before_collect_callbacks.clear
      @heap_min = UInt64::MAX
      @heap_max = 0_u64
      @collections = 0_u64
      @minor_collections = 0_u64
      @major_collections = 0_u64
      @stack_bottom = Pointer(Void).null
      @nursery_alloc_bytes = 0_u64
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
    end

    protected def update_heap_bounds_after_unmap : Nil
      @heap_min = UInt64::MAX
      @heap_max = 0_u64
      each_chunk do |chunk|
        note_mapped(chunk)
      end
    end

    private def run_collection(major : Bool, scan_stack : Bool, roots : Array(Void*)?) : Nil
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
        lock_write
        stop_world
        flush_all_tlabs
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
        # Explicit roots respect allow_interior_pointers (ambient-style).
        @roots.each { |ptr| mark_root_candidate(ptr) }
        roots.try &.each { |ptr| mark_root_candidate(ptr) }
        mark_metadata_roots
        # Fiber objects + suspended stacks (once; not also via push_gc_roots).
        scrub_parked_fiber_stacks if scan_stack
        scan_all_fiber_roots if scan_stack
        scan_thread_roots if scan_stack && @stop_the_world
        @last_phase_roots_ns = monotonic_ns - t0

        t0 = monotonic_ns
        if @scan_static_roots
          Platform.scan_static_roots do |low, high|
            each_static_range_excluding_heap(low, high) do |a, b|
              Roots.scan_range(a, b, safe: true) { |candidate| mark_root_candidate(candidate) }
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

        # Finalizers / WeakRef: one index pass (no Proc — that mallocs mid-STW).
        enqueue_unreachable_finalizers

        t0 = monotonic_ns
        sweep(major: major)
        @last_phase_sweep_ns = monotonic_ns - t0

        if major
          @bytes_since_gc = 0_u64
          @nursery_alloc_bytes = 0_u64
          @expl_freed_bytes_since_gc = 0_u64
          @major_collections += 1
          if (@major_collections % STATIC_ROOT_REFRESH_INTERVAL) == 0
            Platform.invalidate_static_root_cache
          end
          # Next minor starts a fresh soft-dirty window after a major.
          @soft_dirty_skip_until_major = false
          arm_page_barrier_after_collect if @nursery_enabled || @incremental_auto
        else
          @nursery_alloc_bytes = 0_u64
          @minor_collections += 1
          arm_page_barrier_after_collect
        end
        @collections += 1
      ensure
        start_world
        unlock_write
        @collecting = false
        @minor_only = false
        @mark_stack.clear
        record_pause(started)
      end

      # Munmap outside STW — empty chunks + excess large freelist (reuse common).
      flush_pending_empty_chunks
      trim_large_cache

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
      elapsed = monotonic_ns - started_ns
      @last_pause_ns = elapsed
      @max_pause_ns = elapsed if elapsed > @max_pause_ns
      @total_pause_ns += elapsed
      @pause_count += 1
      @pause_ring[@pause_ring_pos] = elapsed
      @pause_ring_pos = (@pause_ring_pos + 1) % PAUSE_RING_SIZE
      @pause_ring_len += 1 if @pause_ring_len < PAUSE_RING_SIZE
    end

    private def note_collection_begin : Nil
      @reclaimed_bytes_before_gc = @bytes_reclaimed_since_gc
      @bytes_before_gc = @bytes_since_gc
      @bytes_reclaimed_since_gc = 0_u64
      @layout_precise_scans = 0_u64
      @layout_conservative_scans = 0_u64
      @type_id_root_rejects = 0_u64
      @sp_clamp_hits = 0_u64
      @sp_clamp_fallbacks = 0_u64
    end

    private def begin_incremental(scan_stack : Bool, roots : Array(Void*)?) : Nil
      @collecting = true
      @incremental_marking = true
      @inc_active = true
      @minor_only = false
      begin
        lock_write
        stop_world
        note_collection_begin
        @mark_stack.clear
        clear_all_marks
        @before_collect_callbacks.each(&.call)
        @roots.each { |ptr| mark_root_candidate(ptr) }
        roots.try &.each { |ptr| mark_root_candidate(ptr) }
        mark_metadata_roots
        scrub_parked_fiber_stacks if scan_stack
        scan_all_fiber_roots if scan_stack
        scan_thread_roots if scan_stack && @stop_the_world
        if @scan_static_roots
          Platform.scan_static_roots do |low, high|
            each_static_range_excluding_heap(low, high) do |a, b|
              Roots.scan_range(a, b, safe: true) { |candidate| mark_root_candidate(candidate) }
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
