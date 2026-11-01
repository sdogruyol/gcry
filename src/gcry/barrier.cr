# Official page-granularity write-barrier layer for nursery / incremental mark.
# Soft-dirty is preferred; mprotect+SEGV is the opt-in / process-GC fallback.

{% if flag?(:linux) %}
  require "./platform/linux_softdirty"
  require "./platform/linux_mprotect"
{% end %}

module Gcry
  class Heap
    # Active remembered-set backend (None ⇒ full old scan / unsound incremental).
    property barrier_backend : Platform::BarrierBackend = Platform::BarrierBackend::None
    # Force mprotect even when soft-dirty works (tests / kernels without soft-dirty).
    property prefer_mprotect_barrier : Bool = false
    # Allow mprotect fallback when soft-dirty is unavailable (process GC default-on).
    property allow_mprotect_barrier : Bool = false
    getter barrier_dirty_rescans : UInt64 = 0_u64
    getter barrier_full_fallbacks : UInt64 = 0_u64
    # Incremental cycles whose termination scan failed (returned false, or
    # took the barrier down) and that finished in a full collection
    # (`collect_a_little`).
    getter inc_barrier_lost_collections : UInt64 = 0_u64

    def barrier_backend_name : String
      case @barrier_backend
      when .soft_dirty? then "soft_dirty"
      when .mprotect?   then "mprotect"
      else                   "none"
      end
    end

    # Select backend. Soft-dirty first; mprotect only when preferred or allowed
    # (never hijack SIGSEGV on library heaps unless explicitly requested).
    protected def select_barrier_backend : Platform::BarrierBackend
      {% if flag?(:linux) %}
        if @prefer_mprotect_barrier
          return Platform::BarrierBackend::Mprotect if Platform.install_mprotect_barrier
        end

        if @soft_dirty_max_pct > 0 && (@scan_static_roots || @nursery_enabled || @incremental_auto || @inc_active)
          unless @soft_dirty_probed
            @soft_dirty_works = Platform.clear_soft_dirty && soft_dirty_tracks_writes?
            @soft_dirty_probed = true
          end
          if @soft_dirty_works && !@soft_dirty_skip_until_major
            return Platform::BarrierBackend::SoftDirty
          end
        end

        if (@prefer_mprotect_barrier || @allow_mprotect_barrier) && Platform.install_mprotect_barrier
          return Platform::BarrierBackend::Mprotect
        end
      {% end %}
      Platform::BarrierBackend::None
    end

    # After a major: arm the page barrier for the next cycle if a nursery or
    # sliced majors will read it, and otherwise take down whatever an earlier
    # cycle armed. Until 2026-10-08 the second half was missing: a heap whose
    # `incremental_auto` (or nursery) was turned off kept the barrier the last
    # sliced cycle armed for good — on aarch64 mprotect over every old chunk,
    # write faults included — and the large-object recycler, which refuses
    # while any barrier is armed, never ran again
    # (`process_spec/regression/46_large_recycle_untouched_pages_spec.cr`
    # after `27_boehm_collect_parity_spec`'s sliced example, aarch64 CI).
    protected def arm_page_barrier_after_major : Nil
      if @nursery_enabled || @incremental_auto
        arm_page_barrier_after_collect
      elsif !@barrier_backend.none?
        disarm_mprotect_barrier if @barrier_backend.mprotect?
        @barrier_backend = Platform::BarrierBackend::None
        @soft_dirty_armed = false
      end
    end

    # Arm remembered set after a collect (or at incremental begin).
    protected def arm_page_barrier_after_collect : Nil
      # Whatever the last arm protected is unprotected before anything else
      # is chosen. The cards are about to be replaced, and a page still
      # read-only under cards that no longer list it faults with nothing to
      # claim it. A collection that moved from mprotect to soft-dirty used to
      # leave such pages behind, with the handler still installed.
      disarm_mprotect_barrier if @barrier_backend.mprotect?

      # Library heaps without process roots: keep full old→young scan (predictable tests).
      unless @scan_static_roots || @prefer_mprotect_barrier || @allow_mprotect_barrier
        @barrier_backend = Platform::BarrierBackend::None
        @soft_dirty_armed = false
        return
      end

      @barrier_backend = select_barrier_backend
      case @barrier_backend
      when .soft_dirty?
        @soft_dirty_armed = Platform.clear_soft_dirty
      when .mprotect?
        @soft_dirty_armed = false
        # No cards, no barrier: nothing was protected, so nothing would be
        # recorded, and a dirty-page scan finding no bits would report a
        # quiet heap. See `arm_mprotect_on_old_chunks`.
        drop_mprotect_without_cards unless arm_mprotect_on_old_chunks
      else
        @soft_dirty_armed = false
      end
      Trace.barrier_arm(barrier_backend_name) unless @barrier_backend.none?
    end

    # False when it leaves no cards: an empty heap, or
    # `mprotect_set_heap_range` gave up (a span over its page limit, or
    # `malloc` refused). `mprotect_protect_range` then protects nothing.
    private def arm_mprotect_on_old_chunks : Bool
      {% if flag?(:linux) %}
        return false if @heap_max == 0 || @heap_min == UInt64::MAX
        Platform.mprotect_set_heap_range(@heap_min, @heap_max)
        return false unless Platform.mprotect_cards_cover?(@heap_min, @heap_max)
        Platform.clear_mprotect_dirty_bits
        each_chunk do |chunk|
          next if ChunkHeader.nursery?(chunk)
          next if ChunkHeader.dormant?(chunk)
          low = chunk.address
          high = chunk.address + chunk.value.mapped_bytes
          Platform.mprotect_protect_range(low, high)
        end
        true
      {% else %}
        false
      {% end %}
    end

    # An mprotect arm that left no cards takes the backend down to `None`,
    # so every reader sees no barrier rather than a blind one: the nursery
    # keeps its full old→young walk, `begin_incremental` declines to start
    # a cycle, and an incremental cycle whose termination scan rebuilt the
    # cards and lost them finishes with a full stop-the-world collection
    # (`collect_a_little`). Until 2026-11-02 the backend stayed `Mprotect`:
    # the scans saw no dirty bits and reported success, and an incremental
    # cycle swept objects whose only reference was stored after the arm.
    # (Before the same day's clip in `mprotect_protect_range` the pages were
    # protected anyway and the first write died instead.)
    # `process_spec/regression/99_mprotect_protect_outside_cards_spec.cr`.
    private def drop_mprotect_without_cards : Nil
      {% if flag?(:linux) %}
        return unless Platform.mprotect_drop_without_cards
      {% end %}
      @barrier_backend = Platform::BarrierBackend::None
    end

    # Also called with the world running — the re-arm after a lazy sweep,
    # `abort_incremental` — while fault handlers may be running on other
    # threads against the cards and protection it replaces. The handler
    # side copes with that (`platform/linux_mprotect.cr`, above
    # `@@mp_state`): the cards are freed once no handler is inside, and a
    # handler that straddles the swap leaves its page recorded or protected.
    protected def disarm_mprotect_barrier : Nil
      {% if flag?(:linux) %}
        each_chunk do |chunk|
          low = chunk.address
          high = chunk.address + chunk.value.mapped_bytes
          Platform.mprotect_unprotect_range(low, high)
        end
        Platform.clear_mprotect_cards
      {% end %}
    end

    # Scan dirty pages. nursery_only=true → old→young; false → incremental rematerialize.
    # Returns true when the dirty-page path completed (caller may skip full scan).
    protected def scan_dirty_pages_for_pointers(nursery_only : Bool) : Bool
      case @barrier_backend
      when .soft_dirty?
        scan_softdirty_pages(nursery_only)
      when .mprotect?
        scan_mprotect_pages(nursery_only)
      else
        false
      end
    end

    private def scan_softdirty_pages(nursery_only : Bool) : Bool
      {% if flag?(:linux) %}
        return false unless @soft_dirty_armed && @soft_dirty_max_pct > 0

        dirty = 0_u64
        total = 0_u64
        pagemap_ok = true
        each_chunk do |chunk|
          low = chunk.address
          high = chunk.address + chunk.value.mapped_bytes
          counts = Platform.count_soft_dirty_pages(low, high)
          unless counts
            pagemap_ok = false
            break
          end
          d, t = counts
          dirty += d
          total += t
        end
        @last_soft_dirty_pages = dirty
        @last_soft_dirty_total = total
        return false unless pagemap_ok && total > 0

        # dirty==0: either no old→young stores, or soft-dirty missed them (seen
        # on WSL under release HTTP). Returning true here skipped the full
        # old→young walk and swept live Hash keys → SEGV at 0x4 in String.
        return false if dirty == 0

        if dirty * 100 > total * @soft_dirty_max_pct.to_u64
          @soft_dirty_fallbacks += 1
          @barrier_full_fallbacks += 1
          @soft_dirty_skip_until_major = true
          @soft_dirty_armed = false
          return false
        end

        scan_ok = true
        each_chunk do |chunk|
          low = chunk.address
          high = chunk.address + chunk.value.mapped_bytes
          ok = Platform.each_dirty_page(low, high) do |page|
            scan_range_for_barrier_pointers(
              Pointer(Void).new(page),
              Pointer(Void).new(page + Platform::PAGE_SIZE),
              nursery_only,
            )
          end
          unless ok
            scan_ok = false
            break
          end
        end
        if scan_ok
          @soft_dirty_page_scans += 1
          @barrier_dirty_rescans += 1
          true
        else
          false
        end
      {% else %}
        false
      {% end %}
    end

    private def scan_mprotect_pages(nursery_only : Bool) : Bool
      {% if flag?(:linux) %}
        dirty, total = Platform.count_mprotect_dirty_pages
        @last_soft_dirty_pages = dirty
        @last_soft_dirty_total = total
        if total > 0 && @soft_dirty_max_pct > 0 && dirty * 100 > total * @soft_dirty_max_pct.to_u64
          @barrier_full_fallbacks += 1
          # Too dirty — unprotect and let caller full-scan.
          disarm_mprotect_barrier
          @barrier_backend = Platform::BarrierBackend::None
          return false
        end
        # Through the chunks the heap holds now, not every dirty bit in the
        # cards. A bit outlives the chunk it was set in: a cached large
        # chunk the arm protected is written when the allocation path trims
        # the cache (`detach_large_cache` claims its first page) and then
        # unmapped (`release_large_chain`), all between two collections, and
        # its page stays dirty in cards with no chunk under it any more.
        # Reading that page faulted with nothing mapped there (`SEGV_MAPERR`,
        # never the barrier's), and the minor died in the forwarded fault.
        # A dormant chunk holds no objects to find.
        # `process_spec/regression/99_mprotect_protect_outside_cards_spec.cr`.
        if Platform.mprotect_dirty_scan_by_chunk
          each_chunk do |chunk|
            next if ChunkHeader.dormant?(chunk)
            Platform.each_mprotect_dirty_page(chunk.address, chunk.address + chunk.value.mapped_bytes) do |page|
              scan_range_for_barrier_pointers(
                Pointer(Void).new(page),
                Pointer(Void).new(page + Platform::PAGE),
                nursery_only,
              )
            end
          end
        else
          Platform.each_mprotect_dirty_page(0_u64, UInt64::MAX) do |page|
            scan_range_for_barrier_pointers(
              Pointer(Void).new(page),
              Pointer(Void).new(page + Platform::PAGE),
              nursery_only,
            )
          end
        end
        Platform.clear_mprotect_dirty_bits
        # Re-arm RO on old chunks for the next mutator window — under cards
        # that cover them. The cards were sized to the heap at the arm, and a
        # chunk mapped since then can lie below or above them (a large
        # allocation's own mapping, typically below on Linux). Protecting it
        # under the old cards made a page no fault could claim, and the
        # sweep's first write to it — the chunk-list rebuild's link in its
        # header (`ChunkHeader.link`) — died in the forwarded fault;
        # `mprotect_protect_range` now protects only what the cards cover.
        #
        # An incremental slice that does not finish lets the mutators run
        # under this protection, so there a heap that has outgrown the cards
        # gets new ones, as the arm makes them: every chunk unprotected,
        # cards sized to the heap now, the old chunks protected again — or,
        # if no cards can be had, no barrier, and the cycle finishes with a
        # full collection (`drop_mprotect_without_cards`). Inside the stop,
        # after the dirty bits were taken above. A minor needs no rebuild:
        # it ends in `arm_page_barrier_after_collect`, which replaces these
        # cards before any mutator write can matter, and the rebuild would
        # only lengthen its pause.
        # `process_spec/regression/99_mprotect_protect_outside_cards_spec.cr`.
        if nursery_only || !Platform.mprotect_cards_cover_protection ||
           !Platform.mprotect_rebuild_outgrown_cards || Platform.mprotect_cards_cover?(@heap_min, @heap_max)
          each_chunk do |chunk|
            next if ChunkHeader.nursery?(chunk)
            next if ChunkHeader.dormant?(chunk)
            Platform.mprotect_protect_range(chunk.address, chunk.address + chunk.value.mapped_bytes)
          end
        else
          disarm_mprotect_barrier
          unless arm_mprotect_on_old_chunks
            drop_mprotect_without_cards
            return false if @barrier_backend.none?
          end
        end
        @barrier_dirty_rescans += 1
        true
      {% else %}
        false
      {% end %}
    end

    private def scan_range_for_barrier_pointers(low : Void*, high : Void*, nursery_only : Bool) : Nil
      word = sizeof(Void*).to_u64
      addr = (low.address + word - 1) & ~(word - 1)
      limit = high.address
      while addr + word <= limit
        cand = Pointer(Void).new(Pointer(UInt64).new(addr).value)
        if (h = find_object(cand))
          if nursery_only
            mark_candidate(cand) if BlockHeader.nursery?(h)
          else
            # Incremental dirty re-scan: rematerialize edges into the mark stack.
            #
            # `heap_marked?` / `heap_set_mark`, not the static `BlockHeader`
            # pair. This is a live mark path, not a diagnostic: under
            # `GCRY_BITMAP=1` the static setter writes the header generation
            # byte while the *bitmap* is what the sweep reads, so the object
            # would be scanned, its children marked, and then the object itself
            # reclaimed while live. `collect_mark.cr` carries the same warning
            # for `unmarked_live_object?`; this site had not been given it.
            unless heap_marked?(h) || BlockHeader.free?(h)
              heap_set_mark(h)
              @mark_stack.push(h)
            end
          end
        end
        addr += word
      end
    end
  end
end
