# Extended GC observability for process GC and library heaps.
# Prefer `Gcry.metrics` / Prometheus text from `Gcry.prometheus_text`.
# Rich JSON for HTTP: `Gcry::Observability.json_stats`.

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
    getter phase_mark_ns : UInt64
    getter phase_sweep_ns : UInt64
    getter type_id_root_rejects : UInt64
    getter blacklist_hits : UInt64
    getter blacklist_skips : UInt64
    getter tlab_refills : UInt64
    getter tlab_steals : UInt64
    getter parallel_mark_workers : Int32
    getter parallel_mark_runs : UInt64
    getter parallel_mark_stolen : UInt64
    getter layout_precise_scans : UInt64
    getter layout_conservative_scans : UInt64
    getter layout_entries : Int32
    getter sp_clamp_hits : UInt64
    getter sp_clamp_fallbacks : UInt64
    getter barrier_backend : String
    getter barrier_dirty_rescans : UInt64
    getter size_class_live_bytes : UInt64
    getter small_mapped_bytes : UInt64
    getter released_chunk_bytes : UInt64

    def initialize(
      @collections : UInt64, @major_collections : UInt64, @minor_collections : UInt64,
      @heap_size : UInt64, @free_bytes : UInt64, @unmapped_bytes : UInt64,
      @bytes_since_gc : UInt64, @live_objects : UInt64,
      @pause_count : UInt64, @pause_last_ns : UInt64, @pause_p50_ns : UInt64,
      @pause_p99_ns : UInt64, @pause_max_ns : UInt64, @pause_total_ns : UInt64,
      @phase_mark_ns : UInt64, @phase_sweep_ns : UInt64,
      @type_id_root_rejects : UInt64, @blacklist_hits : UInt64, @blacklist_skips : UInt64,
      @tlab_refills : UInt64, @tlab_steals : UInt64,
      @parallel_mark_workers : Int32, @parallel_mark_runs : UInt64, @parallel_mark_stolen : UInt64,
      @layout_precise_scans : UInt64, @layout_conservative_scans : UInt64,
      @layout_entries : Int32, @sp_clamp_hits : UInt64, @sp_clamp_fallbacks : UInt64,
      @barrier_backend : String, @barrier_dirty_rescans : UInt64,
      @size_class_live_bytes : UInt64, @small_mapped_bytes : UInt64, @released_chunk_bytes : UInt64,
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
      heap.last_phase_mark_ns,
      heap.last_phase_sweep_ns,
      heap.type_id_root_rejects,
      heap.blacklist_hits,
      heap.blacklist_skips,
      heap.tlab_refills,
      heap.tlab_steals,
      heap.parallel_mark_workers,
      heap.parallel_mark_runs,
      heap.parallel_mark_stolen,
      heap.layout_precise_scans,
      heap.layout_conservative_scans,
      Layout.size,
      heap.sp_clamp_hits,
      heap.sp_clamp_fallbacks,
      heap.barrier_backend_name,
      heap.barrier_dirty_rescans,
      heap.size_class_live_bytes,
      heap.small_mapped_bytes,
      heap.released_chunk_bytes,
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
      io << "# HELP #{prefix}_size_class_live_bytes Live payload in size-class chunks\n"
      io << "# TYPE #{prefix}_size_class_live_bytes gauge\n"
      io << "#{prefix}_size_class_live_bytes #{m.size_class_live_bytes}\n"
      io << "# HELP #{prefix}_small_mapped_bytes Mapped size-class bytes\n"
      io << "# TYPE #{prefix}_small_mapped_bytes gauge\n"
      io << "#{prefix}_small_mapped_bytes #{m.small_mapped_bytes}\n"
      io << "# HELP #{prefix}_released_chunk_bytes Cumulative empty-chunk munmap\n"
      io << "# TYPE #{prefix}_released_chunk_bytes counter\n"
      io << "#{prefix}_released_chunk_bytes #{m.released_chunk_bytes}\n"
      io << "# HELP #{prefix}_pause_seconds STW pause samples\n"
      io << "# TYPE #{prefix}_pause_seconds summary\n"
      io << "#{prefix}_pause_seconds{quantile=\"0.5\"} #{m.pause_p50_ns / 1_000_000_000.0}\n"
      io << "#{prefix}_pause_seconds{quantile=\"0.99\"} #{m.pause_p99_ns / 1_000_000_000.0}\n"
      io << "#{prefix}_pause_seconds_sum #{m.pause_total_ns / 1_000_000_000.0}\n"
      io << "#{prefix}_pause_seconds_count #{m.pause_count}\n"
      io << "# HELP #{prefix}_phase_mark_seconds Last major mark phase\n"
      io << "# TYPE #{prefix}_phase_mark_seconds gauge\n"
      io << "#{prefix}_phase_mark_seconds #{m.phase_mark_ns / 1_000_000_000.0}\n"
      io << "# HELP #{prefix}_phase_sweep_seconds Last major sweep phase\n"
      io << "# TYPE #{prefix}_phase_sweep_seconds gauge\n"
      io << "#{prefix}_phase_sweep_seconds #{m.phase_sweep_ns / 1_000_000_000.0}\n"
      io << "# HELP #{prefix}_type_id_root_rejects_total Ambient roots rejected by type_id gate\n"
      io << "# TYPE #{prefix}_type_id_root_rejects_total counter\n"
      io << "#{prefix}_type_id_root_rejects_total #{m.type_id_root_rejects}\n"
      io << "# HELP #{prefix}_blacklist_hits_total Pages recorded as false roots\n"
      io << "# TYPE #{prefix}_blacklist_hits_total counter\n"
      io << "#{prefix}_blacklist_hits_total #{m.blacklist_hits}\n"
      io << "# HELP #{prefix}_blacklist_skips_total Freelist pages skipped via blacklist\n"
      io << "# TYPE #{prefix}_blacklist_skips_total counter\n"
      io << "#{prefix}_blacklist_skips_total #{m.blacklist_skips}\n"
      io << "# HELP #{prefix}_tlab_refills_total TLAB freelist refills\n"
      io << "# TYPE #{prefix}_tlab_refills_total counter\n"
      io << "#{prefix}_tlab_refills_total #{m.tlab_refills}\n"
      io << "# HELP #{prefix}_tlab_steals_total TLAB steals from other threads\n"
      io << "# TYPE #{prefix}_tlab_steals_total counter\n"
      io << "#{prefix}_tlab_steals_total #{m.tlab_steals}\n"
      io << "# HELP #{prefix}_parallel_mark_workers Requested mark workers\n"
      io << "# TYPE #{prefix}_parallel_mark_workers gauge\n"
      io << "#{prefix}_parallel_mark_workers #{m.parallel_mark_workers}\n"
      io << "# HELP #{prefix}_parallel_mark_runs_total Collections that requested parallel mark\n"
      io << "# TYPE #{prefix}_parallel_mark_runs_total counter\n"
      io << "#{prefix}_parallel_mark_runs_total #{m.parallel_mark_runs}\n"
      io << "# HELP #{prefix}_parallel_mark_stolen_total Grey objects stolen by helpers\n"
      io << "# TYPE #{prefix}_parallel_mark_stolen_total counter\n"
      io << "#{prefix}_parallel_mark_stolen_total #{m.parallel_mark_stolen}\n"
      io << "# HELP #{prefix}_layout_entries Layout table size\n"
      io << "# TYPE #{prefix}_layout_entries gauge\n"
      io << "#{prefix}_layout_entries #{m.layout_entries}\n"
      io << "# HELP #{prefix}_layout_precise_scans_total Objects scanned via layout tables\n"
      io << "# TYPE #{prefix}_layout_precise_scans_total counter\n"
      io << "#{prefix}_layout_precise_scans_total #{m.layout_precise_scans}\n"
      io << "# HELP #{prefix}_sp_clamp_hits_total Other-thread stacks clamped to SP\n"
      io << "# TYPE #{prefix}_sp_clamp_hits_total counter\n"
      io << "#{prefix}_sp_clamp_hits_total #{m.sp_clamp_hits}\n"
      io << "# HELP #{prefix}_barrier_dirty_rescans_total Dirty-page rescans before sweep\n"
      io << "# TYPE #{prefix}_barrier_dirty_rescans_total counter\n"
      io << "#{prefix}_barrier_dirty_rescans_total #{m.barrier_dirty_rescans}\n"
      io << "# HELP #{prefix}_barrier_backend Info label for active barrier\n"
      io << "# TYPE #{prefix}_barrier_backend gauge\n"
      io << "#{prefix}_barrier_backend{name=\"#{m.barrier_backend}\"} 1\n"
    end
  end
end
