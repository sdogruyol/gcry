require "./mark"
require "./roots"
require "./finalizer"
require "./platform/linux_roots"

module Gcry
  class Heap
    DEFAULT_GC_THRESHOLD      = 4194304_u64 # 4 MiB major
    DEFAULT_NURSERY_THRESHOLD =  524288_u64 # 512 KiB minor
    DEFAULT_INCREMENTAL_WORK  =         512

    getter collections : UInt64 = 0_u64
    getter minor_collections : UInt64 = 0_u64
    getter major_collections : UInt64 = 0_u64
    getter? enabled : Bool = true
    property gc_threshold : UInt64 = DEFAULT_GC_THRESHOLD
    # Library tests free manually — auto minor is opt-in (process GC enables it).
    property nursery_threshold : UInt64 = UInt64::MAX
    property incremental_work : Int32 = DEFAULT_INCREMENTAL_WORK
    # When true, scan writable process mappings as roots (needed as process GC).
    property scan_static_roots : Bool = false
    property nursery_enabled : Bool = true

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
    @heap_min : UInt64 = UInt64::MAX
    @heap_max : UInt64 = 0_u64
    @minor_only = false # mark filter during minor GC

    def enable : Nil
      @enabled = true
    end

    def disable : Nil
      @enabled = false
    end

    def lock_read : Nil
    end

    def unlock_read : Nil
    end

    def lock_write : Nil
    end

    def unlock_write : Nil
    end

    def stop_world : Nil
    end

    def start_world : Nil
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

    def current_thread_stack_bottom : {Void*, Void*}
      {Pointer(Void).null, @stack_bottom}
    end

    def before_collect(&block : -> Nil) : Nil
      @before_collect_callbacks << block
    end

    def push_stack(stack_top : Void*, stack_bottom : Void*) : Nil
      raise "push_stack outside of collect" unless @collecting
      Roots.scan_range(stack_top, stack_bottom) do |candidate|
        mark_candidate(candidate)
      end
    end

    def add_finalizer(object : Void*, callback : Finalizers::Callback) : Nil
      @finalizers.add(object, callback)
    end

    def add_finalizer(object : Void*, &block : Finalizers::Callback) : Nil
      add_finalizer(object, block)
    end

    def register_disappearing_link(link : Void**, object : Void* = Pointer(Void).null) : Nil
      referent = object
      if referent.null?
        referent = link.value
      end
      return if referent.null?

      if header = find_object(referent)
        referent = BlockHeader.user_from(header)
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

      unless @inc_active
        begin_incremental(scan_stack: true, roots: nil)
      end

      @collecting = true
      @incremental_marking = true
      finished = false
      begin
        mark_loop_budget(work_units)
        if @mark_stack.empty?
          sweep(major: true)
          @bytes_since_gc = 0_u64
          @nursery_alloc_bytes = 0_u64
          @collections += 1
          @major_collections += 1
          @inc_active = false
          @incremental_marking = false
          finished = true
        end
      ensure
        @collecting = false
        unless @inc_active
          @mark_stack.clear
          @incremental_marking = false
        end
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

    def find_object(pointer : Void*) : BlockHeader*?
      return nil if pointer.null?
      addr = pointer.address
      return nil if @heap_max == 0 || addr < @heap_min || addr >= @heap_max

      chunk = chunk_containing(addr)
      return nil unless chunk

      if ChunkHeader.large?(chunk)
        header = ChunkHeader.data_start(chunk).as(BlockHeader*)
        return nil if BlockHeader.free?(header)
        user = BlockHeader.user_from(header)
        finish = user.address + header.value.size
        return header if addr >= header.address && addr < finish
        return nil
      end

      class_index = chunk.value.size_class.to_i32
      return nil if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      payload = SizeClasses.payload(class_index)
      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      data_start = ChunkHeader.data_start(chunk).address
      data_end = ChunkHeader.data_end(chunk).address
      return nil if addr < data_start || addr >= data_end

      offset = addr - data_start
      max_offset = ((data_end - data_start) // block_bytes) * block_bytes
      return nil if offset >= max_offset

      block_index = offset // block_bytes
      header_addr = data_start + block_index * block_bytes
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

      if @bytes_since_gc >= @gc_threshold
        collect
      end
    end

    protected def destroy_collector : Nil
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
      @collecting = true
      @minor_only = !major
      begin
        @mark_stack.clear
        if major
          clear_all_marks
        else
          clear_nursery_marks
        end

        @before_collect_callbacks.each(&.call)
        @roots.each { |ptr| mark_candidate(ptr) }
        roots.try &.each { |ptr| mark_candidate(ptr) }

        if @scan_static_roots
          Platform.scan_static_roots do |low, high|
            each_static_range_excluding_heap(low, high) do |a, b|
              Roots.scan_range(a, b) { |candidate| mark_candidate(candidate) }
            end
          end
        end

        if scan_stack
          bottom = Fiber.current.@stack.bottom
          @stack_bottom = bottom
          Roots.scan_range(Roots.stack_pointer, bottom) do |candidate|
            mark_candidate(candidate)
          end
        end

        # Conservatively find nursery pointers from old objects (no write barrier).
        scan_old_for_nursery_pointers unless major

        mark_loop
        sweep(major: major)

        if major
          @bytes_since_gc = 0_u64
          @nursery_alloc_bytes = 0_u64
          @major_collections += 1
        else
          @nursery_alloc_bytes = 0_u64
          @minor_collections += 1
        end
        @collections += 1
      ensure
        @collecting = false
        @minor_only = false
        @mark_stack.clear
      end

      @running_finalizers = true
      begin
        @finalizers.run_pending
      ensure
        @running_finalizers = false
      end
    end

    private def begin_incremental(scan_stack : Bool, roots : Array(Void*)?) : Nil
      @collecting = true
      @incremental_marking = true
      @inc_active = true
      @minor_only = false
      begin
        @mark_stack.clear
        clear_all_marks
        @before_collect_callbacks.each(&.call)
        @roots.each { |ptr| mark_candidate(ptr) }
        roots.try &.each { |ptr| mark_candidate(ptr) }
        if @scan_static_roots
          Platform.scan_static_roots do |low, high|
            each_static_range_excluding_heap(low, high) do |a, b|
              Roots.scan_range(a, b) { |candidate| mark_candidate(candidate) }
            end
          end
        end
        if scan_stack
          bottom = Fiber.current.@stack.bottom
          @stack_bottom = bottom
          Roots.scan_range(Roots.stack_pointer, bottom) do |candidate|
            mark_candidate(candidate)
          end
        end
      ensure
        @collecting = false
      end
    end

    private def abort_incremental : Nil
      return unless @inc_active
      @inc_active = false
      @incremental_marking = false
      @mark_stack.clear
    end

    # Emit [low, high) minus each mapped heap chunk. Uses per-chunk holes so
    # fiber stacks / libc mappings that sit *between* chunks stay scannable.
    # (A single heap_min..heap_max hole would hide those and drop live roots.)
    private def each_static_range_excluding_heap(low : Void*, high : Void*, & : Void*, Void* ->) : Nil
      lo = low.address
      hi = high.address
      return if hi <= lo

      cursor = lo
      while cursor < hi
        best_lo = 0_u64
        best_hi = 0_u64
        found = false

        each_chunk do |chunk|
          c_lo = chunk.address
          c_hi = c_lo + chunk.value.mapped_bytes
          next if c_hi <= cursor || c_lo >= hi

          if !found || c_lo < best_lo
            found = true
            best_lo = c_lo
            best_hi = c_hi
          end
        end

        unless found
          yield Pointer(Void).new(cursor), Pointer(Void).new(hi)
          return
        end

        if best_lo > cursor
          yield Pointer(Void).new(cursor), Pointer(Void).new(best_lo)
        end

        cursor = best_hi > cursor ? best_hi : (cursor + 1)
      end
    end

    private def mark_candidate(pointer : Void*) : Nil
      header = find_object(pointer)
      return unless header
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
      size = header.value.size.to_u64
      word = sizeof(Void*).to_u64
      words = size // word
      cursor = user.as(UInt64*)
      words.times do |i|
        mark_candidate(Pointer(Void).new(cursor[i]))
      end
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
      size = header.value.size.to_u64
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

    private def sweep(major : Bool) : Nil
      chunk = @chunks
      while chunk
        nxt = chunk.value.next

        if major || ChunkHeader.nursery?(chunk)
          if ChunkHeader.large?(chunk)
            header = ChunkHeader.data_start(chunk).as(BlockHeader*)
            unless BlockHeader.free?(header)
              if BlockHeader.marked?(header)
                BlockHeader.clear_mark(header)
              else
                reclaim_large(chunk, header) if major
              end
            end
          else
            each_block(chunk) do |header|
              next if BlockHeader.free?(header)
              # Minor GC only reclaims/promotes nursery objects.
              next if !major && !BlockHeader.nursery?(header)

              if BlockHeader.marked?(header)
                BlockHeader.clear_mark(header)
                BlockHeader.promote(header) unless major
              else
                reclaim_small(header)
              end
            end
          end
        end

        chunk = nxt
      end
    end

    private def reclaim_small(header : BlockHeader*) : Nil
      payload = header.value.size
      user = BlockHeader.user_from(header)
      @finalizers.on_reclaim(user)

      class_index = size_class_index(payload)
      was_nursery = BlockHeader.nursery?(header)
      if was_nursery
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, @nursery_freelists[class_index])
        @nursery_freelists[class_index] = user
      else
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, @freelists[class_index])
        @freelists[class_index] = user
      end

      @free_bytes += payload.to_u64
      @live_objects -= 1 if @live_objects > 0
    end

    private def reclaim_large(chunk : ChunkHeader*, header : BlockHeader*) : Nil
      user = BlockHeader.user_from(header)
      @finalizers.on_reclaim(user)

      unlink_chunk(chunk)
      @heap_size -= chunk.value.mapped_bytes
      update_heap_bounds_after_unmap
      @live_objects -= 1 if @live_objects > 0
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

    private def chunk_containing(addr : UInt64) : ChunkHeader*?
      each_chunk do |chunk|
        base = chunk.address
        finish = base + chunk.value.mapped_bytes
        return chunk if addr >= base && addr < finish
      end
      nil
    end
  end
end
