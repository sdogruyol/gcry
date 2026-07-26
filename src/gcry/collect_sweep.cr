# Sweep phase: reclaim, empty-chunk release, dormant/madvise, freelists.

module Gcry
  class Heap
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
        @size_class_live_bytes = 0_u64
        @chunk_fill_lt25 = 0_u64
        @chunk_fill_lt50 = 0_u64
        @chunk_fill_lt75 = 0_u64
        @chunk_fill_ge75 = 0_u64
        @dormant_chunk_bytes = 0_u64
        @dontneed_bytes = 0_u64
      end

      # Bytes of empty chunks kept dormant this major (within retain budget).
      dormant_budget_used = 0_u64

      chunk = @chunks
      while chunk
        nxt = chunk.value.next
        drop = false

        if major || ChunkHeader.nursery?(chunk)
          if ChunkHeader.large?(chunk)
            header = ChunkHeader.data_start(chunk).as(BlockHeader*)
            unless BlockHeader.free?(header)
              if heap_marked?(header)
                heap_clear_mark(header)
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
            live_payload = 0_u64
            usable_payload = 0_u64
            if class_index >= 0 && class_index < SIZE_CLASS_COUNT
              payload = SizeClasses.payload(class_index)
              block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
              cursor = ChunkHeader.data_start(chunk).as(UInt8*)
              limit = ChunkHeader.data_end(chunk).as(UInt8*)
              # When releasing empties: discover live first so fully-dead chunks
              # skip freelist link (unlink-only for pre-existing free blocks).
              defer_reclaim = major && @release_empty_chunks
              if defer_reclaim
                while (cursor + block_bytes) <= limit
                  usable_payload += payload.to_u64
                  header = cursor.as(BlockHeader*)
                  unless BlockHeader.free?(header)
                    if heap_marked?(header)
                      any_live = true
                      live_payload += payload.to_u64
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
                  cursor = ChunkHeader.data_start(chunk).as(UInt8*)
                  while (cursor + block_bytes) <= limit
                    header = cursor.as(BlockHeader*)
                    unless BlockHeader.free?(header)
                      @live_objects -= 1 if @live_objects > 0
                    end
                    cursor += block_bytes
                  end
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
                if @release_empty_chunks && class_index >= 0 && class_index < SIZE_CLASS_COUNT
                  if dormant_budget_used + mapped <= @empty_chunk_retain && @empty_chunk_retain > 0
                    # Optional: keep VA with DONTNEED when retain > 0.
                    # Set DORMANT flag but defer madvise to post-STW
                    # `flush_pending_dormant_chunks` (kernel VM lock outside STW).
                    ChunkHeader.set_dormant(chunk, true)
                    dormant_budget_used += mapped
                    @dormant_chunk_bytes += mapped
                    unlink_freelist_range(class_index, ChunkHeader.nursery?(chunk),
                      ChunkHeader.data_start(chunk).address, ChunkHeader.data_end(chunk).address)
                  else
                    @heap_size -= mapped if @heap_size >= mapped
                    @bytes_reclaimed_since_gc += mapped
                    @released_chunk_bytes += mapped
                    index_remove(chunk)
                    unlink_freelist_range(class_index, ChunkHeader.nursery?(chunk),
                      ChunkHeader.data_start(chunk).address, ChunkHeader.data_end(chunk).address)
                    chunk.value.next = to_unmap
                    to_unmap = chunk
                    drop = true
                    any_drop = true
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
                  bit = 1_u64 << class_index
                  if ChunkHeader.nursery?(chunk)
                    rebuild_nursery_mask |= bit
                  else
                    rebuild_mask |= bit
                  end
                else
                  ChunkHeader.set_holed(chunk, false)
                end
              end
              unless drop
                @size_class_chunk_count += 1
                note_chunk_fill(live_payload, usable_payload)
              end
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

      # Page-HOLED freelist rebuild (empty-chunk release uses unlink_freelist_range).
      if rebuild_mask != 0 || rebuild_nursery_mask != 0
        SIZE_CLASS_COUNT.times do |i|
          bit = 1_u64 << i
          rebuild_size_class_freelist(i, false, recalc: false) if (rebuild_mask & bit) != 0
          rebuild_size_class_freelist(i, true, recalc: false) if (rebuild_nursery_mask & bit) != 0
        end
        recalc_free_bytes
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
        LibC.munmap(Pointer(Void).new(run_base), LibC::SizeT.new(run_total))
        chunk = nxt
      end
    end

    # Apply MADV_FREE / DONTNEED to dormant chunks after STW.
    # Walks @chunks; dormant chunks stay in the chunk list but their
    # physical pages are released outside STW (kernel VM lock avoided).
    # Coalesces contiguous dormant ranges into a single madvise.
    private def flush_pending_dormant_chunks : Nil
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
          dontneed_free_pages_in_chunk(chunk, SizeClasses.payload(class_index))
        end
      {% else %}
        each_chunk do |chunk|
          next unless ChunkHeader.holed?(chunk)
          next if ChunkHeader.large?(chunk)
          class_index = chunk.value.size_class.to_i32
          next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
          dontneed_free_pages_in_chunk(chunk, SizeClasses.payload(class_index))
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
    private def unlink_freelist_range(class_index : Int32, nursery : Bool, lo : UInt64, hi : UInt64) : Nil
      head = nursery ? @nursery_freelists[class_index] : @freelists[class_index]
      new_head = Pointer(Void).null
      user = head
      while user
        header = BlockHeader.from_user(user)
        nxt = header.value.next_free
        addr = user.address
        if addr < lo || addr >= hi
          payload = header.value.size
          header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, new_head)
          new_head = user
        end
        user = nxt
      end
      if nursery
        @nursery_freelists[class_index] = new_head
        @nursery_freelist_clean[class_index] = false
      else
        @freelists[class_index] = new_head
        @freelist_clean[class_index] = false
      end
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

      recalc_free_bytes if recalc
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

    # Drop RSS for free pages that hold no live blocks. Intrusive freelist is
    # safe because those blocks are omitted from the freelist (HOLED + rebuild).
    # Pre-computes contiguous free-page runs and issues ONE madvise per run
    # instead of one per page (reduces syscall count from up to 64 to 1-3).
    private def dontneed_free_pages_in_chunk(chunk : ChunkHeader*, payload : UInt32) : Bool
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
              if Platform.release_physical_pages(run_start, len)
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
