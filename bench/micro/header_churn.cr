# Single-mutator 8 KiB churn for the header-retention factorial experiment.
# Unlike alloc_ns, this does not create a worker alongside main: doing so would
# invoke the multi-mutator release policy instead of the EC1 policy under test.
require "../../src/gcry"
require "../performance/header_policy"
require "json"

def minor_faults : UInt64
  # Fields after the final ')' start at field 3; minflt is field 10.
  stat = File.read("/proc/self/stat")
  stat[(stat.rindex(')').not_nil! + 1)..].split[7].to_u64
end

heap = Gcry.default_heap.not_nil!
HeaderPolicyExperiment.apply(heap)
count = (ARGV[0]? || "100000").to_i
abort "allocation count must be positive" if count <= 0
ring = Array(Void*).new(64, Pointer(Void).null)
5000.times { |i| ring[i % ring.size] = GC.malloc(8192) }
GC.collect
before_faults = minor_faults
before_cols = heap.collections
before_pause = heap.total_pause_ns
start = Time.instant
count.times { |i| ring[i % ring.size] = GC.malloc(8192) }
wall = (Time.instant - start).total_nanoseconds.to_u64
faults = minor_faults - before_faults
collections = heap.collections - before_cols
pause = heap.total_pause_ns - before_pause
GC.collect
puts({
  bench: "header_churn", policy: ENV["BENCH_HEADER_POLICY"]? || "base",
  allocations: count, bytes: 8192, wall_ns: wall, ns_per_alloc: wall.to_f / count,
  minflt: faults, faults_per_1k: faults.to_f * 1000 / count,
  collections: collections, pause_total_ns: pause,
  gc_threshold: heap.gc_threshold, adaptive_threshold: heap.adaptive_threshold,
  warm_budget: heap.empty_chunk_warm_retain, heap_size_after_gc: heap.heap_size,
}.to_json)
Gcry::Roots.keep_alive(ring.to_unsafe.as(Void*))
