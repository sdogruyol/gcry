require "../../../../src/gcry"
# A Primes-like graph in a library heap: n nodes, each a 48-byte block holding
# a pointer to an 80-byte "hash" block, which points at a 64-byte "entries"
# block holding up to 4 child-node pointers. Conservative scan throughout.
n = (ARGV[0]? || "200000").to_i
reps = (ARGV[1]? || "3").to_i
heap = Gcry::Heap.new
heap.gc_threshold = UInt64::MAX
nodes = Array(Void*).new(n)
n.times do
  node = heap.malloc(48)
  hash = heap.malloc(80)
  entries = heap.malloc(64)
  node.as(Void**)[1] = hash
  hash.as(Void**)[2] = entries
  nodes << node
end
rng = Random.new(1)
n.times do |i|
  next if i == 0
  parent = nodes[rng.rand(i)]
  entries = parent.as(Void**)[1].as(Void**)[2].as(Void**)
  4.times do |k|
    if entries[k].null?
      entries[k] = nodes[i]
      break
    end
  end
end
heap.add_root(nodes[0])
nodes.clear
t0 = Time.instant
reps.times { heap.collect(scan_stack: false) }
dt = (Time.instant - t0).total_milliseconds / reps
puts "n=#{n} objects=#{n * 3} collect_ms=#{dt.round(1)} ns/obj=#{(dt * 1_000_000 / (n * 3)).round(1)} live=#{heap.live_objects}"
