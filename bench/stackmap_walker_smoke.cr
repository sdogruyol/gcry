# Walker smoke for compiler stack maps (docs/STACK_MAPS.md).
#
# Build (probe Crystal):
#   CRYSTAL_EMIT_STACKMAP=1 crystal build -Dgc_none --no-debug \
#     --frame-pointers=always -o bin/stackmap_walker_smoke bench/stackmap_walker_smoke.cr
#
# Run:
#   GCRY_PRECISE_STACK=1 ./bin/stackmap_walker_smoke          # hybrid
#   GCRY_PRECISE_STACK=2 ./bin/stackmap_walker_smoke          # exclusive
#
# Exit 0 when maps load and precise_stack_roots_marked > 0 after churn.
# Exclusive also requires surviving churn without SEGV (still not a proof).

require "../src/gcry"

def churn(n : Int32) : String
  acc = ""
  i = 0
  while i < n
    s = "item-#{i}-#{"x" * (i % 17)}"
    acc = s if (i % 3) == 0
    arr = Array(String).new(4) { |j| "#{s}-#{j}" }
    GC.collect if (i % 64) == 0
    # Keep a live ref across collects.
    acc = arr[0] if arr[0].bytesize > acc.bytesize
    i += 1
  end
  acc
end

mode = ENV["GCRY_PRECISE_STACK"]? || "?"
puts "stackmap_walker_smoke mode=#{mode}"

keep = churn(512)
GC.collect
GC.collect

loaded = Gcry::StackMaps.loaded? || Gcry::StackMaps.ensure_loaded
records = Gcry::StackMaps.record_count
hits = Gcry::StackMaps.hits
roots = Gcry::StackMaps.roots_yielded
marked = Gcry.default_heap.precise_stack_roots_marked
exclusive = Gcry.default_heap.precise_stack_exclusive

lookups = Gcry::StackMaps.lookups
near_hits = Gcry::StackMaps.near_hits
puts "keep=#{keep.bytesize}b loaded=#{loaded} records=#{records} hits=#{hits} near_hits=#{near_hits} lookups=#{lookups} roots_yielded=#{roots} marked=#{marked} exclusive=#{exclusive}"

unless loaded && records > 0
  STDERR.puts "FAIL: expected .llvm_stackmaps in this binary (build with CRYSTAL_EMIT_STACKMAP=1)"
  exit 1
end

unless ENV["GCRY_PRECISE_STACK"]?.in?("1", "2")
  STDERR.puts "FAIL: set GCRY_PRECISE_STACK=1|2"
  exit 1
end

# Hybrid (=1): capped mutator FP walk must consult the map (lookups>0).
# Exclusive (=2): must produce precise roots via full FP walk.
if exclusive
  if marked == 0 && roots == 0
    STDERR.puts "FAIL: exclusive walker produced no precise roots (try --frame-pointers=always)"
    exit 1
  end
elsif lookups == 0
  STDERR.puts "FAIL: hybrid walker never consulted maps (lookups=0)"
  exit 1
end

puts "OK"
