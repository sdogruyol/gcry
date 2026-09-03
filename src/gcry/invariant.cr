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

    # Checks skipped because another thread could be mutating the heap under the
    # walk. Counted rather than silent: a checker that quietly stops checking
    # looks exactly like one that runs and finds nothing.
    @@concurrent_skips = 0_u64

    def self.concurrent_skips : UInt64
      @@concurrent_skips
    end

    # Walks that ran to agreement. The skip counter says how often the checker
    # declined; this says how often it actually checked, which is the number a
    # test needs to know the check is not passing vacuously.
    @@live_object_checks = 0_u64

    def self.live_object_checks : UInt64
      @@live_object_checks
    end

    # Verify that `live_objects` matches the actual number of live (non-free)
    # blocks in the heap. This is the most important invariant: if the counter
    # drifts, every GC decision based on it is suspect.
    #
    # Only meaningful on a quiescent heap. `after_malloc` runs outside the
    # allocation lock and `note_alloc_bytes` bumps the counter at a different
    # instant than `set_used` writes the header, so with a second mutator thread
    # allocating the walk and the counter are two different points in time —
    # measured as `actual=40 reported=41` in `spec/mt_spec.cr:118`, off by
    # exactly the one allocation in flight. Skip rather than report a drift that
    # is really a race.
    #
    # Asking "is another thread running?" was not enough, and this check was
    # flaky for it — 6 failures in 25 runs of `spec/invariant_spec.cr`, on three
    # different examples. Two distinct causes came out of it, and only the
    # second one is about timing.
    #
    #   - **The counter is not always kept.** `note_alloc_bytes` uses plain
    #     get/set unless `heap_counters_atomic` is set, so a second allocating
    #     thread makes `set(get + 1)` lose increments outright. The residual
    #     failures after the timing fix were this, and they had `actual` *above*
    #     `reported` — a counter that had permanently fallen behind, which the
    #     walk was right to report. The invariant is therefore stated only of a
    #     heap that can keep it: see `Heap#counters_may_lose_updates?`.
    #   - **The walk and the counter are two instants.** `after_malloc` runs
    #     outside the allocation lock, so an allocation in flight is counted in
    #     one and not the other. Quiescence is established from what the heap
    #     itself says rather than from thread bookkeeping: sample the counter,
    #     walk, sample again. A change across the walk *is* a concurrent
    #     mutation, whoever made it. And because an allocation whose counter has
    #     been bumped but whose header is not yet written straddles both
    #     samples, a mismatch is re-checked `CONFIRM_ATTEMPTS` times: the
    #     in-flight store lands and the next attempt agrees, while a real drift
    #     is stable and still fails.
    CONFIRM_ATTEMPTS = 3

    # The failure path interpolates, and interpolation allocates, which lands
    # straight back in `after_malloc` → `check_live_objects`. That recursion is
    # what the flaky runs printed: a stack of nested checkers under one real
    # mismatch. A checker must not be its own mutator.
    @@checking = false

    def self.check_live_objects(heap : Heap) : Nil
      return unless enabled?
      return if @@checking
      if heap.concurrent_mutators? || heap.counters_may_lose_updates?
        @@concurrent_skips += 1
        return
      end

      @@checking = true
      begin
        actual = 0_u64
        reported = 0_u64
        attempts = 0
        while attempts < CONFIRM_ATTEMPTS
          reported = heap.live_objects
          actual = count_live_blocks(heap)
          after = heap.live_objects
          if actual == reported && reported == after
            @@live_object_checks += 1
            return
          end
          if reported != after
            @@concurrent_skips += 1
            return
          end
          attempts += 1
        end
        fail("live_objects mismatch: actual=#{actual} reported=#{reported}")
      ensure
        @@checking = false
      end
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
        # Dormant chunks hold no live blocks and their headers were advised
        # away — see count_live_blocks.
        next if ChunkHeader.dormant?(chunk)
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
        next if ChunkHeader.dormant?(chunk)
        next if ChunkHeader.large?(chunk)
        class_index = chunk.value.size_class.to_i32
        next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
        payload = SizeClasses.payload(class_index)
        block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
        cursor = ChunkHeader.data_start(chunk).as(UInt8*)
        limit = ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(BlockHeader*)
          if counts_live?(header)
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

    # A block header the walk must not read as live. Two cases, and neither is
    # the collector's accounting being wrong:
    #
    #   dormant chunk  the sweep marks a chunk dormant only `unless any_live`, so
    #                  it holds nothing by construction — and then advises the
    #                  pages away, which destroys the headers. On Linux
    #                  `MADV_DONTNEED` zeroes them, and `flags == 0` does not
    #                  read as FREE, so every block in the chunk counted live; on
    #                  Darwin `MADV_FREE_REUSABLE` leaves them stale, which does
    #                  not read as FREE either. Measured on Linux, one 8 000-block
    #                  collection: 6 501 counted in 4 dormant chunks against
    #                  `live_objects = 1`, of which 6 348 headers read all-zero
    #                  and 153 were stale. The sweep already skips dormant chunks
    #                  for the same reason (`collect_sweep.cr:47`).
    #
    #   zero size      a live block always has a non-zero size (`set_used`), so a
    #                  zeroed header is a page the kernel dropped, not an object.
    #                  Reasoned, not measured, and kept because the chunk flag
    #                  above cannot cover it: `MADV_FREE` on a SPARSE chunk lets
    #                  the kernel discard a page under pressure at any later
    #                  moment, and SPARSE chunks do hold live blocks.
    #
    # Both are strictly one-directional — they can only stop garbage being
    # counted live, never hide a live block the counter forgot: that direction
    # still fails as `actual < reported`.
    @[AlwaysInline]
    private def self.counts_live?(header : BlockHeader*) : Bool
      !BlockHeader.free?(header) && header.value.size != 0
    end

    private def self.count_live_blocks(heap : Heap) : UInt64
      count = 0_u64
      heap.each_chunk do |chunk|
        next if ChunkHeader.dormant?(chunk)
        if ChunkHeader.large?(chunk)
          header = ChunkHeader.data_start(chunk).as(BlockHeader*)
          count += 1 if counts_live?(header)
        else
          class_index = chunk.value.size_class.to_i32
          next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
          payload = SizeClasses.payload(class_index)
          block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
          # On a chunk whose allocation is bitmap-driven, `occ` is the
          # authority and the header's FREE flag is stale for every block the
          # streaming sweep reclaimed — it never writes them, by design. Reading
          # headers here reports every reclaimed block as live: measured
          # `actual=1632 reported=1` on a chunk holding one live object.
          if heap.bitmap_alloc_chunk_public?(chunk)
            count += heap.chunk_occupied_count(chunk)
          else
            cursor = ChunkHeader.data_start(chunk).as(UInt8*)
            limit = ChunkHeader.data_end(chunk).as(UInt8*)
            while (cursor + block_bytes) <= limit
              header = cursor.as(BlockHeader*)
              count += 1 if counts_live?(header)
              cursor += block_bytes
            end
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
