# Sweep phase: reclaim, empty-chunk release, dormant/madvise, freelists.

module Gcry
  class Heap
    private def sweep(major : Bool, after_world : Bool = false) : Nil
      # Rebuild the chunk list in one pass. Reclaiming large objects used to
      # unlink + dirty the chunk index per object; every following reclaim_small
      # then rebuilt/sorted the index (O(n²) insertion sort) — that made sweep
      # multi-second on HTTP apps with many large allocs (see unmapped_bytes).
      #
      # after_world (lazy sweep): mutators are running; take per-class freelist /
      # alloc locks around reclaim. Do not relink `@chunks` (would race
      # map_chunk). Munmap empty-reclaim / HOLED rebuild stay in-STW only.
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
        @size_class_live_bytes = 0_u64
        @chunk_fill_lt25 = 0_u64
        @chunk_fill_lt50 = 0_u64
        @chunk_fill_lt75 = 0_u64
        @chunk_fill_ge75 = 0_u64
        @dormant_chunk_bytes = 0_u64
        @dontneed_bytes = 0_u64
        @mostly_empty_bytes = 0_u64
        @mostly_empty_chunks = 0_u64
        @sweep_dormant_skips = 0_u64
      end

      # Bytes of empty chunks kept warm / dormant this major (retain budgets).
      warm_budget_used = 0_u64
      dormant_budget_used = 0_u64

      chunk = @chunks
      while chunk
        nxt = chunk.value.next
        drop = false

        # Already-dormant empties: skip O(blocks) walk; recount retain budget.
        if !ChunkHeader.large?(chunk) && (major || ChunkHeader.nursery?(chunk)) &&
           ChunkHeader.dormant?(chunk)
          if major
            mapped = chunk.value.mapped_bytes
            @fully_free_chunk_bytes += mapped
            @dormant_chunk_bytes += mapped
            dormant_budget_used += mapped
            @sweep_dormant_skips += 1
            @size_class_chunk_count += 1
            note_chunk_fill(0_u64, 1_u64)
          end
          if !after_world || relink_chunks_after_world?
            chunk.value.next = kept
            kept = chunk
          end
          chunk = nxt
          next
        end

        if major || ChunkHeader.nursery?(chunk)
          if ChunkHeader.large?(chunk)
            if after_world
              with_alloc_lock { sweep_large_one(chunk, major) }
            else
              sweep_large_one(chunk, major)
            end
          else
            # Inline size-class sweep — avoid each_block yield overhead on
            # multi-million block heaps (dominated phase_sweep under HTTP).
            class_index = chunk.value.size_class.to_i32
            any_live = false
            live_payload = 0_u64
            usable_payload = 0_u64
            # FREE payload on a fully-dead chunk (munmap free_bytes_sub).
            free_payload = 0_u64
            fl_locked = false
            if after_world && class_index >= 0 && class_index < SIZE_CLASS_COUNT
              freelist_lock_ptr(class_index, ChunkHeader.nursery?(chunk)).value.lock
              fl_locked = true
            end
            begin
              if class_index >= 0 && class_index < SIZE_CLASS_COUNT
                payload = SizeClasses.payload(class_index)
                block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
                cursor = ChunkHeader.data_start(chunk).as(UInt8*)
                limit = ChunkHeader.data_end(chunk).as(UInt8*)
                # When releasing empties: discover live first so fully-dead chunks
                # skip freelist link (unlink-only for pre-existing free blocks).
                defer_reclaim = major && release_empty_chunks_this_collect?
                if defer_reclaim
                  # Count unmarked USED + FREE payload in the discover pass so
                  # fully-dead chunks skip a second O(blocks) walk.
                  dead = 0_u64
                  while (cursor + block_bytes) <= limit
                    usable_payload += payload.to_u64
                    header = cursor.as(BlockHeader*)
                    if BlockHeader.free?(header)
                      free_payload &+= payload.to_u64
                      # FREE + marked: mid-alloc claimed from a stack root.
                      if heap_marked?(header)
                        any_live = true
                        live_payload += payload.to_u64
                      end
                    else
                      if heap_marked?(header)
                        any_live = true
                        live_payload += payload.to_u64
                      else
                        dead &+= 1
                      end
                    end
                    cursor += block_bytes
                  end
                  if any_live
                    cursor = ChunkHeader.data_start(chunk).as(UInt8*)
                    while (cursor + block_bytes) <= limit
                      header = cursor.as(BlockHeader*)
                      unless BlockHeader.free?(header)
                        if heap_marked?(header)
                          heap_clear_mark(header)
                        else
                          reclaim_small(chunk, header, payload)
                        end
                      end
                      cursor += block_bytes
                    end
                  else
                    # Fully-dead chunk: batch the live_objects accounting (one
                    # store under STW) instead of a CAS per block.
                    live_objects_sub(dead)
                  end
                else
                  while (cursor + block_bytes) <= limit
                    usable_payload += payload.to_u64 if major
                    header = cursor.as(BlockHeader*)
                    unless BlockHeader.free?(header)
                      if major || BlockHeader.nursery?(header)
                        if heap_marked?(header)
                          heap_clear_mark(header)
                          BlockHeader.promote(header) unless major
                          unless major
                            @nursery_survival_bytes += payload.to_u64
                          end
                          any_live = true
                          live_payload += payload.to_u64 if major
                        else
                          reclaim_small(chunk, header, payload)
                        end
                      else
                        any_live = true
                        live_payload += payload.to_u64 if major
                      end
                    end
                    cursor += block_bytes
                  end
                end
              else
                any_live = true
              end

              if major
                @size_class_live_bytes += live_payload
                unless any_live
                  mapped = chunk.value.mapped_bytes
                  @fully_free_chunk_bytes += mapped
                  ChunkHeader.set_holed(chunk, false)
                  ChunkHeader.set_sparse(chunk, false)
                  if release_empty_chunks_this_collect? && class_index >= 0 && class_index < SIZE_CLASS_COUNT
                    # Priority: warm (mapped) → dormant (DONTNEED) → munmap.
                    # Warm retain is the thr middle path vs KEEP_CHUNKS (RSS tax
                    # without page-fault on reuse). Unbounded Parallel dormant
                    # remains opt-in via parallel_empty_chunk_dormant_all.
                    within_warm = @empty_chunk_warm_retain > 0 &&
                                  (warm_budget_used + mapped <= @empty_chunk_warm_retain)
                    within_retain = @empty_chunk_retain > 0 &&
                                    (dormant_budget_used + mapped <= @empty_chunk_retain)
                    can_dormant = within_retain ||
                                  (!munmap_empty_chunks_this_collect? && @parallel_empty_chunk_dormant_all && @empty_chunk_retain > 0)
                    # Drop freelist nodes via one rebuild_size_class_freelist per
                    # class at end of sweep (rebuild skips DORMANT / dropped
                    # chunks). Per-empty unlink_freelist_range was O(freelist ×
                    # empties) and dominated phase_sweep under HTTP churn.
                    bit = 1_u64 << class_index
                    if within_warm
                      # Warm: keep pages mapped; freelist dead blocks (defer path
                      # left them USED after live_objects_sub).
                      p = SizeClasses.payload(class_index)
                      bb = BlockHeader::SIZE.to_u64 + p.to_u64
                      freelist_reserve_fully_dead(chunk, class_index, p, bb)
                      warm_budget_used += mapped
                    elsif can_dormant
                      # Dormant: DONTNEED RSS, keep VA in chunk index (safe under
                      # Parallel — munmap was the soft-realloc amplifier).
                      ChunkHeader.set_dormant(chunk, true)
                      dormant_budget_used += mapped
                      @dormant_chunk_bytes += mapped
                      if ChunkHeader.nursery?(chunk)
                        rebuild_nursery_mask |= bit
                      else
                        rebuild_mask |= bit
                      end
                    elsif munmap_empty_chunks_this_collect?
                      # Queue for post-STW flush. Parallel lazy disables this
                      # path (`sweep_after_world?`); EC1 lazy allows it and
                      # rebuilds `@chunks` under `@block_other_heap`.
                      # Drop FREE bytes that leave the heap (reclaim_small /
                      # freelist_reserve already adjust; skip full recalc).
                      free_bytes_sub(free_payload) if free_payload > 0
                      @heap_size -= mapped if @heap_size >= mapped
                      @bytes_reclaimed_since_gc += mapped
                      @released_chunk_bytes += mapped
                      if ChunkHeader.nursery?(chunk)
                        rebuild_nursery_mask |= bit
                      else
                        rebuild_mask |= bit
                      end
                      index_remove(chunk)
                      if @tight_grow && @grow_lo[class_index] == ChunkHeader.data_start(chunk).address
                        @grow_lo[class_index] = 0_u64
                        @grow_hi[class_index] = 0_u64
                        @prefer_freelists[class_index] = Pointer(Void).null
                      end
                      chunk.value.next = to_unmap
                      to_unmap = chunk
                      drop = true
                      any_drop = true
                    else
                      # Parallel bounded excess: no DONTNEED budget, no munmap.
                      # defer_reclaim left dead blocks USED after live_objects_sub —
                      # link them onto the freelist without a second live_objects_dec.
                      p = SizeClasses.payload(class_index)
                      bb = BlockHeader::SIZE.to_u64 + p.to_u64
                      freelist_reserve_fully_dead(chunk, class_index, p, bb)
                    end
                  elsif ChunkHeader.dormant?(chunk)
                    # release off: clear stale dormant from a prior process config.
                    ChunkHeader.set_dormant(chunk, false)
                  end
                else
                  ChunkHeader.set_dormant(chunk, false) if ChunkHeader.dormant?(chunk)
                  # Free-page physical release: detect free pages in STW, set HOLED
                  # flag; actual madvise runs post-STW in flush_pending_page_release.
                  if @madvise_free_pages && class_index >= 0 && class_index < SIZE_CLASS_COUNT &&
                     usable_payload > 0 && live_payload < usable_payload
                    ChunkHeader.set_holed(chunk, true)
                    ChunkHeader.set_sparse(chunk, false)
                    bit = 1_u64 << class_index
                    if ChunkHeader.nursery?(chunk)
                      rebuild_nursery_mask |= bit
                    else
                      rebuild_mask |= bit
                    end
                  else
                    ChunkHeader.set_holed(chunk, false)
                    # Mostly-empty (HOLED-less): high-free-ratio non-empty chunks.
                    # Post-STW MADV_FREE by default — freelist stays valid (no rebuild).
                    # Exclusive with HOLED / madvise_free_pages.
                    if @mostly_empty_release && !@madvise_free_pages &&
                       class_index >= 0 && class_index < SIZE_CLASS_COUNT &&
                       usable_payload > 0 &&
                       live_payload * 100 <= usable_payload * @mostly_empty_max_live_pct.to_u64
                      ChunkHeader.set_sparse(chunk, true)
                    else
                      ChunkHeader.set_sparse(chunk, false)
                    end
                  end
                end
                unless drop
                  @size_class_chunk_count += 1
                  note_chunk_fill(live_payload, usable_payload)
                end
              end
            ensure
              if fl_locked
                freelist_lock_ptr(class_index, ChunkHeader.nursery?(chunk)).value.unlock
              end
            end
          end
        end

        unless drop
          # Parallel lazy: leave `@chunks` alone (map_chunk may prepend).
          # EC1 lazy: rebuild like in-STW so munmap drops are unlinked.
          if !after_world || relink_chunks_after_world?
            chunk.value.next = kept
            kept = chunk
          end
        end
        chunk = nxt
      end

      if !after_world || relink_chunks_after_world?
        @chunks = kept
      end

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

      # Page-HOLED + empty dormant/munmap: one freelist rebuild per touched class.
      if rebuild_mask != 0 || rebuild_nursery_mask != 0
        SIZE_CLASS_COUNT.times do |i|
          bit = 1_u64 << i
          if (rebuild_mask & bit) != 0
            if after_world
              with_freelist_lock(i, false) { rebuild_size_class_freelist(i, false, recalc: false) }
            else
              rebuild_size_class_freelist(i, false, recalc: false)
            end
          end
          if (rebuild_nursery_mask & bit) != 0
            if after_world
              with_freelist_lock(i, true) { rebuild_size_class_freelist(i, true, recalc: false) }
            else
              rebuild_size_class_freelist(i, true, recalc: false)
            end
          end
        end
        # No recalc_free_bytes: reclaim_small / freelist_reserve / large cache
        # and munmap free_payload_sub keep @free_bytes coherent. Full-heap
        # recalc was an extra O(blocks) walk after every empty/HOLED rebuild.
      end

      if any_drop
        update_heap_bounds_after_unmap
      end
    end

    private def sweep_large_one(chunk : ChunkHeader*, major : Bool) : Nil
      header = ChunkHeader.data_start(chunk).as(BlockHeader*)
      return if BlockHeader.free?(header)
      if heap_marked?(header)
        heap_clear_mark(header)
      elsif major
        # Recycle mapping — never munmap inside STW (Linux VMA munmap
        # of thousands of large HTTP buffers dominated pause time).
        mapped = chunk.value.mapped_bytes
        cache_large_chunk(chunk, header)
        @bytes_reclaimed_since_gc += mapped
        live_objects_dec
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

      # The pending list is built by sweep in heap-walk order, so addresses
      # are already mostly monotonically increasing. Find the longest
      # monotonically-non-decreasing prefix and merge it into single munmap
      # regions (one syscall + one VMA teardown per run instead of one per
      # chunk). When a run coalesces multiple chunks into one munmap, the
      # previously-released `@unmapped_bytes` total is bumped by the full
      # run length here (it was NOT bumped in sweep — sweep only logs the
      # chunk-release decision; the actual VMA teardown happens in flush).
      while chunk
        run_base = chunk.as(Void*).address
        run_end = run_base + chunk.value.mapped_bytes
        nxt = chunk.value.next
        # Coalesce ONLY fully-contiguous chunks (next.base == current end).
        # Two chunks whose [base, base+mapped) ranges touch exactly can be
        # unmapped as a single region; anything with a gap (even a 4 KiB
        # page) must be a separate munmap — overlapping or with a gap means
        # the kernel placed some other VMA between them and a single
        # munmap would unmap unintended pages.
        while nxt && nxt.as(Void*).address == run_end
          new_end = nxt.as(Void*).address + nxt.value.mapped_bytes
          run_end = new_end if new_end > run_end
          chunk = nxt
          nxt = nxt.value.next
        end
        run_total = (run_end - run_base).to_u64
        @unmapped_bytes += run_total
        unless guard_release(run_base, run_total, GUARD_KIND_EMPTY_CHUNK)
          LibC.munmap(Pointer(Void).new(run_base), LibC::SizeT.new(run_total))
        end
        chunk = nxt
      end
    end

    # Apply MADV_FREE / DONTNEED to dormant chunks after STW.
    # Walks @chunks; dormant chunks stay in the chunk list but their
    # physical pages are released outside STW (kernel VM lock avoided).
    # Coalesces contiguous dormant ranges into a single madvise.
    private def flush_pending_dormant_chunks : Nil
      return if @dormant_chunk_bytes == 0

      data_lo = UInt64::MAX
      data_hi = 0_u64
      page = Platform.host_page_size

      each_chunk do |chunk|
        next unless ChunkHeader.dormant?(chunk)
        base = ChunkHeader.data_start(chunk).address
        finish = base + chunk.value.mapped_bytes
        start_page = (base + page - 1) & ~(page - 1)
        end_page = finish & ~(page - 1)
        if start_page < end_page
          if data_hi == start_page
            data_hi = end_page
          else
            if data_hi > data_lo
              Platform.release_physical_pages(data_lo, data_hi - data_lo)
              @dontneed_bytes += data_hi - data_lo
            end
            data_lo = start_page
            data_hi = end_page
          end
        end
      end
      if data_hi > data_lo
        Platform.release_physical_pages(data_lo, data_hi - data_lo)
        @dontneed_bytes += data_hi - data_lo
      end
    end

    # Apply per-chunk free-page madvise to HOLED chunks after STW.
    # On Darwin where MADV_FREE_REUSABLE preserves page content, walks ALL
    # kept size-class chunks (not just HOLED) for more aggressive RSS recovery.
    # Safe because the live-mask computation correctly identifies free pages
    # regardless of HOLED; MADV_FREE_REUSABLE on Darwin does not zero headers.
    private def flush_pending_page_release_chunks : Nil
      {% if flag?(:darwin) %}
        each_chunk do |chunk|
          next if ChunkHeader.large?(chunk)
          next if ChunkHeader.dormant?(chunk)
          class_index = chunk.value.size_class.to_i32
          next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
          release_free_pages_in_chunk(chunk, SizeClasses.payload(class_index), preserve_content: false)
        end
      {% else %}
        each_chunk do |chunk|
          next unless ChunkHeader.holed?(chunk)
          next if ChunkHeader.large?(chunk)
          class_index = chunk.value.size_class.to_i32
          next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
          release_free_pages_in_chunk(chunk, SizeClasses.payload(class_index), preserve_content: false)
        end
      {% end %}
    end

    # Mostly-empty flush: free pages in SPARSE chunks, no HOLED freelist rebuild.
    # Default MADV_FREE keeps freelist words valid. Opt-in dontneed mode unlinks
    # freelist nodes in free-only page runs then MADV_DONTNEED (churn risk).
    private def flush_pending_mostly_empty_chunks : Nil
      return unless @mostly_empty_release
      return if @madvise_free_pages

      budget = @mostly_empty_budget
      budget_left = budget == 0 ? UInt64::MAX : budget
      preserve = !@mostly_empty_dontneed

      each_chunk do |chunk|
        next unless ChunkHeader.sparse?(chunk)
        ChunkHeader.set_sparse(chunk, false)
        next if ChunkHeader.large?(chunk)
        next if ChunkHeader.dormant?(chunk)
        class_index = chunk.value.size_class.to_i32
        next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
        break if budget_left == 0

        payload = SizeClasses.payload(class_index)
        nursery = ChunkHeader.nursery?(chunk)
        before = @dontneed_bytes
        if @mostly_empty_dontneed
          unlink_free_only_page_runs(chunk, class_index, nursery, payload)
        end
        if release_free_pages_in_chunk(chunk, payload, preserve_content: preserve)
          gained = @dontneed_bytes - before
          if gained > budget_left
            # Counters already include full run; budget is best-effort cap on
            # further chunks this major.
            budget_left = 0
          else
            budget_left -= gained
          end
          @mostly_empty_bytes += gained
          @mostly_empty_chunks += 1
        end
      end
    end

    # Drop freelist nodes whose user pointer lies in free-only page runs of
    # *chunk*, then leave those pages eligible for MADV_DONTNEED. No class-wide
    # rebuild (unlike HOLED).
    private def unlink_free_only_page_runs(chunk : ChunkHeader*, class_index : Int32, nursery : Bool, payload : UInt32) : Nil
      page = Platform.host_page_size
      data0 = ChunkHeader.data_start(chunk).address
      data1 = ChunkHeader.data_end(chunk).address
      return if data1 <= data0

      first_page = data0 & ~(page - 1)
      last_page = (data1 - 1) & ~(page - 1)
      n_pages = ((last_page - first_page) // page) + 1
      return if n_pages == 0 || n_pages > 64

      live_mask = 0_u64
      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      cursor = ChunkHeader.data_start(chunk).as(UInt8*)
      limit = ChunkHeader.data_end(chunk).as(UInt8*)
      while (cursor + block_bytes) <= limit
        header = cursor.as(BlockHeader*)
        unless BlockHeader.free?(header)
          b0 = cursor.address
          b1 = cursor.address + block_bytes
          p = b0 & ~(page - 1)
          while p < b1
            idx = ((p - first_page) // page).to_i32
            live_mask |= 1_u64 << idx if idx >= 0 && idx < 64
            p += page
          end
        end
        cursor += block_bytes
      end

      idx = 0
      while idx < n_pages.to_i32
        if (live_mask & (1_u64 << idx)) == 0
          run_start = first_page + idx.to_u64 * page
          while idx < n_pages.to_i32 && (live_mask & (1_u64 << idx)) == 0
            idx += 1
          end
          run_end = first_page + idx.to_u64 * page
          if run_start >= data0 && run_end <= data1 && run_end > run_start
            unlink_freelist_range(class_index, nursery, run_start, run_end)
          end
        else
          idx += 1
        end
      end
    end

    # Release physical pages for cached large-object chunks after a major
    # collection. Large freelist chunks (`cache_large_chunk`) keep their
    # physical pages hot (the entire mmap is one object, so partial-page reclaim
    # does not apply).
    #
    # On Darwin: MADV_FREE_REUSABLE drops RSS while preserving page contents —
    # the next allocation from the cache pays a page-fault cost instead of a
    # syscall.
    # On Linux: MADV_FREE — kernel may defer reclaim until memory pressure
    # rises; page content is preserved until reclaimed.  Unlike
    # MADV_DONTNEED (which zeroes and evicts immediately), this avoids the
    # re-fault storms that made larger RSS under acikturkiye.
    private def release_large_freelist_pages : Nil
      {% if flag?(:darwin) || flag?(:linux) %}
        page = Platform.host_page_size
        LARGE_FREE_BUCKETS.times do |b|
          user = @large_freelists[b]
          while user
            header = BlockHeader.from_user(user)
            chunk = (header.as(UInt8*) - ChunkHeader::SIZE).as(ChunkHeader*)
            next_user = header.value.next_free
            data_lo = chunk.address
            data_hi = data_lo + chunk.value.mapped_bytes
            start = (data_lo + page - 1) & ~(page - 1)
            finish = data_hi & ~(page - 1)
            if start < finish
              ok = {% if flag?(:darwin) %}
                     Platform.release_physical_pages(start, finish - start)
                   {% else %}
                     Platform.release_physical_pages_free(start, finish - start)
                   {% end %}
              if ok
                @dontneed_bytes += (finish - start)
              end
            end
            user = next_user
          end
        end
      {% end %}
    end

    # Classify a kept size-class chunk by live_payload / usable_payload.
    private def note_chunk_fill(live_payload : UInt64, usable_payload : UInt64) : Nil
      if usable_payload == 0 || live_payload * 4 < usable_payload
        @chunk_fill_lt25 += 1
      elsif live_payload * 2 < usable_payload
        @chunk_fill_lt50 += 1
      elsif live_payload * 4 < usable_payload * 3
        @chunk_fill_lt75 += 1
      else
        @chunk_fill_ge75 += 1
      end
    end

    # Defer an empty size-class chunk to the post-STW `flush_pending_empty_chunks`
    # release list. Safe to call from within STW: the chunk is unlinked now and
    # the actual munmap runs after threads are resumed (avoids blocking other
    # mutators on kernel VM locks). Also removes the freelist entries that
    # pointed inside the chunk so we never hand a user pointer that lives in
    # soon-to-be-unmapped memory back to an allocation.
    private def reclaim_empty_chunk(chunk : ChunkHeader*) : Nil
      return if ChunkHeader.large?(chunk)

      class_index = chunk.value.size_class.to_i32
      return if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      nursery = ChunkHeader.nursery?(chunk)
      mapped = chunk.value.mapped_bytes
      base = chunk.address
      finish = base + mapped

      # Drop any free-block pointers inside this range BEFORE unlinking — the
      # freelist may still hold a node that lives in the about-to-be-released
      # chunk. unlink_freelist_range walks the freelist and rebuilds the head
      # from entries outside [base, finish).
      unlink_freelist_range(class_index, nursery, base, finish)

      unlink_chunk(chunk)
      @heap_size -= mapped if @heap_size >= mapped
      @released_chunk_bytes += mapped
      @bytes_reclaimed_since_gc += mapped
      # Defer the actual munmap to flush_pending_empty_chunks (post-STW).
      # Previously this called LibC.munmap inline, which could stall mutators
      # behind the kernel VM lock while we held the world stopped. The
      # @unmapped_bytes counter is bumped inside flush, after the actual
      # munmap length is known (which may be a coalesced run larger than
      # a single chunk's mapped_bytes).
      chunk.value.next = @pending_empty_chunks
      @pending_empty_chunks = chunk
      update_heap_bounds_after_unmap
    end

    # Drop freelist nodes whose user pointer falls in [lo, hi).
    # Never rewrite !free? headers: a USED object can still be linked on the
    # freelist after a mid-`tlab_alloc_small` STW + flush (see scrub_freelists).
    #
    # Parallel EC can corrupt next_free into a cycle (long GDB: DEFAULT-1 stuck
    # here under major sweep while peers sit in STW sigsuspend — world never
    # restarts). Bound the walk; on runaway install the partial new_head and
    # stop (do not rebuild mid-sweep — @chunks is being relinked). Orphaned
    # FREE blocks are recovered by a later rebuild_size_class_freelist.
    private def unlink_freelist_range(class_index : Int32, nursery : Bool, lo : UInt64, hi : UInt64) : Nil
      if nursery
        @nursery_freelists[class_index] = filter_freelist_outside(
          @nursery_freelists[class_index], lo, hi)
        @nursery_freelist_clean[class_index] = false
      else
        @freelists[class_index] = filter_freelist_outside(@freelists[class_index], lo, hi)
        if @tight_grow
          @prefer_freelists[class_index] = filter_freelist_outside(
            @prefer_freelists[class_index], lo, hi)
        end
        @freelist_clean[class_index] = false
      end
    end

    private def filter_freelist_outside(head : Void*, lo : UInt64, hi : UInt64) : Void*
      new_head = Pointer(Void).null
      user = head
      max_steps = (@heap_size // BlockHeader::SIZE.to_u64) &+ 1024_u64
      max_steps = 1024_u64 if max_steps < 1024_u64
      steps = 0_u64
      while user
        steps &+= 1
        break if steps > max_steps
        header = BlockHeader.from_user(user)
        nxt = header.value.next_free
        nxt = Pointer(Void).null if nxt == user
        addr = user.address
        if (addr < lo || addr >= hi) && BlockHeader.free?(header)
          payload = header.value.size
          # Carry SWEPT: this is a freelist *rebuild* of blocks that are already
          # free, not a free. Constructing the header with a bare `FREE` erased
          # the bit, so a block the sweep had reclaimed later read as an
          # explicit `Heap#free` in the crash report — measured on 2026-08-16,
          # when a CI catch was written up as "the other free path exists" and
          # was in fact this.
          header.value = BlockHeader.new(payload, swept_flag(header), new_head)
          new_head = user
        end
        user = nxt
      end
      new_head
    end

    private def rebuild_size_class_freelist(class_index : Int32, nursery : Bool, *, recalc : Bool = true) : Nil
      payload = SizeClasses.payload(class_index)
      head = Pointer(Void).null
      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      page = Platform.host_page_size

      each_chunk do |chunk|
        next if ChunkHeader.large?(chunk)
        next if ChunkHeader.dormant?(chunk)
        next if chunk.value.size_class != class_index.to_u32
        next if ChunkHeader.nursery?(chunk) != nursery

        skip_holes = ChunkHeader.holed?(chunk)
        live_mask = 0_u64
        first_page = 0_u64
        n_pages = 0_u64

        if skip_holes
          data0 = ChunkHeader.data_start(chunk).address
          data1 = ChunkHeader.data_end(chunk).address
          first_page = data0 & ~(page - 1)
          last_page = (data1 - 1) & ~(page - 1)
          n_pages = ((last_page - first_page) // page) + 1
          if n_pages == 0 || n_pages > 64
            skip_holes = false
          else
            cursor = ChunkHeader.data_start(chunk).as(UInt8*)
            limit = ChunkHeader.data_end(chunk).as(UInt8*)
            while (cursor + block_bytes) <= limit
              header = cursor.as(BlockHeader*)
              unless BlockHeader.free?(header)
                b0 = cursor.address
                b1 = cursor.address + block_bytes
                p = b0 & ~(page - 1)
                while p < b1
                  idx = ((p - first_page) // page).to_i32
                  live_mask |= 1_u64 << idx if idx >= 0 && idx < 64
                  p += page
                end
              end
              cursor += block_bytes
            end
          end
        end

        each_block(chunk) do |header|
          next unless BlockHeader.free?(header)
          if skip_holes
            b0 = header.address
            b1 = b0 + block_bytes
            p = b0 & ~(page - 1)
            on_live_page = false
            while p < b1
              idx = ((p - first_page) // page).to_i32
              if idx >= 0 && idx < 64 && (live_mask & (1_u64 << idx)) != 0
                on_live_page = true
                break
              end
              p += page
            end
            next unless on_live_page
          end
          user = BlockHeader.user_from(header)
          header.value = BlockHeader.new(payload, swept_flag(header), head)
          head = user
        end
      end

      if nursery
        @nursery_freelists[class_index] = head
        @nursery_freelist_clean[class_index] = false
      else
        @freelists[class_index] = head
        @freelist_clean[class_index] = false
        retight_partition_freelist(class_index) if @tight_grow
      end

      recalc_free_bytes if recalc
    end

    # After a full freelist rebuild, re-establish sticky prefer = newest chunk.
    private def retight_partition_freelist(class_index : Int32) : Nil
      chunk = @chunks
      grow = Pointer(ChunkHeader).null
      while chunk
        if !ChunkHeader.large?(chunk) && !ChunkHeader.dormant?(chunk) &&
           chunk.value.size_class == class_index.to_u32 &&
           !ChunkHeader.nursery?(chunk)
          grow = chunk
          break
        end
        chunk = chunk.value.next
      end
      if grow.null?
        @prefer_freelists[class_index] = Pointer(Void).null
        @grow_lo[class_index] = 0_u64
        @grow_hi[class_index] = 0_u64
        return
      end
      @grow_lo[class_index] = ChunkHeader.data_start(grow).address
      @grow_hi[class_index] = ChunkHeader.data_end(grow).address
      user = @freelists[class_index]
      prefer = Pointer(Void).null
      global = Pointer(Void).null
      while user
        header = BlockHeader.from_user(user)
        nxt = header.value.next_free
        payload = header.value.size
        if tight_addr_in_grow?(class_index, user.address)
          header.value = BlockHeader.new(payload, swept_flag(header), prefer)
          prefer = user
        else
          header.value = BlockHeader.new(payload, swept_flag(header), global)
          global = user
        end
        user = nxt
      end
      @prefer_freelists[class_index] = prefer
      @freelists[class_index] = global
    end

    # Drop RSS for a fully-free chunk while keeping the VMA (dormant reuse).
    # Addr/len must be page-aligned into the data region.
    private def dontneed_chunk_data(chunk : ChunkHeader*) : Nil
      {% if flag?(:linux) || flag?(:darwin) %}
        page = Platform.host_page_size
        data0 = ChunkHeader.data_start(chunk).address
        data1 = ChunkHeader.data_end(chunk).address
        start = (data0 + page - 1) & ~(page - 1)
        finish = data1 & ~(page - 1)
        return if finish <= start
        len = finish - start
        if Platform.release_physical_pages(start, len)
          @dontneed_bytes += len
        end
      {% end %}
    end

    # Drop RSS for free pages that hold no live blocks.
    # preserve_content=false → MADV_DONTNEED / Darwin reusable (HOLED path must
    # omit those blocks from the freelist via rebuild).
    # preserve_content=true → Linux MADV_FREE (freelist words stay valid until
    # kernel reclaim) — used by mostly-empty without HOLED.
    private def release_free_pages_in_chunk(chunk : ChunkHeader*, payload : UInt32, *, preserve_content : Bool) : Bool
      {% if flag?(:linux) || flag?(:darwin) %}
        page = Platform.host_page_size
        data0 = ChunkHeader.data_start(chunk).address
        data1 = ChunkHeader.data_end(chunk).address
        return false if data1 <= data0

        first_page = data0 & ~(page - 1)
        last_page = (data1 - 1) & ~(page - 1)
        n_pages = ((last_page - first_page) // page) + 1
        return false if n_pages == 0 || n_pages > 64

        live_mask = 0_u64
        block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
        cursor = ChunkHeader.data_start(chunk).as(UInt8*)
        limit = ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(BlockHeader*)
          unless BlockHeader.free?(header)
            b0 = cursor.address
            b1 = cursor.address + block_bytes
            p = b0 & ~(page - 1)
            while p < b1
              idx = ((p - first_page) // page).to_i32
              live_mask |= 1_u64 << idx if idx >= 0 && idx < 64
              p += page
            end
          end
          cursor += block_bytes
        end

        any = false
        # Walk pages and coalesce contiguous free runs into single madvise.
        idx = 0
        while idx < n_pages.to_i32
          if (live_mask & (1_u64 << idx)) == 0
            run_start = first_page + idx.to_u64 * page
            # Extend the run while pages are free and within chunk data.
            while idx < n_pages.to_i32 && (live_mask & (1_u64 << idx)) == 0
              idx += 1
            end
            run_end = first_page + idx.to_u64 * page
            len = run_end - run_start
            if run_start >= data0 && run_end <= data1 && len > 0
              ok = if preserve_content
                     {% if flag?(:linux) %}
                       Platform.release_physical_pages_free(run_start, len)
                     {% else %}
                       # Darwin reusable already preserves content.
                       Platform.release_physical_pages(run_start, len)
                     {% end %}
                   else
                     Platform.release_physical_pages(run_start, len)
                   end
              if ok
                @dontneed_bytes += len
                any = true
              end
            end
          else
            idx += 1
          end
        end
        any
      {% else %}
        false
      {% end %}
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
      @free_bytes.set(total)
    end

    # `FREE`, plus `SWEPT` if the block already carried it. The freelist rebuild
    # paths re-link blocks that are *already free*; they must not silently
    # relabel how those blocks were released, which a bare `Flags::FREE` did.
    @[AlwaysInline]
    private def swept_flag(header : BlockHeader*) : UInt32
      BlockHeader::Flags::FREE | (header.value.flags & BlockHeader::Flags::SWEPT)
    end

    private def reclaim_small(chunk : ChunkHeader*, header : BlockHeader*, payload : UInt32 = 0_u32) : Nil
      class_index = chunk.value.size_class.to_i32
      return if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      payload = SizeClasses.payload(class_index) if payload == 0
      link_small_to_freelist(chunk, header, payload, class_index)
      free_bytes_add(payload.to_u64)
      @bytes_reclaimed_since_gc += payload.to_u64
      live_objects_dec
    end

    # Freelist-link a USED block without live_objects_dec (caller already
    # batched the count, e.g. fully-dead defer path under Parallel bounded).
    private def freelist_reserve_fully_dead(chunk : ChunkHeader*, class_index : Int32, payload : UInt32, block_bytes : UInt64) : Nil
      cursor = ChunkHeader.data_start(chunk).as(UInt8*)
      limit = ChunkHeader.data_end(chunk).as(UInt8*)
      reclaimed = 0_u64
      while (cursor + block_bytes) <= limit
        header = cursor.as(BlockHeader*)
        unless BlockHeader.free?(header)
          link_small_to_freelist(chunk, header, payload, class_index)
          reclaimed &+= payload.to_u64
        end
        cursor += block_bytes
      end
      free_bytes_add(reclaimed) if reclaimed > 0
      @bytes_reclaimed_since_gc += reclaimed
    end

    private def link_small_to_freelist(chunk : ChunkHeader*, header : BlockHeader*, payload : UInt32, class_index : Int32) : Nil
      user = BlockHeader.user_from(header)
      was_nursery = BlockHeader.nursery?(header)
      push_size_class_free(class_index, was_nursery, header, user, payload, swept: true)
    end

    # Accounting only — caller unmaps / drops the chunk from @chunks.
    private def prepare_reclaim_large(chunk : ChunkHeader*, header : BlockHeader*) : Nil
      mapped = chunk.value.mapped_bytes
      payload = header.value.size.to_u64
      @heap_size -= mapped if @heap_size >= mapped
      @unmapped_bytes += mapped
      @bytes_reclaimed_since_gc += payload
      live_objects_dec
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
