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
              with_alloc_lock { sweep_large_one(chunk, major, after_world: true) }
            else
              sweep_large_one(chunk, major, after_world: false)
            end
          else
            # Size-class sweep. The block walk itself is `sweep_small_blocks`;
            # everything below it is the policy that consumes the four numbers
            # it returns — live accounting, warm/DORMANT/munmap selection,
            # HOLED/SPARSE classification, freelist rebuild bits. Keeping that
            # policy in one place is what lets a second representation supply
            # the same four numbers without restating any of it.
            class_index = chunk.value.size_class.to_i32
            fl_locked = false
            if after_world && class_index >= 0 && class_index < SIZE_CLASS_COUNT
              freelist_lock_ptr(class_index, ChunkHeader.nursery?(chunk)).value.lock
              fl_locked = true
            end
            begin
              counts = sweep_small_blocks(chunk, class_index, major, fl_locked)
              any_live = counts.any_live
              live_payload = counts.live_payload
              usable_payload = counts.usable_payload
              free_payload = counts.free_payload

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
                      # left them USED after live_objects_sub). No-op on a
                      # bitmap chunk, which is warm by staying mapped.
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
                      # `index_remove` used to run here. Deferred to
                      # `flush_pending_empty_chunks_locked`: this branch runs
                      # inside the pause in the in-STW sweep configs, and
                      # `index_remove` takes `@index_lock` — a lock any
                      # suspended mutator can hold across `chunk_containing` /
                      # `index_insert` / the bounds updates. The collector
                      # spinning on a frozen peer's lock is the 0.21.1
                      # `@chunk_list_lock` hang, one lock over. The munmap this
                      # remove serves is already deferred to the same flush,
                      # and remove-before-munmap ordering is preserved there.
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
                  # `!bitmap_alloc_chunk?`: free-page release is not ported to
                  # the bitmap representation and must not be half-engaged.
                  #
                  # Its machinery is freelist-shaped end to end — HOLED triggers
                  # `rebuild_size_class_freelist`, and
                  # `unlink_free_only_page_runs` takes free blocks *off the
                  # freelist* before the syscall so nothing hands them out
                  # mid-release. Under bitmap allocation there is no freelist to
                  # unlink from, and the pool cursor can hand out a block in a
                  # run the walk is discarding.
                  #
                  # Measured: with an `occ`-built live mask the walk engages
                  # (0 B -> 1.97 MB) and corrupts — HOLED faulted 1 of 4 under
                  # `GCRY_PAGE_DONTNEED=1` where the default arm is clean 3 of 3.
                  # Declining only the madvise made it *worse* (3 of 4), because
                  # the freelist unlink still ran. So the whole path stands down.
                  #
                  # Cost: bitmap chunks do not return free pages to the OS —
                  # an RSS regression, tracked, and strictly better than
                  # reclaiming live objects.
                  if @madvise_free_pages && !bitmap_alloc_chunk?(chunk) &&
                     class_index >= 0 && class_index < SIZE_CLASS_COUNT &&
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
                       !bitmap_alloc_chunk?(chunk) &&
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
        # Only on the `after_world` path, and the distinction is not a detail.
        #
        # The first version took the lock unconditionally, on the argument that
        # "in the stopped world nothing else can be here and the lock is free".
        # That is false, and it shipped in 0.21.0 as a hang: STW suspends by
        # **signal**, not at safepoints, so a mutator can be frozen inside
        # `map_chunk` or `unlink_chunk` still holding this lock, and the
        # collector then spins on it with every mutator parked. The watchdog
        # names it — `STALLED in phase=sweep — waiting on something a suspended
        # thread holds` — and it reproduces wherever the sweep runs in-STW
        # rather than after it: `GCRY_PAGE_DONTNEED=1`, `GCRY_TLAB=1`,
        # `GCRY_DISABLE_LAZY_SWEEP=1`.
        #
        # Measured interleaved, 40 children each: **0 hangs on the tree before
        # the lock, 5 on v0.21.0, 0 with this**. The hangs were also masking
        # what the gate exists to catch — the same 40 children crash 5 times on
        # the page-release corruption once they are allowed to finish.
        #
        # In the stopped world the store needs no lock: the mutators that could
        # race it are the ones that are suspended. The lock is for the
        # `after_world` path, where they are running and a prepend racing this
        # store would be lost, which puts a live chunk on no list at all.
        if after_world
          @chunk_list_lock.sync { @chunks = kept }
        else
          @chunks = kept
        end
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
        # Same reason as `trim_large_cache`: this walks the chunk list and
        # rewrites `@heap_min` / `@heap_max`, the bounds `find_block` reads to
        # decide whether an address is gcry's at all. In the lazy path
        # (`after_world`) the mutators are running and can be mapping chunks
        # underneath the walk, so it needs the allocator's lock; in the stopped
        # world nothing else runs and taking it would be pointless.
        if after_world && !@trim_unlocked
          with_alloc_lock { update_heap_bounds_after_unmap }
        else
          update_heap_bounds_after_unmap
        end
      end
    end

    private def sweep_large_one(chunk : ChunkHeader*, major : Bool, after_world : Bool) : Nil
      header = ChunkHeader.large_header(chunk)
      return if BlockHeader.free_large?(header)
      # A chunk whose block header is still all zeroes is one `alloc_large`
      # published and has not filled in yet. `map_chunk` links the chunk and
      # inserts it into the index before `set_used` runs, and STW takes no part
      # in `@alloc_lock` — it suspends by signal, so a mutator can be stopped
      # between those two writes. The block then reads as neither FREE nor
      # marked, which is exactly the shape sweep reclaims: the mutator resumes,
      # finishes the allocation, and hands out memory already on the large
      # freelist and headed for munmap.
      #
      # Size zero is the tell, and it is not otherwise reachable: a real large
      # allocation has a payload.
      #
      # A tripwire, not a fix: it has **measured zero** — 334 collections of
      # acikturkiye under `wrk -t4 -c64` for 260 s, while the crash this was
      # written to explain was still happening. So the window is either much
      # narrower than the argument above, or it is closed by something this
      # file does not name. The counter stays because the next time that
      # argument is made, it should have to answer this number.
      if header.value.size == 0
        @sweep_large_uninitialised &+= 1
        return
      end
      if heap_marked?(header)
        heap_clear_mark(header)
      elsif major
        # Recycle mapping — never munmap inside STW (Linux VMA munmap
        # of thousands of large HTTP buffers dominated pause time).
        mapped = chunk.value.mapped_bytes
        @large_cached_by_sweep &+= 1
        if after_world
          # Caller holds `@alloc_lock`; the bucket lists are quiescent.
          cache_large_chunk(chunk, header)
        else
          # In-STW: `cache_large_chunk` walks and writes `@large_freelists`,
          # which a suspended mutator can be frozen mid-`cache`/mid-`take`
          # under `@alloc_lock` — a tail-append against a half-done protocol
          # orphans bucket entries and drifts the byte counters. Queue the
          # chunk (linked through its own header, the `queue_large_release`
          # pattern) and insert it under the lock in
          # `flush_pending_large_cache`, with the world running.
          hv = header.value
          hv.next_free = @pending_large_cache
          header.value = hv
          @pending_large_cache = ChunkHeader.large_user(chunk)
        end
        @bytes_reclaimed_since_gc += mapped
        live_objects_dec
      end
    end

    # True only for a header no code path ever writes: `set_used` stores a
    # real payload size, `refill_size_class` stores size+FREE, and the sweep's
    # own links keep FREE set. All-zero is mmap-fresh memory — a chunk whose
    # refill loop a suspended mutator has not finished.
    @[AlwaysInline]
    private def uninitialised_small_block?(header : BlockHeader*) : Bool
      header.value.size == 0 && header.value.flags == 0
    end

    # Insert the large chunks the in-STW sweep queued, now that mutators run
    # and `@alloc_lock` means what it says. Before `flush_pending_large_release`
    # and the trim, so this collection's recycled chunks are reusable at once.
    private def flush_pending_large_cache : Nil
      return if @pending_large_cache.null?
      with_alloc_lock do
        user = @pending_large_cache
        @pending_large_cache = Pointer(Void).null
        while user
          header = BlockHeader.large_header_from_user(user)
          chunk = (header.as(UInt8*) - ChunkHeader::SIZE).as(ChunkHeader*)
          nxt = header.value.next_free
          cache_large_chunk(chunk, header)
          user = nxt
        end
      end
    end

    # Munmap size-class chunks queued during STW sweep. Call outside STW.
    # Do not invalidate the static-root maps cache here (same as the former
    # in-STW empty-chunk path): heap VMAs are excluded via the chunk index and
    # static scans use safe probing. Full maps refresh stays on the major interval.
    # Release the large chunks mutators detached in `trim_large_cache`.
    #
    # Collector thread only, and never while a `flush_pending_*` walk is in
    # flight — that is the whole point of the queue. The chunks have been off
    # `@chunks` and out of the index since the mutator detached them, so
    # nothing can hand them out; this is only the teardown.
    private def flush_pending_large_release : Nil
      chain = Pointer(Void).null
      with_alloc_lock do
        chain = @pending_large_release
        @pending_large_release = Pointer(Void).null
        @pending_large_release_bytes = 0_u64
      end
      return if chain.null?

      with_alloc_lock { release_large_chain(chain) }
      with_alloc_lock { update_heap_bounds_after_unmap }
    end

    # Run a pass that walks `@chunks` with the world running — the lazy sweep
    # and the three `flush_pending_*` passes. The flag is what a mutator's trim
    # consults before unmapping; see `Heap#trim_large_cache`. Not reentrant:
    # these run one after another, never nested.
    private def during_live_chunk_walk(&) : Nil
      with_alloc_lock do
        @live_chunk_walk = true
        @live_walk_spans &+= 1
      end
      begin
        yield
      ensure
        with_alloc_lock { @live_chunk_walk = false }
      end
    end

    private def flush_pending_empty_chunks : Nil
      chunk = @pending_empty_chunks
      return if chunk.null?

      @pending_empty_chunks = Pointer(ChunkHeader).null

      # Under `@alloc_lock`, because the teardown races readers that do hold it.
      # `update_heap_bounds_after_unmap` walks `@chunks` under the lock, from a
      # mutator's `trim_large_cache` — and `unlink_chunk` leaves the removed
      # chunk's `next` intact, so a walker standing on one keeps following it
      # into memory this loop is unmapping. Measured as a SIGSEGV in that walk,
      # 1 of 30 children of `make large-cache-race` on an unchanged tree.
      #
      # `GCRY_EMPTY_FLUSH_UNLOCKED=1` restores the old behaviour for the gate.
      if @empty_flush_unlocked
        flush_pending_empty_chunks_locked(chunk)
      else
        with_alloc_lock { flush_pending_empty_chunks_locked(chunk) }
      end
    end

    private def flush_pending_empty_chunks_locked(chunk : ChunkHeader*) : Nil
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
        # Deferred from the sweep's drop branch (see the comment there): the
        # entry leaves the index here, immediately before its memory goes, and
        # before `refuse_live_release` would read its own entry as "still
        # indexed inside the range".
        index_remove(chunk)
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
          index_remove(nxt)
          chunk = nxt
          nxt = nxt.value.next
        end
        run_total = (run_end - run_base).to_u64
        @unmapped_bytes += run_total
        unless guard_release(run_base, run_total, GUARD_KIND_EMPTY_CHUNK) ||
               refuse_live_release(run_base, run_total, GUARD_KIND_EMPTY_CHUNK) ||
               quarantine_release(run_base, run_total)
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

      # Dormancy was decided by the sweep, inside the stopped world. This pass
      # runs after `start_world`, holds no lock, and `MADV_DONTNEED` over a
      # chunk's data range zeroes whatever is there — while
      # `revive_dormant_chunk` is free to hand blocks out of exactly such a
      # chunk from any mutator, under the size-class freelist lock that this
      # pass does not take.
      #
      # So the window is real by construction. Whether it is ever *hit* is a
      # different question, and this counts it rather than assuming: the flag
      # costs two stores per collection and changes no behaviour.
      @dormant_flush_active = true

      data_lo = UInt64::MAX
      data_hi = 0_u64
      page = Platform.host_page_size

      each_chunk do |chunk|
        next unless ChunkHeader.dormant?(chunk)
        base = ChunkHeader.data_start(chunk).address
        # `chunk.address + mapped_bytes`, not `base + mapped_bytes`: the chunk
        # ends where its mapping ends, and `base` is `data_offset` bytes past
        # the chunk start. The old expression overshot by exactly that much and
        # was correct only because `end_page` rounded back down over a
        # sub-page offset — an accident a larger metadata region would not
        # survive. Flagged in 2026-09-03-large-freelist-header-madvise.
        finish = chunk.address + chunk.value.mapped_bytes
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
      @dormant_flush_active = false
    end

    # Apply per-chunk free-page madvise to HOLED chunks after STW.
    # On Darwin where MADV_FREE_REUSABLE preserves page content, walks ALL
    # kept size-class chunks (not just HOLED) for more aggressive RSS recovery.
    # Safe because the live-mask computation correctly identifies free pages
    # regardless of HOLED; MADV_FREE_REUSABLE on Darwin does not zero headers.
    # Take the pages out of circulation *before* the syscall that zeroes them.
    #
    # `MADV_DONTNEED` zeroes; `MADV_FREE_REUSABLE` zero-fills a page the kernel
    # reclaims. Either way the freelist nodes living in those pages stop being
    # readable, and the chunk's blocks are still on the class freelist when the
    # call goes out. Unlinking the free-only runs first means no allocator can
    # be handed a block in a run that is about to be dropped — which is a
    # different guarantee from re-reading the mask, and a stronger one:
    # re-reading closes the window from "mask built" to "about to release" and
    # leaves the one from "checked" to "syscall issued".
    #
    # That was measured rather than assumed. Holding the freelist lock across
    # the re-read and the `madvise` — serialising the release against the
    # allocator instead of removing the pages from it — still crashed 5 of 40
    # (`bench/log/linux/2026-08-26-stw-sweep-hang/FINDINGS.md`).
    #
    # The unlink runs under the class's freelist lock; the syscall does not.
    # The machinery already existed for `@mostly_empty_dontneed` and was simply
    # never applied to the HOLED walk, which is the one `GCRY_PAGE_DONTNEED=1`
    # turns on.
    # Unlink a chunk's free-only page runs and release them in one critical
    # section that excludes every small allocation of the class — see
    # `with_small_allocation_excluded` for why the syscall must sit inside it.
    private def release_chunk_pages_excluded(chunk : ChunkHeader*, class_index : Int32, *,
                                             preserve_content : Bool, unlink : Bool = true) : Bool
      payload = SizeClasses.payload(class_index)
      nursery = ChunkHeader.nursery?(chunk)
      with_small_allocation_excluded(class_index, nursery) do
        if unlink
          unlink_free_only_page_runs(chunk, class_index, nursery, payload)
          @page_release_unlinked_chunks &+= 1 unless preserve_content
        end
        release_free_pages_in_chunk(chunk, payload, preserve_content: preserve_content)
      end
    end

    private def flush_pending_page_release_chunks : Nil
      # Neither branch used to consult this, which made the documented escape
      # a no-op where it matters most: on Darwin the walk is default-on and
      # visits *every* kept size-class chunk, so `GCRY_DISABLE_PAGE_RELEASE=1`
      # and `GCRY_DISABLE_MADVISE=1` set a flag nothing here read. On Linux the
      # flag gates HOLED marking upstream, so the escape worked by accident.
      #
      # It matters because this walk computes a free-page mask and then
      # syscalls, with the world running: a mutator can allocate into a page
      # the mask called free before the call lands. `make page-release-corruption`
      # faults 1 of 4 on the Linux arm, and Darwin's `MADV_FREE_REUSABLE`
      # zero-fills a reclaimed page, so the same window is reachable there
      # under memory pressure. The off switch has to actually switch it off.
      return unless @madvise_free_pages
      {% if flag?(:darwin) %}
        each_chunk do |chunk|
          next if ChunkHeader.large?(chunk)
          next if ChunkHeader.dormant?(chunk)
          # A bitmap chunk declines the free-page walk, and the reason written
          # here until 2026-09-04 was wrong — wrong in the direction that
          # matters, so it is worth replacing rather than deleting.
          #
          # It said: the mask comes from `BlockHeader.free?`, that flag is
          # stale on a bitmap chunk, therefore the walk would compute the wrong
          # liveness and release a page holding a live object. The staleness is
          # real. Its direction is not what that says. `set_used` clears FREE
          # when a block is handed out and `bitmap_free_block` clears only
          # `occ`/`mark` and never touches the header, so on a bitmap chunk
          # `BlockHeader.free?` is false for *every* block, forever. The mask
          # is all-ones over every page that holds a whole block: it
          # over-reports liveness and can only fail to release.
          #
          # Measured on Apple M2 Pro / Darwin 25.6.0 / Crystal 1.21.0 with
          # `GCRY_BITMAP_ALLOC=1 GCRY_PAGE_DONTNEED=1` and the stand-down
          # removed (`GCRY_PAGE_RELEASE_BITMAP_WALK=1`): 208 KiB released from
          # bitmap chunks — the tail slack below the last whole block — and
          # `page_release_live_blocks=0`, i.e. the `occ`-based re-read found no
          # live block in any run the mask selected, 5 runs of 5. The header
          # arm of the same gate releases 2.88 MiB, so the walk does work here.
          #
          # So this `next` is a cost decision, not a soundness one: it skips a
          # full chunk walk per collection that would return ~208 KiB. The
          # soundness of the bitmap representation rests on the *other*
          # stand-down — `unlink_free_only_page_runs` below, which declines
          # because under bitmap allocation there is no freelist to unlink and
          # the pool cursor can hand out a block inside a run being released.
          # That one is load-bearing and has its own measured record.
          #
          # The checksum cannot decide any of this on Darwin, which is why the
          # evidence above is a counter: `Platform.release_physical_pages`
          # issues `madvise(..., MADV_FREE)`, and measured on the same host
          # both `MADV_FREE` and `MADV_FREE_REUSABLE` return 0 on a
          # still-referenced range and leave every word intact through 2 GiB
          # of pressure. A mis-released page here is latent.
          # `make darwin-bitmap-page-release` holds all of it.
          next if bitmap_alloc_chunk?(chunk) && !@page_release_bitmap_walk
          class_index = chunk.value.size_class.to_i32
          next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
          release_chunk_pages_excluded(chunk, class_index, preserve_content: false)
        end
      {% else %}
        each_chunk do |chunk|
          next unless ChunkHeader.holed?(chunk)
          next if ChunkHeader.large?(chunk)
          class_index = chunk.value.size_class.to_i32
          next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
          release_chunk_pages_excluded(chunk, class_index, preserve_content: false)
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
        # `GCRY_MOSTLY_EMPTY_UNLINK=1` separates the two things
        # `GCRY_MOSTLY_EMPTY_MODE=dontneed` changes at once. That mode both
        # unlinks the free-only runs *and* switches the syscall from `MADV_FREE`
        # to `MADV_DONTNEED`, so its 7 of 30 says nothing about which half
        # matters. This arm unlinks and keeps `MADV_FREE`.
        #
        # Research only: unlinked blocks do not come back without a freelist
        # rebuild, and the SPARSE path deliberately does not ask for one — the
        # whole point of the mode is to avoid it. If this arm turns out to be
        # the fix, the rebuild is the price and that is a separate decision.
        if release_chunk_pages_excluded(chunk, class_index, preserve_content: preserve,
             unlink: @mostly_empty_dontneed || @mostly_empty_unlink)
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

      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      if bitmap_alloc_chunk?(chunk)
        # Free-page release is NOT yet ported to the bitmap representation, and
        # this returns rather than guessing.
        #
        # An `occ`-built live mask makes the walk engage — 0 B became 1.97 MB —
        # and it also corrupted: `page-release-corruption`'s HOLED arm faulted
        # 1 of 4 under `GCRY_PAGE_DONTNEED=1` where the default arm is clean
        # 3 of 3 (8.6-8.9 MB released, 0 faults). So the fault is this
        # representation's, not the arm's documented flakiness.
        #
        # The unported half is the surrounding machinery, not the mask:
        # `unlink_free_only_page_runs` takes free blocks *off the freelist*
        # before the syscall so nothing hands them out mid-release, and under
        # bitmap allocation there is no freelist to unlink from — the pool
        # cursor can hand out a block in a run this walk is about to discard.
        # A correct port needs the cursor excluded from the run under the
        # size-class lock, which is Phase 3 work that is not done.
        #
        # Declining costs RSS on bitmap chunks and nothing else. Shipping the
        # mask alone costs live objects.
        @page_release_skipped_runs &+= 1
        return false
      else
        live_mask = 0_u64
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
    # Unlike the chunk-list walks, this one reads a structure mutators *edit*,
    # not just memory they can unmap: `take_large_free` hands an entry to user
    # code, which promptly writes over the `next_free` this walk is following.
    # Marking the walk live is not enough — it needs the allocator's lock, and
    # it has to keep it across the `madvise` calls, because an entry taken
    # between a snapshot and the syscall would be live memory by then.
    private def release_large_freelist_pages : Nil
      {% if flag?(:darwin) || flag?(:linux) %}
        with_alloc_lock { release_large_freelist_pages_locked }
      {% end %}
    end

    private def release_large_freelist_pages_locked : Nil
      {% if flag?(:darwin) || flag?(:linux) %}
        page = Platform.host_page_size
        LARGE_FREE_BUCKETS.times do |b|
          user = @large_freelists[b]
          while user
            header = BlockHeader.large_header_from_user(user)
            chunk = (header.as(UInt8*) - ChunkHeader::SIZE).as(ChunkHeader*)
            next_user = header.value.next_free
            # Round up from `data_start`, not from the chunk base. The base is
            # already page-aligned, so rounding up from it is a no-op and the
            # range began at page 0 — the page holding this chunk's own
            # `ChunkHeader` and the `BlockHeader` whose `next_free` threads this
            # very bucket chain. Every sibling release site rounds up from
            # `data_start` for this reason (:615, :1059).
            data_lo = @large_release_from_base ? chunk.address : ChunkHeader.data_start(chunk).address
            data_hi = chunk.address + chunk.value.mapped_bytes
            start = (data_lo + page - 1) & ~(page - 1)
            finish = data_hi & ~(page - 1)
            if start < finish && madvise_range_ok?(chunk, start, finish)
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

    # What one chunk's block walk found. Extracted so the bitmap representation
    # can supply the same four numbers from a streaming `occ &= mark` popcount
    # instead of a header walk, without either arm having to restate the
    # warm/DORMANT/munmap/HOLED/SPARSE policy that consumes them — that policy is
    # the delicate part of `sweep` and it stays in exactly one place.
    private struct SmallSweepCounts
      getter any_live : Bool
      getter live_payload : UInt64
      getter usable_payload : UInt64
      getter free_payload : UInt64

      def initialize(@any_live : Bool, @live_payload : UInt64,
                     @usable_payload : UInt64, @free_payload : UInt64)
      end
    end

    # Mark read for a block the sweep already has in hand.
    #
    # The ordinal is a counter, not a computation: the walk visits blocks in
    # address order, so it increments by one per block and the bitmap index
    # costs nothing. That is the whole reason `heap_marked?`'s chunk lookup must
    # not appear in this loop — a lookup per block is what took a 2026-08-01
    # experiment to 56.3% of Boehm.
    @[AlwaysInline]
    private def block_marked?(chunk : ChunkHeader*, header : BlockHeader*, ordinal : UInt64) : Bool
      return BlockHeader.marked?(header) unless bitmap_chunk?(chunk)
      # Union while this walk exists at all — see `block_marked_in?`.
      chunk_marked?(chunk, ordinal) || BlockHeader.marked?(header)
    end

    # Clearing one block's mark is a header write on the header path and
    # **nothing at all** on the bitmap path: 64 blocks share a word, so a
    # per-bit clear is a read-modify-write over 63 other blocks' marks, and this
    # walk runs with mutators live under lazy sweep. The bitmap is zeroed
    # wholesale by `clear_all_marks` at the start of the next cycle.
    #
    # Per *chunk*, not on the global flag. A nursery chunk keeps the header
    # representation (`bitmap_chunk?` excludes it), so skipping its header
    # clear because some other chunk is a bitmap chunk leaves a mark nothing
    # will ever clear — `clear_nursery_marks` carried the same confusion and
    # the pair reclaimed live objects on the minor path.
    @[AlwaysInline]
    private def clear_block_mark(chunk : ChunkHeader*, header : BlockHeader*) : Nil
      BlockHeader.clear_mark(header) unless bitmap_chunk?(chunk)
    end

    # The bitmap arm of the size-class sweep.
    #
    # One streaming pass over the chunk's two bitmaps — `occ &= mark`, popcount
    # both — and the four numbers the policy below needs fall out of it. No
    # block header is read at all, which is the entire point: the header walk it
    # replaces is O(blocks) and this is O(blocks/64), vectorised.
    #
    # The same pass clears `mark`, so there is no separate clear phase and no
    # per-bit clear anywhere.
    #
    # **The Phase 1 union retires here.** While the sweep walked headers, an
    # object could be marked either in the bitmap (by the trace) or in the
    # header generation (by allocate-black), and readers took the union. This
    # arm reads only the bitmap, so allocate-black must write the bitmap too —
    # which it now can, because the pool cursor holds the chunk. A bitmap-only
    # sweep with allocate-black still on the header would reclaim live objects.
    private def sweep_small_bitmap(chunk : ChunkHeader*, class_index : Int32,
                                   major : Bool, class_locked : Bool) : SmallSweepCounts
      occ = ChunkHeader.occ_bitmap(chunk)
      mark = ChunkHeader.mark_bitmap(chunk)
      return SmallSweepCounts.new(true, 0_u64, 0_u64, 0_u64) if occ.null? || mark.null?

      payload = SizeClasses.payload(class_index).to_u64
      nblocks = chunk_block_count(chunk)
      return SmallSweepCounts.new(false, 0_u64, 0_u64, 0_u64) if nblocks == 0
      words = ((nblocks + 63) >> 6).to_i32

      # Pinned through this stop-the-world: its owner was frozen inside the
      # unlocked hit path and will store into `occ` here without the class
      # lock, so the after-world walk leaves the chunk alone (marks stale
      # until the next stop-the-world zeroes them — `bitmap_settle_cursor_sets`).
      if !@world_stopped && ChunkHeader.pinned?(chunk)
        occupied = chunk_occupied_count(chunk)
        @sweep_cursor_pinned &+= 1
        return SmallSweepCounts.new(true, occupied * payload, nblocks * payload,
          (nblocks - occupied) * payload)
      end

      freed, live = if @poison_freed
                      sweep_words_poisoning(chunk, class_index, occ, mark, words, payload)
                    else
                      Kernels.sweep_words(occ, mark, words, @simd_tier)
                    end

      # No tail correction, and getting that wrong cost an afternoon: the first
      # version subtracted `(words * 64) - nblocks` from `freed` on the theory
      # that the last word's unused bits inflate it. They cannot. `freed` is
      # `popcount(occ & ~mark)`, and the allocator masks tail bits out of every
      # free mask it hands out (`chunk_free_mask`), so a tail bit is never set
      # in `occ` in the first place. Subtracting it under-counted the reclaim by
      # exactly the tail width — 32 blocks per class-3 chunk, which presented as
      # a live-object count stuck at 33 instead of 1.

      if freed > 0
        live_objects_sub(freed)
        free_bytes_add(freed * payload)
        # The header arm accounts this per block in `reclaim_small`; the
        # streaming arm has to do it from the popcount or `prof_stats` reports
        # zero bytes reclaimed for every bitmap chunk.
        @bytes_reclaimed_since_gc += freed * payload
      end

      # `sweep_words` touches no payload, so the poison pattern is written by
      # `sweep_words_poisoning` while it still has the dead bits — see there.
      #
      # Standing this whole arm down instead, which is what `@poison_freed`
      # did until 2026-09-04, hands the chunk to the header walk, and that arm
      # reclaims through the freelist without ever clearing `occ`. Under the
      # bitmap allocator nothing reads that freelist, so every reclaimed block
      # stayed occupied forever: measured 51.2 → 196.6 MB over four rounds of
      # a churn holding 1 in 500, against 51.2 → 52.0 MB with the knob off.

      # The garbage above is reclaimed regardless. But if an allocation cursor
      # is on this chunk it must not reach the empty-chunk path: a cursor is a
      # raw `ChunkHeader*` a mutator may be suspended mid-use of, and unmapping
      # or DONTNEED'ing it out from under that mutator is the `signal 11 at
      # 0x1c` (`occ_bitmap` of a freed chunk) the earlier unlocked cursor-drop
      # caused. Forcing `any_live` keeps it mapped.
      #
      # It cannot be left at that, though, and the claim that its emptiness is
      # "noticed next cycle, once the cursor has moved on" was wrong: nothing
      # moves the cursor off an empty chunk. `bitmap_refill_pool` advances only
      # when a chunk runs *out* of free blocks, which an empty one never does,
      # so with no further allocation of that (class, kind) the pin is
      # permanent — and a pinned chunk is also excluded from the HOLED/SPARSE
      # release, so its pages never go back either. Measured: 80 chunks and
      # 20 971 520 mapped bytes retained at `live_objects == 0`, RSS stuck at
      # its 13.6 MB peak where the header arm returned to 6.3 MB.
      #
      # So retire the cursor when the class lock is held, which is exactly the
      # after-world sweep — the arm that already takes
      # `freelist_lock_ptr(class_index, …)` before this call. A mutator cannot
      # be inside `bitmap_alloc_locked` for this class then, because it would
      # need that same lock, so nulling the slot cannot strand anyone. The
      # in-STW arm still pins: there the lock may be held by a frozen peer and
      # taking it is the 0.21.1 hang.
      pinned = false
      if live == 0 && bitmap_cursor_on?(chunk)
        if class_locked && bitmap_retire_cursor_on(chunk, class_index)
          @sweep_cursor_retired &+= 1
        else
          pinned = true
          @sweep_cursor_pinned &+= 1
        end
      end

      SmallSweepCounts.new(live > 0 || pinned,
        live * payload,
        nblocks * payload,
        (nblocks - live) * payload)
    end

    # `Kernels.sweep_words` with the poison pattern written into every block it
    # reclaims — identical arithmetic, word at a time.
    #
    # The pattern has to go in while the dead set still exists: the kernel
    # publishes `occ[i] = mark[i]` and clears the mark in the same store, so
    # afterwards there is nothing left that says which blocks were reclaimed,
    # and a chunk's bitmap is too large to snapshot (a 64 MiB chunk of 16-byte
    # blocks is 65 536 words). Only `GCRY_POISON_FREED=1` pays for this; the
    # SIMD kernel is untouched and remains the shipping path.
    #
    # The whole-word store is kept, and it is not incidental: a per-bit clear
    # would race a mutator setting a different bit in the same word.
    private def sweep_words_poisoning(chunk : ChunkHeader*, class_index : Int32,
                                      occ : UInt64*, mark : UInt64*, words : Int32,
                                      payload : UInt64) : {UInt64, UInt64}
      freed = 0_u64
      live = 0_u64
      # Every other poison site pairs the write with `@freelist_clean = false`,
      # and `POISON_WORD`'s note calls that pairing "the whole safety
      # argument": without it a later `malloc(clear: true)` can skip its memset
      # and hand `0xdeadf2ee…` to a caller expecting zeros. On a bitmap heap
      # `bitmap_alloc_locked` happens to store false on every allocation, but
      # its own comment marks that as temporary ("until the cursor tracks
      # cleanliness per chunk"), so the invariant is stated here rather than
      # inherited from another file.
      @freelist_clean[class_index] = false
      data_start = ChunkHeader.data_start(chunk).address
      block_bytes = @block_bytes[class_index]
      pay = payload.to_u32!
      i = 0
      while i < words
        o = occ[i]
        m = mark[i]
        dead = o & ~m
        freed &+= dead.popcount.to_u64
        live &+= m.popcount.to_u64
        occ[i] = m
        mark[i] = 0_u64
        while dead != 0
          bit = dead.trailing_zeros_count
          dead &= dead &- 1
          ordinal = (i.to_u64 << 6) &+ bit.to_u64
          user = data_start &+ ordinal &* block_bytes &+ BlockHeader::SIZE
          poison_payload(Pointer(Void).new(user), pay)
        end
        i += 1
      end
      {freed, live}
    end

    # The header-walk arm of the size-class sweep.
    #
    # Still inline loops rather than `each_block`: the yield overhead per block
    # dominated `phase_sweep` on multi-million-block HTTP heaps, and moving the
    # walk behind one call per *chunk* does not reintroduce it.
    #
    # Two modes, unchanged. When empties are being released, a discover pass
    # counts live/dead first so a fully-dead chunk skips the second O(blocks)
    # walk entirely and settles `live_objects` with one store instead of a CAS
    # per block. Otherwise a single pass reclaims as it goes.
    private def sweep_small_blocks(chunk : ChunkHeader*, class_index : Int32,
                                   major : Bool, class_locked : Bool = false) : SmallSweepCounts
      unless class_index >= 0 && class_index < SIZE_CLASS_COUNT
        # A chunk whose class we cannot read is never reclaimed from.
        return SmallSweepCounts.new(true, 0_u64, 0_u64, 0_u64)
      end

      # Old-generation chunks only. Nursery chunks keep the header
      # representation: their allocation still runs through
      # `alloc_nursery`'s freelist, so `occ` is not maintained for them — and a
      # bitmap sweep of a chunk whose `occ` is all zero would compute
      # `live == 0` and reclaim every live object in it.
      #
      # That is the plan's phasing, not an accident: nursery-on-bitmaps is
      # Phase 8, behind the page barrier work. The dispatch is per *chunk* and
      # not global precisely so the two representations can coexist while that
      # is true.
      # `GCRY_POISON_FREED=1` used to stand this arm down and let the header
      # walk run, because the streaming sweep touches no payload and an armed
      # diagnostic that does nothing is worse than one that costs a walk. But
      # the header walk reclaims through the freelist and never clears `occ`,
      # which under this allocator leaks the block permanently — so the
      # poisoning belongs *in* the arm, and `sweep_words_poisoning` does it.
      if @bitmap_alloc && !ChunkHeader.nursery?(chunk)
        return sweep_small_bitmap(chunk, class_index, major, class_locked)
      end

      any_live = false
      live_payload = 0_u64
      usable_payload = 0_u64
      # FREE payload on a fully-dead chunk (munmap free_bytes_sub).
      free_payload = 0_u64

      payload = SizeClasses.payload(class_index)
      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      cursor = ChunkHeader.data_start(chunk).as(UInt8*)
      limit = ChunkHeader.data_end(chunk).as(UInt8*)

      # When releasing empties: discover live first so fully-dead chunks
      # skip freelist link (unlink-only for pre-existing free blocks).
      if major && release_empty_chunks_this_collect?
        # Count unmarked USED + FREE payload in the discover pass so
        # fully-dead chunks skip a second O(blocks) walk.
        dead = 0_u64
        ordinal = 0_u64
        while (cursor + block_bytes) <= limit
          usable_payload += payload.to_u64
          header = cursor.as(BlockHeader*)
          if BlockHeader.free?(header)
            free_payload &+= payload.to_u64
            # FREE + marked: mid-alloc claimed from a stack root.
            if block_marked?(chunk, header, ordinal)
              any_live = true
              live_payload += payload.to_u64
            end
          else
            if uninitialised_small_block?(header)
              # Mid-`refill_size_class`: a mutator frozen inside the
              # header-init loop leaves mmap-zeroed headers — neither
              # FREE nor marked, which is exactly what the sweep
              # reclaims. The large path has had this tripwire since
              # 2026-08-24 (`sweep_large_one`); the small path could
              # reclaim the blocks AND classify the chunk fully-dead
              # into the warm/DORMANT/munmap paths under a mutator
              # still writing it. Count it, call the chunk live.
              @sweep_small_uninitialised &+= 1
              any_live = true
            elsif block_marked?(chunk, header, ordinal)
              any_live = true
              live_payload += payload.to_u64
            else
              dead &+= 1
            end
          end
          cursor += block_bytes
          ordinal &+= 1
        end
        if any_live
          cursor = ChunkHeader.data_start(chunk).as(UInt8*)
          ordinal = 0_u64
          while (cursor + block_bytes) <= limit
            header = cursor.as(BlockHeader*)
            unless BlockHeader.free?(header)
              if uninitialised_small_block?(header)
                # Counted in the discover pass; never reclaim.
              elsif block_marked?(chunk, header, ordinal)
                # No per-block clear on the bitmap path — `clear_all_marks`
                # zeroes the whole bitmap at the start of the next cycle,
                # because clearing one bit is a read-modify-write over the 63
                # other blocks sharing its word and this walk runs with
                # mutators live under lazy sweep.
                clear_block_mark(chunk, header)
              else
                reclaim_small(chunk, header, payload)
              end
            end
            cursor += block_bytes
            ordinal &+= 1
          end
        else
          # Fully-dead chunk: batch the live_objects accounting (one
          # store under STW) instead of a CAS per block.
          live_objects_sub(dead)
        end
      else
        ordinal = 0_u64
        while (cursor + block_bytes) <= limit
          usable_payload += payload.to_u64 if major
          header = cursor.as(BlockHeader*)
          unless BlockHeader.free?(header)
            if uninitialised_small_block?(header)
              # See the discover-pass comment above: a mutator frozen
              # mid-refill leaves zeroed headers; never reclaim them.
              @sweep_small_uninitialised &+= 1
              any_live = true
            elsif major || BlockHeader.nursery?(header)
              if block_marked?(chunk, header, ordinal)
                clear_block_mark(chunk, header)
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
          ordinal &+= 1
        end
      end

      SmallSweepCounts.new(any_live, live_payload, usable_payload, free_payload)
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
    # Is this range really inside the chunk it was computed from, and is that
    # chunk really inside the heap? `data_start`/`data_end` come out of the
    # chunk header, so checking the range against them proves only that the
    # header is self-consistent. If the walk stepped onto a released or
    # otherwise foreign header — the hazard every live-world chunk walk carries
    # — those bounds are whatever happens to be at that address, and the
    # `MADV_DONTNEED` built from them lands on memory that is not gcry's.
    # Re-read the block headers covering a run just before it is released. The
    # mask that chose this run was built earlier and without a lock; anything
    # that reads USED now was allocated into a page this call is about to drop.
    private def audit_page_run_live(chunk : ChunkHeader*, payload : UInt32,
                                    run_start : UInt64, run_end : UInt64) : UInt32
      live = 0_u32
      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      # This re-read is the last moment the answer is current, so it has to ask
      # the same authority the run selection asked. On a bitmap chunk the block
      # headers are stale by design — the streaming sweep never writes FREE —
      # so a header walk here disagrees with the `occ`-built mask that chose the
      # run, and the two disagreeing is worse than either being wrong alone.
      bitmap = bitmap_alloc_chunk?(chunk)
      occ = bitmap ? ChunkHeader.occ_bitmap(chunk) : Pointer(UInt64).null
      bitmap = false if occ.null?

      cursor = ChunkHeader.data_start(chunk).as(UInt8*)
      limit = ChunkHeader.data_end(chunk).as(UInt8*)
      ordinal = 0_u64
      while (cursor + block_bytes) <= limit
        b0 = cursor.address
        if b0 + block_bytes > run_start && b0 < run_end
          allocated = if bitmap
                        ((occ[ordinal >> 6] >> (ordinal & 63)) & 1_u64) != 0
                      else
                        !BlockHeader.free?(cursor.as(BlockHeader*))
                      end
          if allocated
            live &+= 1
            @page_release_live_blocks &+= 1
          end
        end
        cursor += block_bytes
        ordinal &+= 1
      end
      live
    end

    # A release range must lie inside the chunk **and above its own metadata**.
    #
    # The lower bound is `data_start`, not `base`. A chunk's `ChunkHeader` — and
    # for a large chunk the object's `BlockHeader` with the `next_free` link the
    # large freelist is threaded through — live below `data_start`, so a range
    # that reaches page 0 hands the kernel permission to discard the bookkeeping
    # that finds the chunk again. `release_large_freelist_pages_locked` did
    # exactly that until 2026-09-03, and it did it on the default post-STW path.
    #
    # Bounding here rather than only at that one call site is deliberate: every
    # other release site already rounds up from `data_start` (:615, :1059) or
    # filters on `run_start >= data0` (:803, :1175), so tightening this costs
    # them nothing and turns "remembered to start above the header" from a
    # convention into a checked property.
    private def madvise_range_ok?(chunk : ChunkHeader*, run_start : UInt64, run_end : UInt64) : Bool
      return true if @madvise_unchecked
      base = chunk.as(Void*).address
      limit = base &+ chunk.value.mapped_bytes
      data_start = ChunkHeader.data_start(chunk).address
      ok = run_start >= data_start && run_end <= limit &&
           base >= @heap_span_lo && limit <= @heap_span_hi
      @madvise_range_rejects &+= 1 unless ok
      ok
    end

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

        # Research only (`GCRY_PAGE_RELEASE_TEST_STALL_MS`, default 0): hold the
        # gap between the mask and the syscalls open on purpose.
        #
        # The defect this walk has is a window — a mutator allocating into a
        # page the mask called free before the `madvise` lands — and its natural
        # rate is both low and unstable: the same binary gave 10 of 40 in one
        # batch of `dormant_flush_race` and 2 of 40 in the next. Three candidate
        # fixes were measured against that moving baseline and none of the
        # readings could be trusted. Widening the window makes the defect
        # frequent enough to measure a fix against, and a real fix has to hold
        # it at zero *with the stall on*.
        if (stall = @page_release_test_stall_ms) > 0
          ts = uninitialized LibC::Timespec
          ts.tv_sec = typeof(ts.tv_sec).new(stall // 1000)
          ts.tv_nsec = typeof(ts.tv_nsec).new((stall % 1000) * 1_000_000)
          rem = uninitialized LibC::Timespec
          LibC.nanosleep(pointerof(ts), pointerof(rem))
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
            if run_start >= data0 && run_end <= data1 && len > 0 &&
               madvise_range_ok?(chunk, run_start, run_end)
              # The mask that chose this run was built by reading every block
              # header in the chunk with no lock, and mutators have been
              # allocating ever since. Measured: 30, 31, 5 and 41 live blocks
              # sitting in runs that were about to be dropped, against 0 with
              # the walk off. Re-read now — this is the last moment the answer
              # is current — and leave the run alone if anything is live in it.
              live_now = audit_page_run_live(chunk, payload, run_start, run_end)
              skip_run = live_now > 0 && !@page_release_unchecked
              @page_release_skipped_runs &+= 1 if skip_run
              ok = skip_run ? false : if preserve_content
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
                @page_release_bytes += len
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
          header = ChunkHeader.large_header(chunk)
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
      # A bitmap chunk has no freelist consumer: the pool cursor reads `occ`,
      # which the sweep just zeroed. Linking its blocks would double-book free
      # bytes, thread a stale freelist through the chunk, and under headerless
      # write 16-byte headers into the objects. Both empty-chunk branches of
      # the sweep call this, so the guard is here rather than at the callers.
      return if bitmap_alloc_chunk?(chunk)
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
      if ThreadListWatch.check(header.address, BlockHeader::SIZE.to_u64 &+ payload, ThreadListWatch::SITE_SWEEP, header.value.flags)
        report_thread_list_sweep(header)
      end
      user = BlockHeader.user_from(header)
      was_nursery = BlockHeader.nursery?(header)
      push_size_class_free(class_index, was_nursery, header, user, payload, swept: true)
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
