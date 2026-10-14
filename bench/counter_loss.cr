# Do the process heap's counters lose updates?
#
#   bin/counter_loss          # shipped counters: the walk and the counter agree
#   bin/counter_loss --plain  # red: plain set(get + n) forced; a loss must be seen
#
# A lost update is the one counter error that never comes back: `live_objects`
# stays off by the update it dropped, and `bytes_since_gc` drifting low delays a
# collection by exactly the bytes it forgot. So this compares the counter with a
# walk of the heap (`Invariant.live_objects_drift`) only at quiescent points —
# every spawned thread joined, the reading the same twice 10 ms apart — and the
# verdict is the drift still there at the end.
#
# Until 2026-10-14 the harness counted mismatches after every allocation and
# had two arms, "atomic" and "plain", that were the same code: the plain arm
# cleared `heap_counters_atomic`, and the bitmap allocator — every default
# build since the headerless layout — implies atomic counters regardless
# (`Heap#counters_atomic?`). Its one failure, 1 "lost increment" in 983 361
# comparisons on macos-15-intel CI, was not a lost update: a lost update is
# counted again at every comparison after it, as the old `--inject` arm showed
# (884 952 of 983 249). It was the Monitor or the idle thread allocating in its
# birth, caught between an occupancy bit and its counter credit while off the
# CPU (`Heap#concurrent_mutators?` has the Linux reproduction).
#
# The red arm takes the plain branch where the default layout has one to take
# (`Heap#debug_plain_counters`), and the workload makes threads race on the
# heap-wide counters rather than on their own cursor sets: `THREADS` defaults
# past `MAX_CURSOR_SETS`, so the last threads share the fallback set, whose
# every allocation is a locked one that bumps the heap's counters directly,
# and every thread frees three of every four blocks it allocates, a batch at
# a time. A free subtracts at once while the allocation it pairs with waits
# in a cursor set for its credit, so the frees drive the heap-wide counter
# down to zero, which is where the shipped arm lost decrements until
# 2026-10-14 (`Heap#live_objects_sub`): the counter 3 to 10 above the walk at
# the end of 10 of 10 runs on 12 CPUs, and 1 or 2 above in 2 of 6 on 3. That
# bug's own gate is process_spec/regression/76; this arm's job is to stay
# exact.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "counter_loss requires -Dgc_none (gcry as process GC)" %}
{% end %}

ROUNDS = (ENV["COUNTER_LOSS_ROUNDS"]?.try(&.to_i?) || 6)
# Past the cursor-set table by 16, so at least that many threads share the
# fallback set even after main, the Monitor and the idle thread take theirs.
THREADS    = (ENV["COUNTER_LOSS_THREADS"]?.try(&.to_i?) || Gcry::Heap::MAX_CURSOR_SETS + 16)
PER_THREAD = (ENV["COUNTER_LOSS_PER_THREAD"]?.try(&.to_i?) || 2048)
# Main alone with the runtime threads, as in the v0.20.0 and macOS sightings.
MAIN_PER_ROUND = 4096
SIZES          = {16, 32, 48, 64, 96, 128, 256}
BATCH          = 256

heap = Gcry.default_heap.not_nil!
plain = ARGV.includes?("--plain")
heap.debug_plain_counters = plain

# Walk minus counter once two readings 10 ms apart agree. A thread between an
# occupancy bit and its counter credit moves the reading; a lost update does
# not. Nil if it never settles, which makes the run inconclusive.
def settled_drift(heap : Gcry::Heap) : Int64?
  last = nil
  200.times do
    d = Gcry::Invariant.live_objects_drift(heap)
    return d if d && d == last
    last = d
    sleep 10.milliseconds
  end
  nil
end

puts "=== do the process heap's counters lose updates? ==="
puts "counters: #{plain ? "plain set(get + n), forced (`debug_plain_counters`)" : "shipped"}"
puts "rounds: #{ROUNDS}, main #{MAIN_PER_ROUND} alone, then #{THREADS} threads x #{PER_THREAD} (3 in 4 freed)"
puts ""

live = [] of Array(UInt8)
drifts = [] of Int64
ROUNDS.times do
  MAIN_PER_ROUND.times { live << Array(UInt8).new(32, 2_u8) }
  live.clear if live.size > MAIN_PER_ROUND * 8

  ready = Atomic(Int32).new(0)
  go = Atomic(Int32).new(0)
  born = Array(Thread).new(THREADS) do |t|
    Thread.new do
      batch = Pointer(Void*).malloc(BATCH)
      ready.add(1)
      until go.get == 1
        Thread.yield
      end
      i = 0
      while i < PER_THREAD
        j = 0
        while j < BATCH
          batch[j] = GC.malloc(SIZES[(i &+ j &+ t) % SIZES.size])
          j += 1
        end
        j = 0
        while j < BATCH
          GC.free(batch[j]) unless j & 3 == 0
          j += 1
        end
        i += BATCH
      end
    end
  end
  until ready.get == THREADS
    Thread.yield
  end
  go.set(1)
  born.each(&.join)
  GC.collect

  d = settled_drift(heap)
  unless d
    puts "INCONCLUSIVE the walk and the counter never held still for 10 ms with every"
    puts "spawned thread joined: something is still allocating, so no reading is a loss."
    exit 1
  end
  drifts << d
end

sleep 100.milliseconds
final = settled_drift(heap)
unless final
  puts "INCONCLUSIVE the final reading never held still."
  exit 1
end
lossy = drifts.count { |d| d != 0 }
puts "cursor sets in the table:  #{heap.cursor_set_count} of #{Gcry::Heap::MAX_CURSOR_SETS}"
puts "drift per round (walk - counter): #{drifts.join(" ")}"
puts "drift at the end:          #{final}"
puts ""

# The table only grows, and a new entry is made only when none is free, so a
# full table with every spawned thread alive at once puts the rest on the
# fallback set.
if heap.cursor_set_count < Gcry::Heap::MAX_CURSOR_SETS
  puts "INCONCLUSIVE the cursor-set table never filled (#{heap.cursor_set_count} of #{Gcry::Heap::MAX_CURSOR_SETS}),"
  puts "so no thread took the shared fallback set this workload exists to race."
  exit 1
end

if plain
  if lossy == 0 && final == 0
    puts "FAIL plain counters lost nothing in #{ROUNDS} rounds of #{THREADS} racing threads."
    puts "This arm is the gate's red direction: without a loss here, the shipped"
    puts "arm's zero cannot be told from a workload that no longer races the counters."
    exit 1
  end
  puts "ok — plain counters drifted in #{lossy} of #{ROUNDS} rounds, #{final} at the end:"
  puts "the comparison sees a lost update, so the shipped arm's zero is a measurement."
  exit 0
end

if final != 0
  puts "FAIL the counter is off the walk by #{final} with every thread joined and the"
  puts "reading held still: a lost update, which every GC decision reading `live_objects`"
  puts "or `bytes_since_gc` is built on."
  exit 1
end
if lossy > 0
  puts "ok — #{lossy} round(s) read a drift that was gone by the end: an update in"
  puts "flight, not a lost one."
  exit 0
end
puts "ok — the counter agreed with the walk at every round and at the end."
exit 0
