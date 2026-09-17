# What does starting the Nth thread cost, and does a collection make it worse?
#
# **A probe, not a gate.** It asserts one thing — that its own arms ran — and
# otherwise reports numbers. The question it exists for came out of a CI
# accident rather than a design: `bench/stack_bounds_growth.cr` asked for 100
# live threads, and on the macOS runner the arm never got all 100 *running*
# inside 120 s, twice, while the same harness's 8-thread arm was instantaneous
# and Linux did 100 in about two seconds
# (`log/linux/2026-09-16-stack-bounds-gate/FINDINGS.md`). `threads held: 100`
# never printed, so the time went into thread **startup**, not into a
# collection that followed it.
#
# The hypothesis `ROADMAP.md` carries, and what this measures:
#
#   `Thread.new` allocates. An allocation can trigger a collection. Darwin's
#   stop-the-world suspends **each** thread with its own Mach `thread_suspend`
#   / `thread_get_state` pair, where Linux broadcasts one signal and waits for
#   acknowledgements. So a thread-creation storm would pay O(n) per collection
#   and O(n**2) over the storm on Darwin, and not on Linux.
#
# It is a hypothesis with two halves, and the arms separate them:
#
#   auto=on    the shipped configuration: collections happen while the threads
#              are being created.
#   auto=off   `GCRY_DISABLE_AUTO=1`. No automatic collection, so thread
#              startup is measured without any stop-the-world in it. If
#              startup is slow here too, the collector is not the reason and
#              the hypothesis is dead.
#   collect    a dedicated thread calling `GC.collect` every 2 ms for the
#              duration of the storm.
#
# The third arm exists because the first two were measured and **could not test
# the hypothesis**: on Linux both report `collections=0`, because 100
# `Thread.new` calls do not allocate their way to the threshold. Two arms that
# differ only in a knob neither of them exercises measure the same thing twice.
# A storm that provably collects is what the prediction is about, so one arm
# has to force the collections rather than hope for them.
#
# Across a sweep of N. Linear growth in the per-thread cost is the signature to
# look for: if `us/thread` is flat in N the cost is per-thread, and if it rises
# with N the cost is per-thread-times-threads, which is the O(n**2) the
# hypothesis predicts. `collections` is reported beside it because the
# prediction is specifically about collections during the storm — a slowdown
# with `collections=0` is not this mechanism.
#
# Every (N, arm) pair is its **own bounded child**. That is the shape this
# probe's ancestor got wrong: one child sweeping every N loses the small-N data
# when the large N hangs, which is exactly the case under investigation. A pair
# that outlives its budget is reported as `TIMEOUT` and the sweep continues.
#
#   crystal build -Dgc_none bench/thread_startup_cost.cr -o bin/thread_startup_cost
#   bin/thread_startup_cost
#   BENCH_CHILD_TIMEOUT_S=30 bin/thread_startup_cost      # tighter budget

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "thread_startup_cost requires -Dgc_none (gcry as process GC)" %}
{% end %}

SWEEP = [8, 32, 64, 100]

child_spec = ARGV.find(&.starts_with?("--child="))

ARGV.each do |arg|
  next if arg.starts_with?("--child=")
  STDERR.puts "unknown argument #{arg.inspect}: this probe takes no arguments, or exactly " \
              "one --child=<n>."
  exit 64
end

# ── Child: start N threads, hold them, report ────────────────────────────────
if child_spec
  spec = child_spec.split('=', 2)[1]
  arm, _, n_s = spec.partition(':')
  want = n_s.to_i
  unless arm.in?("auto=on", "auto=off", "collect") && want > 0
    STDERR.puts "bad --child spec #{spec.inspect}: expected <arm>:<n>."
    exit 64
  end
  heap = Gcry.default_heap.not_nil!
  collections_before = heap.collections

  # The collector thread, for the arm that forces the mechanism. Started before
  # the storm and stopped after it, so every collection it takes has some
  # prefix of the threads already live — which is the cost the hypothesis is
  # about.
  collector_stop = Atomic(Int32).new(0)
  collector = if arm == "collect"
                Thread.new do
                  while collector_stop.get == 0
                    GC.collect
                    Thread.sleep(2.milliseconds)
                  end
                end
              end

  running = Atomic(Int32).new(0)
  release = Atomic(Int32).new(0)
  threads = [] of Thread

  started = Time.instant
  want.times do
    threads << Thread.new do
      running.add(1)
      # 25 ms, not microseconds: 100 threads polling at 200 us is 500 000
      # wakeups a second, which is how this probe's ancestor took a job down.
      while release.get == 0
        Thread.sleep(25.milliseconds)
      end
    end
  end
  spawned = Time.instant

  while running.get < want
    Thread.sleep(1.millisecond)
  end
  all_running = Time.instant

  release.set(1)
  threads.each(&.join)
  joined = Time.instant
  if c = collector
    collector_stop.set(1)
    c.join
  end

  collections = heap.collections - collections_before
  spawn_ms = (spawned - started).total_milliseconds
  ready_ms = (all_running - started).total_milliseconds
  join_ms = (joined - all_running).total_milliseconds
  per_thread_us = want > 0 ? ready_ms * 1000.0 / want : 0.0

  # One line, parsed by the parent. Anything human goes in the parent's table.
  puts "DATUM n=#{want} spawn_ms=#{spawn_ms.round(1)} ready_ms=#{ready_ms.round(1)} " \
       "join_ms=#{join_ms.round(1)} us_per_thread=#{per_thread_us.round(1)} " \
       "collections=#{collections}"
  exit 0
end

# ── Parent: sweep N across both arms ─────────────────────────────────────────
exe = Process.executable_path.not_nil!

puts "=== thread startup cost ==="
puts "hypothesis: Darwin suspends each thread with its own Mach pair, so a"
puts "thread-creation storm that collects pays O(n) per collection and O(n^2)"
puts "over the storm. Flat us/thread means per-thread cost; rising means the"
puts "product. `collections=0` in the auto=off arm is the control."
puts ""
printf("%-9s %-6s %10s %10s %10s %14s %12s\n",
  "arm", "n", "spawn_ms", "ready_ms", "join_ms", "us/thread", "collections")

rows = [] of Tuple(String, Int32, String)
missing = [] of String

[{"auto=on", {} of String => String},
 {"auto=off", {"GCRY_DISABLE_AUTO" => "1"}},
 {"collect", {} of String => String}].each do |(arm, env)|
  SWEEP.each do |n|
    result = BoundedChild.run(exe, ["--child=#{arm}:#{n}"], env)
    datum = result.output.each_line.find(&.starts_with?("DATUM "))
    if datum.nil?
      note = result.timed_out ? "TIMEOUT" : "no datum (exit non-zero)"
      printf("%-9s %-6d %10s %10s %10s %14s %12s\n", arm, n, note, "", "", "", "")
      missing << "#{arm} n=#{n}: #{note}"
      next
    end
    fields = datum.split.skip(1).to_h { |kv| {kv.split('=', 2)[0], kv.split('=', 2)[1]} }
    printf("%-9s %-6d %10s %10s %10s %14s %12s\n",
      arm, n, fields["spawn_ms"], fields["ready_ms"], fields["join_ms"],
      fields["us_per_thread"], fields["collections"])
    rows << {arm, n, fields["us_per_thread"]}
  end
end

puts ""

# The one assertion: the arms ran. A probe whose children all timed out has
# measured nothing, and saying "no signal" on that would be the failure this
# whole line of work is about.
answered = rows.size
if answered == 0
  STDERR.puts "FAIL: no (arm, n) pair produced a datum, so this probe measured nothing:"
  missing.each { |m| STDERR.puts "  #{m}" }
  exit 1
end

unless missing.empty?
  puts "#{missing.size} pair(s) produced no datum — that is a reading, not an error here:"
  missing.each { |m| puts "  #{m}" }
  puts ""
end

on = rows.select { |(arm, _, _)| arm == "auto=on" }
off = rows.select { |(arm, _, _)| arm == "auto=off" }
if on.size >= 2
  first = on.first[2].to_f
  last = on.last[2].to_f
  ratio = first > 0 ? last / first : 0.0
  puts "auto=on  us/thread n=#{on.first[1]} -> n=#{on.last[1]}: #{first.round(1)} -> " \
       "#{last.round(1)} (x#{ratio.round(2)})"
end
if off.size >= 2
  first = off.first[2].to_f
  last = off.last[2].to_f
  ratio = first > 0 ? last / first : 0.0
  puts "auto=off us/thread n=#{off.first[1]} -> n=#{off.last[1]}: #{first.round(1)} -> " \
       "#{last.round(1)} (x#{ratio.round(2)})"
end
col = rows.select { |(arm, _, _)| arm == "collect" }
if col.size >= 2
  first = col.first[2].to_f
  last = col.last[2].to_f
  ratio = first > 0 ? last / first : 0.0
  puts "collect  us/thread n=#{col.first[1]} -> n=#{col.last[1]}: #{first.round(1)} -> " \
       "#{last.round(1)} (x#{ratio.round(2)})"
end
puts ""
puts "read it as: a ratio near 1 is per-thread cost and kills the O(n^2) reading;"
puts "a ratio that tracks n is the product. Compare the arms before blaming the"
puts "collector — auto=off has no stop-the-world in it at all, and if the auto=on"
puts "and auto=off rows report collections=0 they are the same measurement twice:"
puts "only the collect arm exercises the mechanism the hypothesis names."
exit 0
