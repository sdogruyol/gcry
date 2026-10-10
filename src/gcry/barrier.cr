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
        arm_mprotect_on_old_chunks
      else
        @soft_dirty_armed = false
      end
      Trace.barrier_arm(barrier_backend_name) unless @barrier_backend.none?
    end

    private def arm_mprotect_on_old_chunks : Nil
      {% if flag?(:linux) %}
        return if @heap_max == 0 || @heap_min == UInt64::MAX
        Platform.mprotect_set_heap_range(@heap_min, @heap_max)
        Platform.clear_mprotect_dirty_bits
        each_chunk do |chunk|
          next if ChunkHeader.nursery?(chunk)
          next if ChunkHeader.dormant?(chunk)
          low = chunk.address
          high = chunk.address + chunk.value.mapped_bytes
          Platform.mprotect_protect_range(low, high)
        end
      {% end %}
    end

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
        Platform.each_mprotect_dirty_page do |page|
          scan_range_for_barrier_pointers(
            Pointer(Void).new(page),
            Pointer(Void).new(page + Platform::PAGE),
            nursery_only,
          )
        end
        Platform.clear_mprotect_dirty_bits
        # Re-arm RO on old chunks for the next mutator window.
        each_chunk do |chunk|
          next if ChunkHeader.nursery?(chunk)
          next if ChunkHeader.dormant?(chunk)
          Platform.mprotect_protect_range(chunk.address, chunk.address + chunk.value.mapped_bytes)
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
