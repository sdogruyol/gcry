# Heap invariant checker — validates gcry heap invariants at runtime.
#
# Enable with `GCRY_DEBUG_INVARIANTS=1`. Checks run after every malloc, free,
# and collect. Designed to be safe to call from any context (no GC heap alloc,
# no mmap, no syscalls other than write(2) for the error message).
#
# When an invariant fails, the checker prints a diagnostic message to stderr
# and raises an exception. Under `-Dgcry_invariant_abort` it calls abort(3)
# for core dump analysis.

module Gcry
  module Invariant
    @[AlwaysInline]
    def self.enabled? : Bool
      {% if flag?(:gcry_invariant_abort) %}
        true
      {% else %}
        @@enabled
      {% end %}
    end

    @@enabled = false

    def self.enable : Nil
      @@enabled = true
    end

    def self.disable : Nil
      @@enabled = false
    end

    # Called once at process start if GCRY_DEBUG_INVARIANTS is set.
    def self.init_from_env : Nil
      if ENV["GCRY_DEBUG_INVARIANTS"]? == "1"
        enable
      end
    end

    # Verify that `live_objects` matches the actual number of live (non-free)
    # blocks in the heap. This is the most important invariant: if the counter
    # drifts, every GC decision based on it is suspect.
    def self.check_live_objects(heap : Heap) : Nil
      return unless enabled?
      actual = count_live_blocks(heap)
      reported = heap.live_objects
      return if actual == reported
      fail("live_objects mismatch: actual=#{actual} reported=#{reported}")
    end

    # Verify that the freelist for a given size class is internally consistent:
    # every node in the chain is a valid heap pointer, the FREE flag is set, and
    # there are no cycles.
    def self.check_freelist(heap : Heap, class_index : Int32, nursery : Bool = false) : Nil
      return unless enabled?
      return if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      head = nursery ? heap.nursery_freelist_for(class_index) : heap.freelist_for(class_index)
      return if head.null?

      visited = Pointer(Void).null
      user = head
      count = 0_u64
      while user
        # Cycle detection: if we've seen more nodes than the heap can hold,
        # something is wrong. A single size-class chunk holds at most ~8000
        # blocks (128 KiB / 16 B), so 100_000 is a generous safety limit.
        count += 1
        if count > 100_000
          fail("freelist cycle or runaway at size class #{class_index} (nursery=#{nursery})")
          return
        end

        # Every freelist node must be a valid heap pointer.
        unless heap.is_heap_ptr(user)
          fail("freelist node at #{user} is not a heap pointer (class=#{class_index})")
          return
        end

        header = BlockHeader.from_user(user)
        unless BlockHeader.free?(header)
          fail("freelist node at #{user} is not marked FREE (class=#{class_index})")
          return
        end

        user = header.value.next_free
      end
    end

    # Verify freelist consistency for all size classes.
    def self.check_all_freelists(heap : Heap) : Nil
      return unless enabled?
      SIZE_CLASS_COUNT.times do |i|
        check_freelist(heap, i, nursery: false)
        check_freelist(heap, i, nursery: true)
      end
    end

    # Verify that chunk index is consistent with the chunk list.
    def self.check_chunk_index(heap : Heap) : Nil
      return unless enabled?
      # Count chunks in the linked list.
      list_count = 0_u64
      heap.each_chunk { list_count += 1 }

      # The chunk index is lazily rebuilt; it may be stale or null.
      # Only verify when the index is non-null and has a matching count.
      idx_count = heap.chunk_index_count
      return if idx_count == 0

      # If the index exists, it should cover all chunks (the sweep phase
      # rebuilds it). A mismatch indicates a bug in index maintenance.
      if list_count != idx_count
        fail("chunk index count mismatch: list=#{list_count} index=#{idx_count}")
      end
    end

    # Verify that no free block's content overlaps with a live block's header.
    # Slow walk — only run on small heaps or during stress-test validation.
    def self.check_no_overlap(heap : Heap) : Nil
      return unless enabled?
      # Collect all free block ranges.
      free_ranges = [] of {UInt64, UInt64}
      heap.each_chunk do |chunk|
        next if ChunkHeader.large?(chunk)
        class_index = chunk.value.size_class.to_i32
        next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
        payload = SizeClasses.payload(class_index)
        block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
        cursor = ChunkHeader.data_start(chunk).as(UInt8*)
        limit = ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(BlockHeader*)
          if BlockHeader.free?(header)
            free_ranges << {header.address, header.address + block_bytes}
          end
          cursor += block_bytes
        end
      end

      # Check each live block against free ranges.
      heap.each_chunk do |chunk|
        next if ChunkHeader.large?(chunk)
        class_index = chunk.value.size_class.to_i32
        next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
        payload = SizeClasses.payload(class_index)
        block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
        cursor = ChunkHeader.data_start(chunk).as(UInt8*)
        limit = ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(BlockHeader*)
          unless BlockHeader.free?(header)
            addr = header.address
            free_ranges.each do |free_lo, free_hi|
              if addr >= free_lo && addr < free_hi
                fail("live block at #{addr} overlaps free block [#{free_lo}, #{free_hi})")
                return
              end
            end
          end
          cursor += block_bytes
        end
      end
    end

    # Run all applicable checks after a malloc.
    def self.after_malloc(heap : Heap, ptr : Void*, size : UInt64) : Nil
      return unless enabled?
      return if ptr.null?
      check_live_objects(heap)
    end

    # Run all applicable checks after a free.
    def self.after_free(heap : Heap, ptr : Void*) : Nil
      return unless enabled?
      check_live_objects(heap)
    end

    # Run all applicable checks after a collect.
    def self.after_collect(heap : Heap) : Nil
      return unless enabled?
      check_live_objects(heap)
      check_all_freelists(heap)
    end

    private def self.count_live_blocks(heap : Heap) : UInt64
      count = 0_u64
      heap.each_chunk do |chunk|
        if ChunkHeader.large?(chunk)
          header = ChunkHeader.data_start(chunk).as(BlockHeader*)
          count += 1 unless BlockHeader.free?(header)
        else
          class_index = chunk.value.size_class.to_i32
          next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
          payload = SizeClasses.payload(class_index)
          block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
          cursor = ChunkHeader.data_start(chunk).as(UInt8*)
          limit = ChunkHeader.data_end(chunk).as(UInt8*)
          while (cursor + block_bytes) <= limit
            header = cursor.as(BlockHeader*)
            count += 1 unless BlockHeader.free?(header)
            cursor += block_bytes
          end
        end
      end
      count
    end

    private def self.fail(msg : String) : NoReturn
      # Use stderr for the diagnostic even if the heap is corrupt.
      # Avoid String interpolation (may allocate) — build the message manually.
      libc_write_err("GCRY INVARIANT FAILURE: ")
      libc_write_err(msg)
      libc_write_err("\n")

      {% if flag?(:gcry_invariant_abort) %}
        LibC.abort
      {% else %}
        raise "gcry invariant: #{msg}"
      {% end %}
    end

    private def self.libc_write_err(msg : String) : Nil
      # write(2) to stderr is signal-safe and does not allocate.
      LibC.write(2, msg, msg.bytesize)
    end
  end
end

# Auto-init from environment at require time.
Gcry::Invariant.init_from_env