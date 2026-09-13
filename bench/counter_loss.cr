# Do the process heap's counters lose updates, and does the atomic path fix it?
#
# `note_alloc_bytes` and its siblings use plain `set(get + 1)` unless
# `heap_counters_atomic` is set, and `heap.cr` calls that safe on the grounds of
# "single mutator + rare SYSMON". `ROADMAP.md` has carried the counter-argument
# since v0.20.0: with the invariant checker on, the process heap's
# `live_objects` read **permanently one below** the walk in 3 runs of 40, in a
# program whose only threads were main and the monitor. A lost increment is not
# a sampling race — it never comes back — and `bytes_since_gc` drifting low
# delays a collection by exactly the bytes it forgot.
#
# That flake was fixed as a *scope* correction: the invariant is now stated only
# of a heap that keeps its counter (`Heap#counters_may_lose_updates?`), which
# made the checker honest without making the counter right. So this harness
# states it anyway (`GCRY_INVARIANT_COUNTER_LOSS=1`) and counts, which is the
# measurement the correction retired:
#
#   bin/counter_loss            # counters atomic: no loss may be counted
#   bin/counter_loss --control  # plain counters:  loss must be counted
#
# The double read inside the checker still guards both arms — a counter that
# *moves* between the two reads is a sampling race and is skipped — so what this
# counts is a lost increment and not a walk racing an allocation.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "counter_loss requires -Dgc_none (gcry as process GC)" %}
{% end %}

ROUNDS = (ENV["COUNTER_LOSS_ROUNDS"]?.try(&.to_i?) || 400)
# Zero by default, and that is the faithful shape: the sighting this measures
# was in "a program whose only threads are main and the monitor". Spawned
# mutators make `concurrent_mutators?` true, which skips the comparison for a
# reason that has nothing to do with the counter — measured 406 300 skips
# against 1 636 comparisons with two of them, i.e. the harness was asking the
# question 0.4% of the time. `COUNTER_LOSS_THREADS` puts them back for anyone
# who wants the racier shape.
THREADS = (ENV["COUNTER_LOSS_THREADS"]?.try(&.to_i?) || 0)
# Allocation per round, small and scalar: the counter is bumped per object, so
# what matters is the number of allocations racing the monitor thread, not their
# size.
PER_ROUND = (ENV["COUNTER_LOSS_PER_ROUND"]?.try(&.to_i?) || 4096)

heap = Gcry.default_heap.not_nil!
control = ARGV.includes?("--control")
# The detector's own positive control. Both real arms come out at zero — which
# is the finding — so without this the harness cannot tell "the counter is
# exact" from "the comparison never looks". `debug_drift_live_objects` moves the
# counter without touching a block, which is the only way to produce a drift on
# purpose: every real path keeps the counter and the headers together.
inject = ARGV.includes?("--inject")

# The arms differ in one property. The checker is forced in both, because a
# comparison that only runs on one arm is not a comparison.
heap.heap_counters_atomic = !control
Gcry::Invariant.enable
Gcry::Invariant.force_counters

puts "=== do the process heap's counters lose updates? ==="
puts "counters: #{control ? "plain set(get + 1) — the shipped default" : "atomic"}#{inject ? ", with one increment dropped on purpose" : ""}"
puts "rounds: #{ROUNDS}, #{PER_ROUND} allocations each, #{THREADS} spawned thread(s) + the monitor"
puts ""

live = [] of Array(UInt8)
dropped = false
ROUNDS.times do |round|
  # One lost increment, a tenth of the way in, so the arm exercises the same
  # walk as the others and then has something to find.
  if inject && !dropped && round == ROUNDS // 10
    heap.debug_drift_live_objects(-1_i64)
    dropped = true
  end
  born = [] of Thread
  if THREADS > 0
    THREADS.times do
      born << Thread.new do
        mine = [] of Array(UInt8)
        (PER_ROUND // THREADS).times { mine << Array(UInt8).new(32, 1_u8) }
        mine.size
      end
    end
  end
  PER_ROUND.times { live << Array(UInt8).new(32, 2_u8) }
  live.clear if live.size > PER_ROUND * 8
  GC.collect
  born.each(&.join)
end

losses = Gcry::Invariant.counter_losses
checks = Gcry::Invariant.live_object_checks
skips = Gcry::Invariant.concurrent_skips
puts "comparisons that agreed:   #{checks}"
puts "comparisons skipped:       #{skips}"
puts "counter losses:            #{losses}"
puts ""

if checks + losses == 0
  puts "INCONCLUSIVE the checker never got a comparison in: every walk was skipped, so neither"
  puts "arm measured anything. The workload has stopped producing quiescent moments, or"
  puts "`force_counters` is not reaching the counter half of the skip."
  exit 1
end

if inject
  if losses == 0
    puts "FAIL one increment was dropped on purpose and the comparison did not notice, in"
    puts "#{checks + losses} walks. The detector is the thing under test here: without it the"
    puts "other two arms' zeros mean nothing at all."
    exit 1
  end
  puts "ok — the dropped increment was caught, at #{losses} of #{checks + losses} comparisons:"
  puts "once the counter is short it stays short, which is exactly what distinguishes a lost"
  puts "increment from a sampling race. The other arms' zeros are a measurement, not a blind spot."
  exit 0
end

if control
  if losses == 0
    # Not a failure: this *is* the measurement. The roadmap carried "3 runs of
    # 40" from v0.20.0 and it does not reproduce — 4.6 M forced comparisons
    # across three shapes, zero losses — so the plain counter stays the default
    # and the atomic path stays an escape rather than becoming one.
    puts "ok — plain counters lost nothing in #{checks + losses} comparisons. The loss this"
    puts "harness was built for does not reproduce on this tree; `--inject` is what says the"
    puts "comparison would have seen it."
    exit 0
  end
  puts "FAIL plain counters lost #{losses} increment(s) in #{checks + losses} comparisons"
  puts "(#{(losses * 100.0 / (checks + losses)).round(2)}%) — the loss is back, and every GC decision that"
  puts "reads `live_objects` or `bytes_since_gc` is built on it. `GCRY_HEAP_COUNTERS_ATOMIC=1`"
  puts "is the escape; making it the default costs at most 2-3% on ns/alloc (measured)."
  exit 1
end

if losses > 0
  puts "FAIL atomic counters lost #{losses} increment(s) in #{checks + losses} comparisons. The"
  puts "counter is supposed to be exact on this path: every GC decision that reads"
  puts "`live_objects` or `bytes_since_gc` is built on it, and a lost increment never"
  puts "comes back."
  exit 1
end
puts "ok — atomic counters agreed with the walk in all #{checks} comparisons."
exit 0
