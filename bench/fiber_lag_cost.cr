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

heap = Gcry.default_heap.not_nil!

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
puts ""

ch = Channel(Nil).new
# A Parallel context, because the lag only applies under multi-mutator STW —
# with one mutator the scan takes the cheap `stack_top` clamp instead.
ctx = Fiber::ExecutionContext::Parallel.new("lag-cost", maximum: 4)
FIBERS.times { ctx.spawn { sink(DEPTH, ch) } }
sleep 300.milliseconds

scans0 = heap.fiber_lag_scans
bytes0 = heap.fiber_lag_window_bytes
skips0 = heap.low_water_skips
skipped0 = heap.low_water_skipped_bytes
COLLECTIONS.times { GC.collect }
scans = heap.fiber_lag_scans - scans0
bytes = heap.fiber_lag_window_bytes - bytes0
skips = heap.low_water_skips - skips0
skipped = heap.low_water_skipped_bytes - skipped0

FIBERS.times { ch.send(nil) }

puts "parked-fiber scans that paid the lag: #{scans}"
puts "bytes between saved SP and scan start: #{bytes}"
puts "low-water skips inside those windows:  #{skips}, #{skipped} bytes already skipped"
puts ""

if scans == 0
  puts "INCONCLUSIVE no parked fiber paid the lag in #{COLLECTIONS} collections. Either the"
  puts "context never became multi-mutator — the lag only applies under multi-mutator STW —"
  puts "or the fibers were not parked when the collections ran. Nothing here measures the"
  puts "proposal's payoff, so it cannot be used to justify touching the root scan."
  exit 1
end

per_collection = bytes.to_f / COLLECTIONS
per_scan = bytes.to_f / scans
puts "per collection: #{(per_collection / 1024).round(1)} KiB across #{(scans / COLLECTIONS)} parked scans"
puts "per parked fiber: #{(per_scan / 1024).round(1)} KiB"
puts ""
puts "That is what scanning a fully parked fiber from its own saved SP would stop reading,"
puts "on top of what the low-water skip already removes. The fix itself is a root-scan"
puts "change — being wrong there is a use-after-free days later — so this number is the"
puts "argument for doing it, not a substitute for doing it carefully."
exit 0
