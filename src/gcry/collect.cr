require "./mark"
require "./roots"
require "./finalizer"
require "./platform/linux_roots"

module Gcry
  class Heap
    DEFAULT_GC_THRESHOLD = 4194304_u64 # 4 MiB literal

    getter collections : UInt64 = 0_u64
    getter? enabled : Bool = true
    property gc_threshold : UInt64 = DEFAULT_GC_THRESHOLD
    # When true, scan writable process mappings as roots (needed as process GC).
    property scan_static_roots : Bool = false

    # High end of the stack (stack grows down). Null disables stack scanning.
    @stack_bottom : Void* = Pointer(Void).null
    @roots = Roots::Set.new
    @mark_stack = MarkStack.new
    @finalizers = Finalizers::Registry.new
    @before_collect_callbacks = [] of -> Nil
    @collecting = false
    @heap_min : UInt64 = UInt64::MAX
    @heap_max : UInt64 = 0_u64

    def enable : Nil
      @enabled = true
    end

    def disable : Nil
      @enabled = false
    end

    # No-op locks / STW for single-threaded MVP (`preview_mt` later).
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

    # Compatible with Crystal's `GC.current_thread_stack_bottom`.
    def current_thread_stack_bottom : {Void*, Void*}
      {Pointer(Void).null, @stack_bottom}
    end

    # Register a callback invoked at the start of each collection (fiber roots).
    # Callbacks should call `#push_stack` for suspended fiber stacks.
    def before_collect(&block : -> Nil) : Nil
      @before_collect_callbacks << block
    end

    # Conservatively scan a suspended fiber (or other) stack range into the
    # mark queue. Must be called from a `#before_collect` callback (or while
    # `@collecting` is already true).
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

    # When *object* is collected, `*link` is set to null (Boehm / WeakRef semantics).
    def register_disappearing_link(link : Void**, object : Void* = Pointer(Void).null) : Nil
      referent = object
      if referent.null?
        referent = link.value
      end
      return if referent.null?

      # Prefer the object's base user pointer when we can resolve it.
      if header = find_object(referent)
        referent = BlockHeader.user_from(header)
      end
      @finalizers.register_disappearing_link(link, referent)
    end

    # True if *pointer* refers to a live (allocated, not free) object.
    def live?(pointer : Void*) : Bool
      return false if pointer.null?
      header = find_object(pointer)
      return false unless header
      !BlockHeader.free?(header)
    end

    # Run a full stop-the-world conservative mark–sweep collection.
    #
    # When `scan_stack` is true and `stack_bottom` is set, the C stack between
    # the current frame and `stack_bottom` is scanned. Explicit roots always
    # participate. `#before_collect` callbacks run next (fiber `push_stack`).
    # Extra *roots* are marked as well (handy for tests).
    def collect(scan_stack : Bool = true, roots : Array(Void*)? = nil) : Nil
      return if @destroyed
      return if @collecting

      @collecting = true
      begin
        @mark_stack.clear
        clear_all_marks

        # Fiber / custom roots first (may call push_stack).
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

        if scan_stack && !@stack_bottom.null?
          Roots.scan_range(Roots.stack_pointer, @stack_bottom) do |candidate|
            mark_candidate(candidate)
          end
        end

        mark_loop
        sweep
        @bytes_since_gc = 0_u64
        @collections += 1
      ensure
        @collecting = false
        @mark_stack.clear
      end

      # Finalizers run after the heap is consistent again (may allocate).
      @finalizers.run_pending
    end

    # Resolve a conservative pointer to a live block header, if any.
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
      collect if @bytes_since_gc >= @gc_threshold
    end

    protected def destroy_collector : Nil
      @roots.clear
      @mark_stack.destroy
      @finalizers.clear
      @before_collect_callbacks.clear
      @heap_min = UInt64::MAX
      @heap_max = 0_u64
      @collections = 0_u64
      @stack_bottom = Pointer(Void).null
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

    private def each_static_range_excluding_heap(low : Void*, high : Void*, & : Void*, Void* ->) : Nil
      lo = low.address
      hi = high.address
      return if hi <= lo

      # Do not scan the managed heap itself as roots (would retain everything).
      if @heap_max > @heap_min && lo < @heap_max && hi > @heap_min
        yield Pointer(Void).new(lo), Pointer(Void).new(@heap_min) if lo < @heap_min
        yield Pointer(Void).new(@heap_max), Pointer(Void).new(hi) if hi > @heap_max
      else
        yield low, high
      end
    end

    private def mark_candidate(pointer : Void*) : Nil
      header = find_object(pointer)
      return unless header
      return if BlockHeader.marked?(header)

      BlockHeader.set_mark(header)
      @mark_stack.push(header)
    end

    private def mark_loop : Nil
      until @mark_stack.empty?
        header = @mark_stack.pop
        scan_object(header)
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

    private def clear_all_marks : Nil
      each_chunk do |chunk|
        each_block(chunk) do |header|
          next if BlockHeader.free?(header)
          BlockHeader.clear_mark(header)
        end
      end
    end

    private def sweep : Nil
      chunk = @chunks
      while chunk
        nxt = chunk.value.next

        if ChunkHeader.large?(chunk)
          header = ChunkHeader.data_start(chunk).as(BlockHeader*)
          unless BlockHeader.free?(header)
            if BlockHeader.marked?(header)
              BlockHeader.clear_mark(header)
            else
              reclaim_large(chunk, header)
            end
          end
        else
          each_block(chunk) do |header|
            next if BlockHeader.free?(header)
            if BlockHeader.marked?(header)
              BlockHeader.clear_mark(header)
            else
              reclaim_small(header)
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
      header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, @freelists[class_index])
      @freelists[class_index] = user

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
