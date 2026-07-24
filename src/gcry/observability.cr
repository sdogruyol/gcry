# HTTP helpers that expose gcry metrics (JSON + Prometheus).
# Use under `-Dgc_none` after `require "gcry"`.
#
#   get "/metrics" { Gcry.prometheus_text }
#   get "/gc-stats" { Gcry::Observability.json_stats }

require "json"

module Gcry
  module Observability
    def self.json_stats(heap : Heap = Gcry.default_heap) : String
      m = Gcry.metrics(heap)
      {
        collections:               m.collections,
        major_collections:         m.major_collections,
        minor_collections:         m.minor_collections,
        heap_size:                 m.heap_size,
        free_bytes:                m.free_bytes,
        unmapped_bytes:            m.unmapped_bytes,
        bytes_since_gc:            m.bytes_since_gc,
        live_objects:              m.live_objects,
        pause_count:               m.pause_count,
        pause_last_ns:             m.pause_last_ns,
        pause_p50_ns:              m.pause_p50_ns,
        pause_p99_ns:              m.pause_p99_ns,
        pause_max_ns:              m.pause_max_ns,
        pause_total_ns:            m.pause_total_ns,
        type_id_root_rejects:      m.type_id_root_rejects,
        blacklist_hits:            m.blacklist_hits,
        blacklist_skips:           m.blacklist_skips,
        tlab_refills:              m.tlab_refills,
        layout_precise_scans:      m.layout_precise_scans,
        layout_conservative_scans: m.layout_conservative_scans,
        layout_entries:            m.layout_entries,
        sp_clamp_hits:             m.sp_clamp_hits,
        barrier_backend:           m.barrier_backend,
      }.to_json
    end

    def self.prometheus(heap : Heap = Gcry.default_heap, prefix : String = "gcry") : String
      Gcry.prometheus_text(heap, prefix)
    end
  end
end
