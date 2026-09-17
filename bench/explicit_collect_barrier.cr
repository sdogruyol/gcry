# Does an explicit `GC.collect` actually collect while other threads allocate?
#
# `Heap#collect` used to open with `return if @collecting`, so an explicit
# request made while **any** thread was in a cycle returned immediately — and
# silently. Measured on 20 hardware threads, asking continuously for one wall
# second (`bench/log/linux/2026-09-17-explicit-collect-noop/FINDINGS.md`):
#
#   threads   explicit calls   of those, landed a collection
#   8         1 969            226
#   32        571 342          58
#   70        85 682           6
#
# About one call in fourteen thousand at 70 threads, because a cycle there takes
# ~145 ms and the flag is up for all of it. Nothing in the return value said so.
#
# The guarantee this gates is the one a caller of `GC.collect` is entitled to:
# **when it returns, a collection has completed since the call.** The guard now
# returns early only when the calling thread is inside its *own* cycle — a
# before-collect callback, which cannot retake the non-recursive
# `@post_stw_mutex` — and waits for a peer's cycle in `run_collection` instead,
# which is where that mutex is already acquired.
#
# `pause_count` is the observable: every major collection stops the world, so a
# completed cycle moves it. Attribution does not matter here and asserting it
# would be wrong — the guarantee is "a collection completed", not "yours ran".
#
# Three arms, each a bounded child:
#
#   busy      `CALLS` explicit collects with `THREADS` threads allocating hard.
#             **Every** call must be followed by a higher `pause_count`. This is
#             the gate. One call would not be: at the pre-fix rate a single call
#             lands about one run in 14 000, so a one-call arm would have passed
#             by luck often enough to look green.
#
#   skip      the same with `GCRY_COLLECT_SKIP_WHEN_BUSY=1`, the pre-fix guard.
#             At least one call must come back with **no** collection, which is
#             the guarantee being absent. Fails if the knob stops restoring it.
#
#   quiet     the same call count with no other threads. Every call must land
#             there too — that is what stops the busy arm from passing because
#             `pause_count` moves for some reason unrelated to the request.
#
#   crystal build -Dgc_none bench/explicit_collect_barrier.cr -o bin/explicit_collect_barrier
#   bin/explicit_collect_barrier
#   bin/explicit_collect_barrier --child=busy

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "explicit_collect_barrier requires -Dgc_none (gcry as process GC)" %}
{% end %}

HEAP = Gcry.default_heap.not_nil!

# Enough allocating threads that a cycle is in flight nearly all the time — at
# 32 the measured hit rate was already 1 in 9 850. Not so many that a small
# runner spends its time scheduling.
THREADS = 32

# Twenty, not one: the pre-fix behaviour is probabilistic, so a single call
# proves nothing in either direction. Twenty consecutive successes are
# impossible pre-fix (the rate is ~1e-4) and guaranteed post-fix.
CALLS = 20

ARM_BUDGET = 90.seconds

child_arm = ARGV.find(&.starts_with?("--child=")).try(&.split('=', 2)[1])

ARGV.each do |arg|
  next if arg.starts_with?("--child=")
  STDERR.puts "unknown argument #{arg.inspect}: this harness takes no arguments (it drives " \
              "its arms as bounded children) or exactly one --child=busy|skip|quiet."
  exit 64
end

unless child_arm
  exe = Process.executable_path.not_nil!
  # Every arm asserts its own reading and exits 0 when it sees it — including
  # `skip`, whose reading is that the guarantee is *absent*. (The Darwin resume
  # gate next door uses the other convention: one contract in the child and the
  # parent flipping what it expects per arm. Mixing the two is how this file
  # first reported a failure while all three arms printed `ok`.)
  arms = [
    {"busy", {} of String => String},
    {"skip", {"GCRY_COLLECT_SKIP_WHEN_BUSY" => "1"}},
    {"quiet", {} of String => String},
  ]
  failures = [] of String
  puts "=== does an explicit collect collect? ==="
  arms.each do |(arm, env)|
    result = BoundedChild.run(exe, ["--child=#{arm}"], env, ARM_BUDGET)
    result.output.each_line do |line|
      puts "  #{line.rstrip}" unless line.strip.empty?
    end
    next if result.ok

    failures << if result.timed_out
      "#{arm}: outlived its #{ARM_BUDGET.total_seconds.to_i}s budget — a collect that " \
      "waits for a peer must not wait forever"
    else
      "#{arm}: see the arm's own output above"
    end
  end
  puts ""
  if failures.empty?
    puts "ok — #{CALLS} consecutive explicit collects each completed a collection with " \
         "#{THREADS} threads allocating, the pre-fix guard demonstrably loses that, and the " \
         "same #{CALLS} calls land on an idle process too."
    exit 0
  end
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end

unless child_arm.in?("busy", "skip", "quiet")
  STDERR.puts "unknown arm #{child_arm.inspect}: expected busy, skip or quiet."
  exit 64
end

quiet = child_arm == "quiet"
skip_arm = child_arm == "skip"
want = quiet ? 0 : THREADS

if skip_arm && !HEAP.collect_skip_when_busy
  STDERR.puts "the skip arm needs GCRY_COLLECT_SKIP_WHEN_BUSY=1; without it this arm would run " \
              "the shipped guard and require a guarantee it is supposed to be missing."
  exit 64
end

puts "arm #{child_arm}: #{want} allocating threads, #{CALLS} explicit collects, " \
     "#{HEAP.collect_skip_when_busy ? "pre-fix skip-when-busy" : "shipped"} guard"

stop = Atomic(Int32).new(0)
started = Atomic(Int32).new(0)
threads = [] of Thread
want.times do
  threads << Thread.new do
    started.add(1)
    held = [] of String
    while stop.get == 0
      held << "x" * 32
      held.clear if held.size > 64
    end
  end
end
while started.get < want
  Thread.sleep(1.millisecond)
end
# Let the peers get a cycle going, so the busy arm is actually busy when it asks.
sleep 200.milliseconds if want > 0

landed = 0
missed = 0
CALLS.times do
  before = HEAP.pause_count
  GC.collect
  if HEAP.pause_count > before
    landed += 1
  else
    missed += 1
  end
end

stop.set(1)
threads.each(&.join)

puts "landed=#{landed}/#{CALLS} missed=#{missed} " \
     "pause_p50=#{(HEAP.pause_percentile_ns(50.0) / 1_000_000.0).round(2)}ms"

failures = [] of String

if skip_arm
  if missed == 0
    failures << "all #{CALLS} calls completed a collection with the pre-fix guard in place, so " \
                "this arm is not restoring it — with #{THREADS} threads allocating the measured " \
                "pre-fix rate was about 1 call in 9 850"
  end
else
  if missed > 0
    failures << "#{missed} of #{CALLS} explicit collects returned without a collection having " \
                "completed — that is `GC.collect` doing nothing and not saying so"
  end
end

if failures.empty?
  puts skip_arm ? "ok — the pre-fix guard loses the guarantee, as it must for the gate above to mean anything" \
                   : "ok — every explicit collect completed a collection"
  exit 0
end

failures.each { |f| STDERR.puts "  - #{f}" }
exit 1
