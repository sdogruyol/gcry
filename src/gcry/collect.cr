require "./mark"
require "./roots"
require "./finalizer"
require "./platform/linux_roots"
require "./platform/linux_stack"

module Gcry
  class Heap
    DEFAULT_GC_THRESHOLD         =  4194304_u64 # 4 MiB — library / conservative
    PROCESS_GC_THRESHOLD         = 67108864_u64 # 64 MiB — process GC (fewer STW)
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
    # When true, fully free size-class chunks are munmap'd after major sweep.
    # Library + process default false (HTTP cost); enable via GCRY_RELEASE_CHUNKS=1.
    property release_empty_chunks : Bool = false
    # When true, scan writable process mappings as roots (needed as process GC).
    property scan_static_roots : Bool = false
    property nursery_enabled : Bool = true
    # Process GC: Crystal 1.21+ always has a Monitor (SYSMON) thread even at
    # ExecutionContext parallelism 1. Without STW + scanning that thread's
    # current fiber stack, live objects are swept → heap corruption under load.
    property stop_the_world : Bool = false

    getter unmapped_bytes : UInt64 = 0_u64
    # Last major STW phase timings (ns) — for /gc-stats and tuning.
    getter last_phase_clear_ns : UInt64 = 0_u64
    getter last_phase_roots_ns : UInt64 = 0_u64
    getter last_phase_static_ns : UInt64 = 0_u64
    getter last_phase_stacks_ns : UInt64 = 0_u64
    getter last_phase_mark_ns : UInt64 = 0_u64
    getter last_phase_sweep_ns : UInt64 = 0_u64
    # Occupancy after last major (size-class chunks only).
    getter size_class_chunk_count : UInt64 = 0_u64
    getter fully_free_chunk_bytes : UInt64 = 0_u64
    getter released_chunk_bytes : UInt64 = 0_u64

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

    def enable : Nil
      @enabled = true
    end

    def disable : Nil
      @enabled = false
    end

    def lock_read : Nil
      return unless @stop_the_world
      @gc_lock.read_lock
    end

    def unlock_read : Nil
      return unless @stop_the_world
      @gc_lock.read_unlock
    end

    def lock_write : Nil
      return unless @stop_the_world
      @gc_lock.write_lock
    end

    def unlock_write : Nil
      return unless @stop_the_world
      @gc_lock.write_unlock
    end

    # Match Crystal `gc/none` STW: signal-suspend every other OS thread.
    # Required for process GC because ExecutionContext's Monitor thread holds
    # live heap pointers that are not on Fiber.current's stack.
    #
    # Do not hold Thread.lock across suspend/mark — another thread may allocate
    # while mutating the thread list and deadlock on @gc_lock.
    def stop_world : Nil
      return unless @stop_the_world
      return if @world_stopped

      current_thread = Thread.current
      Thread.unsafe_each do |thread|
        thread.suspend unless thread == current_thread
      end
      Thread.unsafe_each do |thread|
        thread.wait_suspended unless thread == current_thread
      end
      @world_stopped = true
    end

    def start_world : Nil
      return unless @world_stopped

      current_thread = Thread.current
      Thread.unsafe_each do |thread|
        thread.resume unless thread == current_thread
      end
      @world_stopped = false
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

    def push_stack(stack_top : Void*, stack_bottom : Void*) : Nil
      raise "push_stack outside of collect" unless @collecting
      # stack_top may sit on the PROT_NONE guard; cheap safe skips leading
      # unreadable pages then bulk-scans (see Roots.scan_range_safe).
      Roots.scan_range(stack_top, stack_bottom, safe: true) do |candidate|
        mark_candidate(candidate)
      end
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
          @inc_active = false
          @incremental_marking = false
          finished = true
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
      @minor_only = !major
      begin
        # Block fiber swaps, then suspend other OS threads.
        lock_write
        stop_world
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
        @roots.each { |ptr| mark_candidate(ptr) }
        roots.try &.each { |ptr| mark_candidate(ptr) }
        mark_metadata_roots
        # Fiber objects + suspended stacks (once; not also via push_gc_roots).
        scan_all_fiber_roots if scan_stack
        scan_thread_roots if scan_stack && @stop_the_world
        @last_phase_roots_ns = monotonic_ns - t0

        t0 = monotonic_ns
        if @scan_static_roots
          Platform.scan_static_roots do |low, high|
            each_static_range_excluding_heap(low, high) do |a, b|
              Roots.scan_range(a, b, safe: true) { |candidate| mark_candidate(candidate) }
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

        # Conservatively find nursery pointers from old objects (no write barrier).
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
        else
          @nursery_alloc_bytes = 0_u64
          @minor_collections += 1
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

    # Mark Thread objects and their current_fiber (TLS alone is not scanned).
    private def scan_thread_roots : Nil
      Thread.unsafe_each do |thread|
        mark_candidate(Pointer(Void).new(thread.object_id))
        mark_candidate(Pointer(Void).new(thread.current_fiber.object_id))
      end
    end

    # Spill GP registers, then scan approx SP→bottom for the running fiber.
    private def scan_mutator_stack : Nil
      bottom = Fiber.current.@stack.bottom
      @stack_bottom = bottom
      Roots.scan_mutator(bottom) do |candidate|
        mark_candidate(candidate)
      end
    end

    # Mark every Fiber object; scan suspended fibers via saved stack_top
    # (same as push_gc_roots). Running fibers on other threads are handled by
    # scan_other_thread_stacks after STW.
    private def scan_all_fiber_roots : Nil
      current = Fiber.current
      Fiber.unsafe_each do |fiber|
        mark_candidate(Pointer(Void).new(fiber.object_id))
        next if fiber == current
        next if fiber.running?
        # Clamp below guard page (PROT_NONE); stack_top can sit there after overflow.
        # safe:true: reported ranges can still contain holes on some kernels.
        stack = fiber.@stack
        top = fiber.@context.stack_top.address
        guard = stack.pointer.address + Roots::PAGE_SIZE
        top = guard if top < guard
        Roots.scan_range(Pointer(Void).new(top), stack.bottom, safe: true) do |candidate|
          mark_candidate(candidate)
        end
      end
    end

    # Running fibers on *other* OS threads are skipped by `push_gc_roots`
    # (`fiber.running?` is true). After STW, scan their stacks.
    #
    # Main fibers use the pthread stack — always query pthread bounds (Fiber
    # `@stack.bottom` was historically a single global and wrong for SYSMON).
    # Pooled fiber stacks have a PROT_NONE guard page at `stack.pointer`.
    private def scan_other_thread_stacks : Nil
      return unless @stop_the_world

      current = Thread.current
      Thread.unsafe_each do |thread|
        next if thread == current
        fiber = thread.current_fiber
        stack = fiber.@stack

        if fiber.name == "main"
          if bounds = Platform.pthread_stack_bounds(thread.to_unsafe)
            # glibc may include a guard page inside getattr bounds — probe.
            Roots.scan_range(bounds[0], bounds[1], safe: true) do |candidate|
              mark_candidate(candidate)
            end
            next
          end
        end

        # Skip PROT_NONE guard; prefer saved stack_top (used portion) when it
        # sits above the guard — full 8 MiB scans kill STW under many fibers.
        guard = stack.pointer.address + Roots::PAGE_SIZE
        top = fiber.@context.stack_top.address
        top = guard if top < guard
        low = Pointer(Void).new(top)
        next if low.address >= stack.bottom.address
        Roots.scan_range(low, stack.bottom, safe: true) do |candidate|
          mark_candidate(candidate)
        end
      end
    end

    private def mark_metadata_roots : Nil
      # No Crystal Proc/closure — allocating mid-mark re-enters malloc.
      n = @finalizers.entry_count
      if n > 0
        mark_candidate(@finalizers.entries_buffer)
        i = 0
        while i < n
          data = @finalizers.entry_closure_data_at(i)
          mark_candidate(data) unless data.null?
          i += 1
        end
      end
      if @finalizers.link_count > 0
        mark_candidate(@finalizers.links_buffer)
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
        @roots.each { |ptr| mark_candidate(ptr) }
        roots.try &.each { |ptr| mark_candidate(ptr) }
        mark_metadata_roots
        scan_all_fiber_roots if scan_stack
        scan_thread_roots if scan_stack && @stop_the_world
        if @scan_static_roots
          Platform.scan_static_roots do |low, high|
            each_static_range_excluding_heap(low, high) do |a, b|
              Roots.scan_range(a, b, safe: true) { |candidate| mark_candidate(candidate) }
            end
          end
        end
        if scan_stack
          scan_mutator_stack
          scan_other_thread_stacks
        end
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

    private def mark_candidate(pointer : Void*) : Nil
      addr = pointer.address
      return if @heap_max == 0 || addr < @heap_min || addr >= @heap_max
      # Crystal pointers are word-aligned; reject interior/misaligned false hits fast.
      return if (addr & (sizeof(Void*).to_u64 - 1)) != 0

      header = find_object(pointer)
      return unless header
      return if BlockHeader.free?(header)
      return if BlockHeader.marked?(header)
      if @minor_only && !BlockHeader.nursery?(header)
        return
      end

      BlockHeader.set_mark(header)
      @mark_stack.push(header)
    end

    private def mark_loop : Nil
      until @mark_stack.empty?
        header = @mark_stack.pop
        scan_object(header)
      end
    end

    private def mark_loop_budget(work_units : Int32) : Nil
      units = 0
      while units < work_units && !@mark_stack.empty?
        header = @mark_stack.pop
        scan_object(header)
        units += 1
      end
    end

    private def scan_object(header : BlockHeader*) : Nil
      return if BlockHeader.atomic?(header)

      user = BlockHeader.user_from(header).as(UInt8*)
      size = clamped_scan_size(header, user)
      return if size == 0

      word = sizeof(Void*).to_u64
      words = size // word
      cursor = user.as(UInt64*)
      words.times do |i|
        mark_candidate(Pointer(Void).new(cursor[i]))
      end
    end

    # Corrupted header.size must not walk past the mapped chunk (SIGSEGV).
    private def clamped_scan_size(header : BlockHeader*, user : UInt8*) : UInt64
      size = header.value.size.to_u64
      chunk = chunk_containing(header.address)
      return 0_u64 unless chunk

      max = if ChunkHeader.large?(chunk)
              end_addr = ChunkHeader.data_end(chunk).address
              end_addr > user.address ? (end_addr - user.address) : 0_u64
            else
              class_index = chunk.value.size_class.to_i32
              return 0_u64 if class_index < 0 || class_index >= SIZE_CLASS_COUNT
              SizeClasses.payload(class_index).to_u64
            end
      size > max ? max : size
    end

    private def scan_old_for_nursery_pointers : Nil
      each_chunk do |chunk|
        if ChunkHeader.large?(chunk)
          header = ChunkHeader.data_start(chunk).as(BlockHeader*)
          next if BlockHeader.free?(header)
          scan_object_for_nursery(header)
        else
          each_block(chunk) do |header|
            next if BlockHeader.free?(header)
            next if BlockHeader.nursery?(header)
            scan_object_for_nursery(header)
          end
        end
      end
    end

    private def scan_object_for_nursery(header : BlockHeader*) : Nil
      return if BlockHeader.atomic?(header)
      user = BlockHeader.user_from(header).as(UInt8*)
      size = clamped_scan_size(header, user)
      return if size == 0

      word = sizeof(Void*).to_u64
      words = size // word
      cursor = user.as(UInt64*)
      words.times do |i|
        cand = Pointer(Void).new(cursor[i])
        next unless (h = find_object(cand))
        next unless BlockHeader.nursery?(h)
        mark_candidate(cand)
      end
    end

    private def clear_all_marks : Nil
      each_chunk do |chunk|
        each_block_or_large(chunk) do |header|
          next if BlockHeader.free?(header)
          BlockHeader.clear_mark(header)
        end
      end
    end

    # Minor GC: reset nursery mark bits only.
    private def clear_nursery_marks : Nil
      each_chunk do |chunk|
        next unless ChunkHeader.nursery?(chunk)
        each_block(chunk) do |header|
          next if BlockHeader.free?(header)
          BlockHeader.clear_mark(header)
        end
      end
    end

    private def each_block_or_large(chunk : ChunkHeader*, & : BlockHeader* ->) : Nil
      if ChunkHeader.large?(chunk)
        yield ChunkHeader.data_start(chunk).as(BlockHeader*)
      else
        each_block(chunk) { |h| yield h }
      end
    end

    # After mark, before sweep. Allocation-free (no Crystal Proc/closure).
    private def enqueue_unreachable_finalizers : Nil
      i = 0
      while i < @finalizers.entry_count
        if unmarked_live_object?(@finalizers.entry_object_at(i))
          @finalizers.queue_and_remove_entry_at(i)
        else
          i += 1
        end
      end

      i = 0
      while i < @finalizers.link_count
        if unmarked_live_object?(@finalizers.link_object_at(i))
          @finalizers.clear_and_remove_link_at(i)
        else
          i += 1
        end
      end
    end

    private def unmarked_live_object?(obj : Void*) : Bool
      return false if obj.null?
      header = find_object(obj)
      return false unless header
      return false if BlockHeader.free?(header)
      !BlockHeader.marked?(header)
    end

    private def sweep(major : Bool) : Nil
      # Rebuild the chunk list in one pass. Reclaiming large objects used to
      # unlink + dirty the chunk index per object; every following reclaim_small
      # then rebuilt/sorted the index (O(n²) insertion sort) — that made sweep
      # multi-second on HTTP apps with many large allocs (see unmapped_bytes).
      kept = Pointer(ChunkHeader).null
      # Fully free size-class chunks: queue here, munmap after start_world.
      to_unmap = Pointer(ChunkHeader).null
      any_drop = false
      # Opt-in empty-chunk release: defer freelist rebuilds per size-class.
      rebuild_mask = 0_u64
      rebuild_nursery_mask = 0_u64

      if major
        @size_class_chunk_count = 0_u64
        @fully_free_chunk_bytes = 0_u64
        @released_chunk_bytes = 0_u64
      end

      chunk = @chunks
      while chunk
        nxt = chunk.value.next
        drop = false

        if major || ChunkHeader.nursery?(chunk)
          if ChunkHeader.large?(chunk)
            header = ChunkHeader.data_start(chunk).as(BlockHeader*)
            unless BlockHeader.free?(header)
              if BlockHeader.marked?(header)
                BlockHeader.clear_mark(header)
              elsif major
                # Recycle mapping — never munmap inside STW (Linux VMA munmap
                # of thousands of large HTTP buffers dominated pause time).
                mapped = chunk.value.mapped_bytes
                cache_large_chunk(chunk, header)
                @bytes_reclaimed_since_gc += mapped
                @live_objects -= 1 if @live_objects > 0
              end
            end
          else
            # Inline size-class sweep — avoid each_block yield overhead on
            # multi-million block heaps (dominated phase_sweep under HTTP).
            class_index = chunk.value.size_class.to_i32
            any_live = false
            if class_index >= 0 && class_index < SIZE_CLASS_COUNT
              payload = SizeClasses.payload(class_index)
              block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
              cursor = ChunkHeader.data_start(chunk).as(UInt8*)
              limit = ChunkHeader.data_end(chunk).as(UInt8*)
              while (cursor + block_bytes) <= limit
                header = cursor.as(BlockHeader*)
                unless BlockHeader.free?(header)
                  if major || BlockHeader.nursery?(header)
                    if BlockHeader.marked?(header)
                      BlockHeader.clear_mark(header)
                      BlockHeader.promote(header) unless major
                      any_live = true
                    else
                      reclaim_small(chunk, header, payload)
                    end
                  else
                    any_live = true
                  end
                end
                cursor += block_bytes
              end
            else
              any_live = true
            end

            if major
              unless any_live
                mapped = chunk.value.mapped_bytes
                @fully_free_chunk_bytes += mapped
                if @release_empty_chunks && class_index >= 0 && class_index < SIZE_CLASS_COUNT
                  nursery = ChunkHeader.nursery?(chunk)
                  @heap_size -= mapped if @heap_size >= mapped
                  @bytes_reclaimed_since_gc += mapped
                  @released_chunk_bytes += mapped
                  index_remove(chunk)
                  chunk.value.next = to_unmap
                  to_unmap = chunk
                  drop = true
                  any_drop = true
                  bit = 1_u64 << class_index
                  if nursery
                    rebuild_nursery_mask |= bit
                  else
                    rebuild_mask |= bit
                  end
                end
              end
              @size_class_chunk_count += 1 unless drop
            end
          end
        end

        unless drop
          chunk.value.next = kept
          kept = chunk
        end
        chunk = nxt
      end

      @chunks = kept

      # Queue for post-STW munmap (do not munmap while world stopped).
      if to_unmap
        # Prepend onto any leftover pending (should be empty).
        tail = to_unmap
        while !tail.value.next.null?
          tail = tail.value.next
        end
        tail.value.next = @pending_empty_chunks
        @pending_empty_chunks = to_unmap
      end

      if rebuild_mask != 0 || rebuild_nursery_mask != 0
        SIZE_CLASS_COUNT.times do |i|
          bit = 1_u64 << i
          rebuild_size_class_freelist(i, false) if (rebuild_mask & bit) != 0
          rebuild_size_class_freelist(i, true) if (rebuild_nursery_mask & bit) != 0
        end
      end

      if any_drop
        update_heap_bounds_after_unmap
      end
    end

    # Munmap size-class chunks queued during STW sweep. Call outside STW.
    # Do not invalidate the static-root maps cache here (same as the former
    # in-STW empty-chunk path): heap VMAs are excluded via the chunk index and
    # static scans use safe probing. Full maps refresh stays on the major interval.
    private def flush_pending_empty_chunks : Nil
      chunk = @pending_empty_chunks
      return if chunk.null?

      @pending_empty_chunks = Pointer(ChunkHeader).null
      while chunk
        nxt = chunk.value.next
        mapped = chunk.value.mapped_bytes
        @unmapped_bytes += mapped
        LibC.munmap(chunk.as(Void*), LibC::SizeT.new(mapped))
        chunk = nxt
      end
    end

    # Remove a fully free size-class chunk from the heap and rebuild that
    # class's freelist from remaining chunks (avoids dangling freelist links).
    # Used by explicit paths; major sweep batches empty-chunk release itself.
    private def reclaim_empty_chunk(chunk : ChunkHeader*) : Nil
      return if ChunkHeader.large?(chunk)

      class_index = chunk.value.size_class.to_i32
      return if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      nursery = ChunkHeader.nursery?(chunk)
      mapped = chunk.value.mapped_bytes
      unlink_chunk(chunk)
      @heap_size -= mapped if @heap_size >= mapped
      @unmapped_bytes += mapped
      @bytes_reclaimed_since_gc += mapped
      LibC.munmap(chunk.as(Void*), LibC::SizeT.new(mapped))
      Platform.invalidate_static_root_cache
      rebuild_size_class_freelist(class_index, nursery)
      update_heap_bounds_after_unmap
    end

    private def rebuild_size_class_freelist(class_index : Int32, nursery : Bool) : Nil
      payload = SizeClasses.payload(class_index)
      head = Pointer(Void).null

      each_chunk do |chunk|
        next if ChunkHeader.large?(chunk)
        next if chunk.value.size_class != class_index.to_u32
        next if ChunkHeader.nursery?(chunk) != nursery

        each_block(chunk) do |header|
          next unless BlockHeader.free?(header)
          user = BlockHeader.user_from(header)
          header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, head)
          head = user
        end
      end

      if nursery
        @nursery_freelists[class_index] = head
        @nursery_freelist_clean[class_index] = false
      else
        @freelists[class_index] = head
        @freelist_clean[class_index] = false
      end

      recalc_free_bytes
    end

    private def recalc_free_bytes : Nil
      total = 0_u64
      each_chunk do |chunk|
        if ChunkHeader.large?(chunk)
          header = ChunkHeader.data_start(chunk).as(BlockHeader*)
          total += header.value.size.to_u64 if BlockHeader.free?(header)
        else
          each_block(chunk) do |header|
            total += header.value.size.to_u64 if BlockHeader.free?(header)
          end
        end
      end
      @free_bytes = total
    end

    private def reclaim_small(chunk : ChunkHeader*, header : BlockHeader*, payload : UInt32 = 0_u32) : Nil
      class_index = chunk.value.size_class.to_i32
      return if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      payload = SizeClasses.payload(class_index) if payload == 0
      user = BlockHeader.user_from(header)
      was_nursery = BlockHeader.nursery?(header)
      if was_nursery
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, @nursery_freelists[class_index])
        @nursery_freelists[class_index] = user
        @nursery_freelist_clean[class_index] = false
      else
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, @freelists[class_index])
        @freelists[class_index] = user
        @freelist_clean[class_index] = false
      end

      @free_bytes += payload.to_u64
      @bytes_reclaimed_since_gc += payload.to_u64
      @live_objects -= 1 if @live_objects > 0
    end

    # Accounting only — caller unmaps / drops the chunk from @chunks.
    private def prepare_reclaim_large(chunk : ChunkHeader*, header : BlockHeader*) : Nil
      mapped = chunk.value.mapped_bytes
      payload = header.value.size.to_u64
      @heap_size -= mapped if @heap_size >= mapped
      @unmapped_bytes += mapped
      @bytes_reclaimed_since_gc += payload
      @live_objects -= 1 if @live_objects > 0
    end

    private def reclaim_large(chunk : ChunkHeader*, header : BlockHeader*) : Nil
      prepare_reclaim_large(chunk, header)
      unlink_chunk(chunk)
      update_heap_bounds_after_unmap
      LibC.munmap(chunk.as(Void*), LibC::SizeT.new(chunk.value.mapped_bytes))
    end

    private def each_block(chunk : ChunkHeader*, & : BlockHeader* ->) : Nil
      return if ChunkHeader.large?(chunk)

      class_index = chunk.value.size_class.to_i32
      return if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      payload = SizeClasses.payload(class_index)
      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      cursor = ChunkHeader.data_start(chunk).as(UInt8*)
      limit = ChunkHeader.data_end(chunk).as(UInt8*)

      while (cursor + block_bytes) <= limit
        yield cursor.as(BlockHeader*)
        cursor += block_bytes
      end
    end
  end
end
