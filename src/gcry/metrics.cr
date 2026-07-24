# Extended GC observability for process GC and library heaps.
# Prefer `Gcry.metrics` / Prometheus text from `Gcry.prometheus_text`.

module Gcry
  struct Metrics
    getter collections : UInt64
    getter major_collections : UInt64
    getter minor_collections : UInt64
    getter heap_size : UInt64
    getter free_bytes : UInt64
    getter unmapped_bytes : UInt64
    getter bytes_since_gc : UInt64
    getter live_objects : UInt64
    getter pause_count : UInt64
    getter pause_last_ns : UInt64
    getter pause_p50_ns : UInt64
    getter pause_p99_ns : UInt64
    getter pause_max_ns : UInt64
    getter pause_total_ns : UInt64
    getter type_id_root_rejects : UInt64
    getter blacklist_hits : UInt64
    getter blacklist_skips : UInt64
    getter tlab_refills : UInt64
    getter layout_precise_scans : UInt64
    getter layout_conservative_scans : UInt64
    getter layout_entries : Int32
    getter sp_clamp_hits : UInt64
    getter barrier_backend : String

    def initialize(
      @collections : UInt64, @major_collections : UInt64, @minor_collections : UInt64,
      @heap_size : UInt64, @free_bytes : UInt64, @unmapped_bytes : UInt64,
      @bytes_since_gc : UInt64, @live_objects : UInt64,
      @pause_count : UInt64, @pause_last_ns : UInt64, @pause_p50_ns : UInt64,
      @pause_p99_ns : UInt64, @pause_max_ns : UInt64, @pause_total_ns : UInt64,
      @type_id_root_rejects : UInt64, @blacklist_hits : UInt64, @blacklist_skips : UInt64,
      @tlab_refills : UInt64, @layout_precise_scans : UInt64, @layout_conservative_scans : UInt64,
      @layout_entries : Int32, @sp_clamp_hits : UInt64, @barrier_backend : String,
    )
    end
  end

  def self.metrics(heap : Heap = default_heap) : Metrics
    p = PauseStats.new(
      heap.last_pause_ns,
      heap.max_pause_ns,
      heap.total_pause_ns,
      heap.pause_count,
      heap.pause_percentile_ns(50.0),
      heap.pause_percentile_ns(99.0),
    )
    Metrics.new(
      heap.collections,
      heap.major_collections,
      heap.minor_collections,
      heap.heap_size,
      heap.free_bytes,
      heap.unmapped_bytes,
      heap.bytes_since_gc,
      heap.live_objects,
      p.count,
      p.last_ns,
      p.p50_ns,
      p.p99_ns,
      p.max_ns,
      p.total_ns,
      heap.type_id_root_rejects,
      heap.blacklist_hits,
      heap.blacklist_skips,
      heap.tlab_refills,
      heap.layout_precise_scans,
      heap.layout_conservative_scans,
      Layout.size,
      heap.sp_clamp_hits,
      heap.barrier_backend_name,
    )
  end

  # Prometheus exposition format (no extra dependency).
  def self.prometheus_text(heap : Heap = default_heap, prefix : String = "gcry") : String
    m = metrics(heap)
    String.build do |io|
      io << "# HELP #{prefix}_collections_total GC collection cycles\n"
      io << "# TYPE #{prefix}_collections_total counter\n"
      io << "#{prefix}_collections_total #{m.collections}\n"
      io << "# HELP #{prefix}_major_collections_total Major GC cycles\n"
      io << "# TYPE #{prefix}_major_collections_total counter\n"
      io << "#{prefix}_major_collections_total #{m.major_collections}\n"
      io << "# HELP #{prefix}_minor_collections_total Minor GC cycles\n"
      io << "# TYPE #{prefix}_minor_collections_total counter\n"
      io << "#{prefix}_minor_collections_total #{m.minor_collections}\n"
      io << "# HELP #{prefix}_heap_bytes Heap size in bytes\n"
      io << "# TYPE #{prefix}_heap_bytes gauge\n"
      io << "#{prefix}_heap_bytes #{m.heap_size}\n"
      io << "# HELP #{prefix}_free_bytes Free bytes on freelists\n"
      io << "# TYPE #{prefix}_free_bytes gauge\n"
      io << "#{prefix}_free_bytes #{m.free_bytes}\n"
      io << "# HELP #{prefix}_unmapped_bytes Cumulative munmap bytes\n"
      io << "# TYPE #{prefix}_unmapped_bytes gauge\n"
      io << "#{prefix}_unmapped_bytes #{m.unmapped_bytes}\n"
      io << "# HELP #{prefix}_live_objects Approximate live object count\n"
      io << "# TYPE #{prefix}_live_objects gauge\n"
      io << "#{prefix}_live_objects #{m.live_objects}\n"
      io << "# HELP #{prefix}_pause_seconds STW pause samples\n"
      io << "# TYPE #{prefix}_pause_seconds summary\n"
      io << "#{prefix}_pause_seconds{quantile=\"0.5\"} #{m.pause_p50_ns / 1_000_000_000.0}\n"
      io << "#{prefix}_pause_seconds{quantile=\"0.99\"} #{m.pause_p99_ns / 1_000_000_000.0}\n"
      io << "#{prefix}_pause_seconds_sum #{m.pause_total_ns / 1_000_000_000.0}\n"
      io << "#{prefix}_pause_seconds_count #{m.pause_count}\n"
      io << "# HELP #{prefix}_type_id_root_rejects_total Ambient roots rejected by type_id gate\n"
      io << "# TYPE #{prefix}_type_id_root_rejects_total counter\n"
      io << "#{prefix}_type_id_root_rejects_total #{m.type_id_root_rejects}\n"
      io << "# HELP #{prefix}_blacklist_hits_total Pages recorded as false roots\n"
      io << "# TYPE #{prefix}_blacklist_hits_total counter\n"
      io << "#{prefix}_blacklist_hits_total #{m.blacklist_hits}\n"
      io << "# HELP #{prefix}_layout_entries Layout table size\n"
      io << "# TYPE #{prefix}_layout_entries gauge\n"
      io << "#{prefix}_layout_entries #{m.layout_entries}\n"
    end
  end
end
