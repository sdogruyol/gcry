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
# Each measurement is made at a moment this harness has **observed** a
# collection to be in flight — `heap.collecting?` — and not at one it hopes for.
# The first version of this file arranged the in-flight window with 32 threads
# allocating hard, which works on a 20-core host and does not on a 4-vCPU CI
# runner: there the threads allocate too slowly to keep the collector busy, so
# the pre-fix guard let every call through and the **red arm came out green**
# (run 35226882013). A gate whose red direction depends on the host's core count
# is not a gate. The window is now created structurally, by a thread that does
# nothing but collect.
#
# Three arms, each a bounded child:
#
#   busy      `CALLS` explicit collects, each issued while a peer collection is
#             in flight. **Every** one must be followed by a higher
#             `pause_count`. This is the gate.
#
#   skip      the same with `GCRY_COLLECT_SKIP_WHEN_BUSY=1`, the pre-fix guard.
#             Calls issued in that window must come back with **no** collection
#             completed — that is the guarantee being absent. Fails if the knob
#             stops restoring it.
#
#   quiet     the same call count with nothing else running, where there is no
#             window to be inside. Every call must land there too — that is what
#             stops the busy arm from passing because `pause_count` moves for
#             some reason unrelated to the request.
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

# Four threads allocating, only so a collection has something to do, plus one
# thread that calls `GC.collect` in a loop and therefore holds a cycle in flight
# essentially all the time. The in-flight window is that thread's doing, not the
# allocators' — which is the whole correction over the first version.
THREADS = 4

# Twenty, not one: the pre-fix behaviour is probabilistic in the small gap
# between one cycle ending and the next beginning, so a single call proves
# nothing in either direction.
CALLS = 20

# How long to wait for the collector thread to actually have a cycle in flight
# before making a measurement. Generous: on a 4-vCPU runner a cycle of this
# heap takes ~350 ms, so most of the wait is the *previous* cycle finishing.
INFLIGHT_WAIT = 10.seconds

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

puts "arm #{child_arm}: #{want} allocating threads#{quiet ? "" : " + one collector thread"}, " \
     "#{CALLS} explicit collects, " \
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

# The window. This thread does nothing but collect, so `collecting?` is true
# almost all of the time — on any host, which is the point. Note it works under
# the knob too: the skipping guard only refuses a call made while *someone else*
# is collecting, and this thread is the someone else.
unless quiet
  threads << Thread.new do
    started.add(1)
    while stop.get == 0
      GC.collect
    end
  end
end

while started.get < threads.size
  Thread.sleep(1.millisecond)
end

landed = 0
missed = 0
not_inflight = 0
CALLS.times do
  unless quiet
    # Measure at an observed moment, not a hoped-for one.
    deadline = Time.instant + INFLIGHT_WAIT
    until HEAP.collecting?
      if Time.instant >= deadline
        not_inflight += 1
        break
      end
      Thread.sleep(100.microseconds)
    end
  end

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
     "asked_without_a_cycle_in_flight=#{not_inflight} " \
     "pause_p50=#{(HEAP.pause_percentile_ns(50.0) / 1_000_000.0).round(2)}ms"

failures = [] of String

# Precondition for both non-quiet arms: if the collector thread never had a
# cycle in flight, neither reading below is about asking during one.
if !quiet && not_inflight == CALLS
  failures << "not one of the #{CALLS} measurements found a collection in flight within " \
              "#{INFLIGHT_WAIT.total_seconds.to_i}s, so the collector thread is not collecting " \
              "and this arm measures nothing"
end

if skip_arm
  if missed == 0
    failures << "all #{CALLS} calls completed a collection with the pre-fix guard in place, so " \
                "this arm is not restoring it — a call issued while a peer is collecting is " \
                "supposed to return having done nothing"
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
