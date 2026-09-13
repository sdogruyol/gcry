# What would the parked-fiber lag stop costing if it went away?
#
# `ROADMAP.md`, the largest open pause item: 8.4 ms of a 9.2 ms p50 pause at
# Kemal `-c100` is `roots_fibers_ns`, because under multi-mutator STW every
# parked fiber is scanned from 256 KiB below its saved `stack_top` — a fiber in
# transit may report a stale one, so the lag is a bound on how far below to
# look. The proposed fix:
#
#   > a fully parked fiber (wait queue, no owning thread) has a trustworthy SP
#   > and can be scanned from it as on EC1; only fibers in transit need the lag
#
# That is a change to the root scan, i.e. the part where being wrong is a
# use-after-free days later, and it should not be attempted on an estimate. This
# measures the payoff first: `fiber_lag_window_bytes` is the distance between
# each parked fiber's saved `stack_top` and where its scan actually started,
# summed — exactly the bytes the fix would stop reading, after the low-water
# skip has already removed whatever pages were never faulted.
#
#   bin/fiber_lag_cost              # Parallel execution context, parked fibers
#   bin/fiber_lag_cost --lag=0      # the classic full parked scan, for contrast
#
# Counting, not timing, so it holds on a loaded host.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "fiber_lag_cost requires -Dgc_none (gcry as process GC)" %}
{% end %}

FIBERS      = (ENV["LAG_FIBERS"]?.try(&.to_i?) || 256)
COLLECTIONS = (ENV["LAG_COLLECTIONS"]?.try(&.to_i?) || 20)
# Each fiber recurses this deep before parking, so its stack has frames a scan
# has to cover. A fiber parked at the top of an empty stack costs nothing to
# scan and would make the measurement say the lag is free.
DEPTH = 64
# The arm that defeats the pagemap skip. A fiber that first recurses deep and
# *then* parks shallow leaves its stack faulted below the lag floor, so the
# low-water probe finds a present page there and has nothing to skip — which is
# the "pooled stacks lose it over time" case the roadmap names, reproduced on a
# single fiber rather than waiting for a pool to churn.
DEEP_BYTES = (ENV["LAG_DEEP_BYTES"]?.try(&.to_i?) || 512 * 1024)

heap = Gcry.default_heap.not_nil!

# Touch `bytes` of stack and return, leaving those pages faulted.
@[NoInline]
def touch_deep(bytes : Int32) : Int32
  pad = uninitialized UInt8[4096]
  pad[0] = 1_u8
  pad[4095] = 1_u8
  return pad[0].to_i if bytes <= 4096
  touch_deep(bytes - 4096) + pad[4095].to_i
end

@[NoInline]
def sink(depth : Int32, ch : Channel(Nil)) : Nil
  # Locals the conservative scan has to walk on the way down.
  pad = uninitialized UInt8[512]
  pad[depth & 511] = depth.to_u8
  if depth > 0
    sink(depth - 1, ch)
  else
    # Parked here: on a channel's wait queue, owned by no thread, which is the
    # case the proposal is about.
    ch.receive
  end
  pad[0] = pad[depth & 511]
end

puts "=== what the parked-fiber lag reads ==="
puts "#{FIBERS} fibers parked #{DEPTH} frames deep, #{COLLECTIONS} collections, " \
     "lag #{heap.stw_multi_stack_lag} bytes"
puts ARGV.includes?("--deep") ? "each fiber touched #{DEEP_BYTES // 1024} KiB of stack first, then parked shallow" : "stacks never touched below the parked frames"
puts ""

ch = Channel(Nil).new
# A Parallel context, because the lag only applies under multi-mutator STW —
# with one mutator the scan takes the cheap `stack_top` clamp instead.
ctx = Fiber::ExecutionContext::Parallel.new("lag-cost", maximum: 4)
deep = ARGV.includes?("--deep")
FIBERS.times do
  ctx.spawn do
    touch_deep(DEEP_BYTES) if deep
    sink(DEPTH, ch)
  end
end
sleep 300.milliseconds

# `low_water_skips` and `low_water_skipped_bytes` are **reset every
# collection** (`collect.cr`'s per-collection reset), which cost this harness a
# wrong conclusion: read after N collections they show the last one only, and
# "266 skips whether the run does 1 collection or 20" looked like a skip that
# fires once per fiber. It is a counter that forgets. Read per collection and
# summed here instead.
scans0 = heap.fiber_lag_scans
bytes0 = heap.fiber_lag_window_bytes
misses0 = heap.low_water_misses
unprobed0 = heap.low_water_unprobed
skips = 0_u64
skipped = 0_u64
COLLECTIONS.times do
  GC.collect
  skips += heap.low_water_skips
  skipped += heap.low_water_skipped_bytes
end
scans = heap.fiber_lag_scans - scans0
bytes = heap.fiber_lag_window_bytes - bytes0
misses = heap.low_water_misses - misses0
unprobed = heap.low_water_unprobed - unprobed0

FIBERS.times { ch.send(nil) }

puts "parked-fiber scans that paid the lag: #{scans}"
puts "bytes between saved SP and scan start: #{bytes}"
puts "low-water skips inside those windows:  #{skips}, #{skipped} bytes already skipped"
puts "probe ran and found nothing to skip:   #{misses}"
puts "probe not run (lag floor above stack):  #{unprobed}"
puts ""

if scans == 0
  puts "INCONCLUSIVE no parked fiber paid the lag in #{COLLECTIONS} collections. Either the"
  puts "context never became multi-mutator — the lag only applies under multi-mutator STW —"
  puts "or the fibers were not parked when the collections ran. Nothing here measures the"
  puts "proposal's payoff, so it cannot be used to justify touching the root scan."
  exit 1
end

per_collection = bytes.to_f / COLLECTIONS
skipped_per_collection = skipped.to_f / COLLECTIONS
read_per_collection = per_collection - skipped_per_collection
puts "nominal lag window:  #{(per_collection / 1024).round(1)} KiB per collection across #{(scans / COLLECTIONS)} parked scans"
puts "removed by the skip: #{(skipped_per_collection / 1024).round(1)} KiB per collection"
puts "actually read:       #{(read_per_collection / 1024).round(1)} KiB per collection"
puts ""
if read_per_collection <= per_collection * 0.1
  puts "ok — the pagemap low-water skip already removes the lag window here, so scanning a"
  puts "parked fiber from its own SP would save close to nothing on this workload. The"
  puts "proposal's case is the workload where the skip *cannot* help: a stack faulted below"
  puts "the lag floor by an earlier deep call, which `--deep` reproduces."
  exit 0
end
puts "the skip cannot help here: #{(read_per_collection / 1024 / (scans / COLLECTIONS)).round(1)} KiB per parked fiber is read on every"
puts "collection, and that is what scanning a fully parked fiber from its own saved SP"
puts "would stop reading. probe ran and found nothing to skip: #{misses}; probe not run: #{unprobed}."
puts ""
puts "The fix is a root-scan change — being wrong there is a use-after-free days later — so"
puts "this is the argument for doing it, not a substitute for doing it carefully. The"
puts "predicate for \"genuinely parked, not in transit\" is the difficulty."
exit 0
