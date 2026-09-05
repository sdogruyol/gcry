require "../../src/gcry"
require "json"
# ns per 48-byte GC.malloc on N threads, each keeping a 4096-slot ring live.
# Usage: alloc_ns <threads> <allocs_per_thread> <bytes> [atomic]
# Original PR #34 scratch benchmark: same 4096-slot ring and per-thread timer.
# Defaults preserve its workload. Sizes and kinds are new selectable controls.
threads = (ARGV[0]? || "1").to_i
per = (ARGV[1]? || "5000000").to_i
size = (ARGV[2]? || "48").to_i
atomic = ARGV[3]? == "atomic"
abort "threads, allocations and bytes must be positive" if threads <= 0 || per <= 0 || size <= 0
ready = Atomic(Int32).new(0)
done = Atomic(Int32).new(0)
go = Atomic(Int32).new(0)
ns = Array(Int64).new(threads, 0_i64)
ths = Array(Thread).new(threads) do |t|
  Thread.new do
    ring = Array(Void*).new(4096, Pointer(Void).null)
    ready.add(1)
    while go.get == 0
      Thread.yield
    end
    t0 = Time.instant
    i = 0
    while i < per
      ring[i & 4095] = atomic ? GC.malloc_atomic(size) : GC.malloc(size)
      i += 1
    end
    ns[t] = (Time.instant - t0).total_nanoseconds.to_i64
    done.add(1)
  end
end
while ready.get < threads
  Thread.yield
end
h = Gcry.default_heap.not_nil!
collections_before = h.collections
pause_before = h.total_pause_ns
wall_start = Time.instant
go.set(1)
while done.get < threads
  Thread.yield
end
ths.each(&.join)
wall_ns = (Time.instant - wall_start).total_nanoseconds.to_i64
puts({
  bench: "alloc_ns", threads: threads, allocations_per_thread: per, bytes: size, atomic: atomic,
  ring_slots: 4096, wall_ns: wall_ns,
  ns_per_alloc: ns.sum.to_f / threads / per,
  aggregate_ns_per_alloc: wall_ns.to_f / threads / per,
  per_thread_ns: ns, collections: h.collections - collections_before,
  pause_total_ns: h.total_pause_ns - pause_before,
  cursor_hits: h.fast_path_objects, bitmap_locked_allocations: h.bitmap_alloc_fast,
  refills: h.bitmap_alloc_refills, chunk_advances: h.bitmap_alloc_chunk_advances,
  pinned: h.cursor_sets_pinned, retired: h.cursor_sets_retired,
}.to_json)
