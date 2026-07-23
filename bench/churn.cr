# Rough pause / throughput check (library heap — no process static-root scan).
# Build: crystal build --release bench/churn.cr -o bin/churn
# Run:   ./bin/churn [rounds]

require "../src/gcry"

def with_heap(&)
  heap = Gcry::Heap.new
  heap.scan_static_roots = false
  heap.gc_threshold = UInt64::MAX
  heap.nursery_threshold = UInt64::MAX
  begin
    yield heap
  ensure
    heap.destroy
  end
end

def churn(label : String, heap : Gcry::Heap, rounds : Int32, &)
  keep = [] of Void*
  start = Time.instant
  rounds.times do |i|
    ptr = heap.malloc(48 + (i % 80))
    keep << ptr
    keep.shift if keep.size > 30
    yield i
  end
  elapsed = Time.instant - start
  puts "#{label}: rounds=#{rounds} elapsed_ms=#{elapsed.total_milliseconds.round(2)}"
end

rounds = (ARGV[0]? || "2000").to_i

with_heap do |heap|
  heap.nursery_enabled = false
  churn("full-major", heap, rounds) do |i|
    heap.collect(scan_stack: false) if i % 200 == 199
  end
  puts "  major_collections=#{heap.major_collections}"
end

with_heap do |heap|
  heap.nursery_enabled = false
  churn("incremental", heap, rounds) do |i|
    heap.collect_a_little(256) if i % 40 == 39
  end
  heap.collect(scan_stack: false)
  puts "  major_collections=#{heap.major_collections}"
end

with_heap do |heap|
  heap.nursery_enabled = true
  heap.nursery_threshold = 64_u64 * 1024
  churn("nursery-minor", heap, rounds) { }
  heap.collect(scan_stack: false)
  puts "  minor=#{heap.minor_collections} major=#{heap.major_collections}"
end

puts "done"
