# Benchmark-only factorial policy control. Never required by the collector.
# Effective values are visible in /gc-stats and the benchmark result.
module HeaderPolicyExperiment
  def self.apply(heap : Gcry::Heap) : Nil
    mode = ENV["BENCH_HEADER_POLICY"]?
    return unless mode
    abort "header policy experiment requires the header allocator" if heap.bitmap_alloc?
    abort "unknown BENCH_HEADER_POLICY=#{mode}" unless {"base", "warm", "adaptive", "coupled"}.includes?(mode)
    return if mode == "base"
    if mode == "adaptive" || mode == "coupled"
      heap.gc_threshold = Gcry::Heap::ADAPTIVE_THRESHOLD_MIN
      heap.adaptive_threshold = true
    end
    if mode == "warm" || mode == "coupled"
      heap.empty_chunk_warm_retain = heap.gc_threshold
      heap.warm_retain_follows_live = true
    else
      heap.empty_chunk_warm_retain = 0_u64
      heap.warm_retain_follows_live = false
    end
  end
end
