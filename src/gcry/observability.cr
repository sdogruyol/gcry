# HTTP helpers that expose gcry metrics (JSON + Prometheus).
# Use under `-Dgc_none` after `require "gcry"`.
#
#   get "/metrics" { Gcry.prometheus_text }
#   get "/gc-stats" { Gcry::Observability.json_stats }

require "json"

module Gcry
  module Observability
    # Full dogfood snapshot (same fields as historical Kemal `/gc-stats`).
    def self.json_stats(heap : Heap = Gcry.default_heap) : String
      p = PauseStats.new(
        heap.last_pause_ns,
        heap.max_pause_ns,
        heap.total_pause_ns,
        heap.pause_count,
        heap.pause_percentile_ns(50.0),
        heap.pause_percentile_ns(99.0),
      )
      {
        collections:               heap.collections,
        major_collections:         heap.major_collections,
        minor_collections:         heap.minor_collections,
        heap_size:                 heap.heap_size,
        free_bytes:                heap.free_bytes,
        bytes_since_gc:            heap.bytes_since_gc,
        unmapped_bytes:            heap.unmapped_bytes,
        live_objects:              heap.live_objects,
        pause_count:               p.count,
        pause_last_ns:             p.last_ns,
        pause_p50_ns:              p.p50_ns,
        pause_p99_ns:              p.p99_ns,
        pause_max_ns:              p.max_ns,
        pause_total_ns:            p.total_ns,
        phase_clear_ns:            heap.last_phase_clear_ns,
        phase_roots_ns:            heap.last_phase_roots_ns,
        phase_static_ns:           heap.last_phase_static_ns,
        phase_stacks_ns:           heap.last_phase_stacks_ns,
        phase_mark_ns:             heap.last_phase_mark_ns,
        phase_sweep_ns:            heap.last_phase_sweep_ns,
        large_free_bytes:          heap.large_free_bytes,
        large_mapped_bytes:        heap.large_mapped_bytes,
        small_mapped_bytes:        heap.small_mapped_bytes,
        small_free_bytes:          heap.small_free_bytes,
        large_cache_retain:        heap.large_cache_retain,
        size_class_chunk_count:    heap.size_class_chunk_count,
        fully_free_chunk_bytes:    heap.fully_free_chunk_bytes,
        released_chunk_bytes:      heap.released_chunk_bytes,
        size_class_live_bytes:     heap.size_class_live_bytes,
        chunk_fill_lt25:           heap.chunk_fill_lt25,
        chunk_fill_lt50:           heap.chunk_fill_lt50,
        chunk_fill_lt75:           heap.chunk_fill_lt75,
        chunk_fill_ge75:           heap.chunk_fill_ge75,
        small_chunk_bytes:         heap.small_chunk_bytes,
        soft_dirty_armed:          heap.soft_dirty_armed?,
        soft_dirty_page_scans:     heap.soft_dirty_page_scans,
        soft_dirty_fallbacks:      heap.soft_dirty_fallbacks,
        soft_dirty_last_dirty:     heap.last_soft_dirty_pages,
        soft_dirty_last_total:     heap.last_soft_dirty_total,
        soft_dirty_max_pct:        heap.soft_dirty_max_pct,
        dormant_chunk_bytes:       heap.dormant_chunk_bytes,
        dontneed_bytes:            heap.dontneed_bytes,
        empty_chunk_retain:        heap.empty_chunk_retain,
        layout_precise_scans:      heap.layout_precise_scans,
        layout_conservative_scans: heap.layout_conservative_scans,
        layout_entries:            Layout.size,
        type_id_root_rejects:      heap.type_id_root_rejects,
        sp_clamp_hits:             heap.sp_clamp_hits,
        sp_clamp_fallbacks:        heap.sp_clamp_fallbacks,
        finalizer_entries:         heap.finalizer_entry_count,
        weak_links:                heap.finalizer_link_count,
        blacklist_hits:            heap.blacklist_hits,
        blacklist_skips:           heap.blacklist_skips,
        tlab_refills:              heap.tlab_refills,
        tlab_steals:               heap.tlab_steals,
        parallel_mark_workers:     heap.parallel_mark_workers,
        parallel_mark_runs:        heap.parallel_mark_runs,
        parallel_mark_stolen:      heap.parallel_mark_stolen,
        clear_stack_calls:         heap.clear_stack_calls,
        clear_stack_bytes_total:   heap.clear_stack_bytes_total,
        fiber_scrub_runs:          heap.fiber_scrub_runs,
        fiber_scrub_bytes_total:   heap.fiber_scrub_bytes_total,
        barrier_backend:           heap.barrier_backend_name,
        barrier_dirty_rescans:     heap.barrier_dirty_rescans,
      }.to_json
    end

    def self.prometheus(heap : Heap = Gcry.default_heap, prefix : String = "gcry") : String
      Gcry.prometheus_text(heap, prefix)
    end
  end
end
