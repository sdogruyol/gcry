# Does the stack-bounds snapshot still cover the 65th thread?
#
# The root scan cannot call `pthread_getattr_np` with the world stopped — that
# is the hang of 2026-08-10, six hours of a runner in `sigsuspend` — so bounds
# are snapshotted before the stop and looked up from a table inside it. That
# table was a **fixed 64 slots**. A process with more live threads than that
# visited them and had nowhere to record them, so their OS stacks were not
# scanned: `STACK_BOUNDS_INITIAL_SLOTS` is still 64, and the table doubles now.
#
# The counters are the contract, and all three are on `/gc-stats`:
#
#   stack_bounds_visited          threads the snapshot walked
#   stack_bounds_read             the subset it got bounds for
#   stack_bounds_capacity_misses  visited with nowhere to record
#
# `read == visited` and `misses == 0` is full coverage. A gap is a thread whose
# stack the root scan does not have.
#
# **Why this file exists.** `ROADMAP.md` claimed this was "gated in
# `process_spec` above the initial capacity and broken on purpose with
# `GCRY_STACK_BOUNDS_NOGROW=1` (red at `visited=150 read=130`)". It is not:
# `GCRY_STACK_BOUNDS_NOGROW` appeared in no `spec/`, no `bench/`, no recipe and
# no CI step (`log/linux/2026-09-16-orphan-break-knobs/FINDINGS.md`), one of
# eleven knobs in that state. The break was real when it was measured; nothing
# re-checked it afterwards, and the claim went stale in place. This is the gate
# the record says existed.
#
# Three arms:
#
#   hold        more live threads than the initial capacity, and a collection
#               must come out `read == visited` with zero capacity misses.
#               **This is the gate.**
#
#   --nogrow    `GCRY_STACK_BOUNDS_NOGROW=1` freezes the table at its initial
#               capacity, which is the pre-fix behaviour. The run must show the
#               loss rather than merely not crash: `read < visited` *and*
#               `misses > 0`. Requiring both is the point — a table that stopped
#               recording without counting the misses would look like full
#               coverage of fewer threads.
#
#   --control   the same collection with only the initial thread count, where
#               the fixed table was always enough. `read == visited` there too,
#               which is what stops the hold arm from passing for a reason that
#               has nothing to do with growth.
#
# What this does **not** claim: that a thread past the 64th ever held the only
# reference to something. The loss is a documented hole in that thread's
# coverage; whether anything fell into it is unmeasured, and `ROADMAP.md` says
# so. This gate asserts the coverage, not a defect.
#
# Each arm runs as a **bounded child of this process** (`BoundedChild`, the
# module written after a hung arm took an aarch64 job down for 13 minutes). This
# harness did the same thing to the Darwin job on 2026-09-16 — 18m37s, cancelled
# at the 20-minute cap — and the first attempt at bounding it from CI used
# `timeout 180`, which macOS does not have: the step died with
# `timeout: command not found`, exit 127, and `continue-on-error` reported it as
# success. A gate that can hang has to bound itself, in the harness, on every
# platform. `BENCH_CHILD_TIMEOUT_S` moves the budget.
#
#   crystal build -Dgc_none bench/stack_bounds_growth.cr -o bin/stack_bounds_growth
#   bin/stack_bounds_growth            # drives all three arms as bounded children
#   bin/stack_bounds_growth --child=hold

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "stack_bounds_growth requires -Dgc_none (gcry as process GC)" %}
{% end %}

HEAP = Gcry.default_heap.not_nil!

# Linux only, and for a reason about the mechanism rather than about the OS.
# The pre-stop snapshot table exists because `pthread_getattr_np` cannot be
# called with the world stopped. Darwin and Windows have no such problem —
# `darwin_stack.cr` / `windows_stack.cr` query the thread descriptor at lookup
# time — so `snapshot_pthread_stack_bounds` is a no-op there,
# `stack_bounds_visited` / `read` / `capacity_misses` return **zeros by design**
# and `stack_bounds_nogrow=` is a no-op setter. There is no table to grow, no
# loss to produce, and nothing here to assert.
#
# This file claimed the opposite on 2026-09-16 — "the arms are not Linux-only" —
# read off the fact that all three platforms *declare* the same methods. They
# declare them returning zero, which is the Darwin `each_thread_greg` stub shape
# that cost v0.19.0 two platforms' register roots. The Darwin CI run said so
# plainly: `stack_bounds_visited=0 read=0 capacity_misses=0`, caught by this
# harness's own precondition.
{% unless flag?(:linux) %}
  puts "=== stack-bounds table growth ==="
  puts "SKIP — this platform queries the thread descriptor at lookup time instead of"
  puts "snapshotting, so there is no bounds table to grow and the counters this gate"
  puts "asserts on are zeros by design (see src/gcry/platform/darwin_stack.cr)."
  exit 0
{% end %}

# Comfortably past `STACK_BOUNDS_INITIAL_SLOTS` (64) so the table has to double
# at least twice, and not so many that a shared runner spends its time
# scheduling. The control arm stays under it.
THREADS         = 100
CONTROL_THREADS =   8

child_arm = ARGV.find(&.starts_with?("--child=")).try(&.split('=', 2)[1])

# An unrecognised argument is fatal, not ignored. The three arms used to be
# selected by `--control` / `--nogrow` on the parent; after they became child
# arms a stale recipe passing the old flags ran the *parent* three more times,
# once with GCRY_STACK_BOUNDS_NOGROW inherited into the hold arm, and reported a
# failure that was entirely the invocation's fault.
ARGV.each do |arg|
  next if arg.starts_with?("--child=")
  STDERR.puts "unknown argument #{arg.inspect}: this harness takes no arguments (it drives " \
              "its three arms as bounded children) or exactly one --child=hold|control|nogrow."
  exit 64
end

# ── Parent: drive each arm as a bounded child ─────────────────────────────────
unless child_arm
  exe = Process.executable_path.not_nil!
  arms = [
    {"hold", {} of String => String},
    {"control", {} of String => String},
    {"nogrow", {"GCRY_STACK_BOUNDS_NOGROW" => "1"}},
  ]
  failed = [] of String
  puts "=== stack-bounds table growth ==="
  arms.each do |(arm, env)|
    result = BoundedChild.run(exe, ["--child=#{arm}"], env)
    result.output.each_line do |line|
      puts "  #{line.rstrip}" unless line.strip.empty?
    end
    unless result.ok
      failed << (result.timed_out ? "#{arm} (exceeded its budget)" : arm)
    end
  end
  puts ""
  if failed.empty?
    puts "ok — all three arms inside their budget: the table grows past its initial " \
         "capacity, the loss shows in both counters when it is frozen, and neither " \
         "reading comes from a run that hung."
    exit 0
  end
  STDERR.puts "FAIL: #{failed.join(", ")}"
  exit 1
end

unless child_arm.in?("hold", "control", "nogrow")
  STDERR.puts "unknown arm #{child_arm.inspect}: expected hold, control or nogrow."
  exit 64
end

control = child_arm == "control"
nogrow = child_arm == "nogrow"
want = control ? CONTROL_THREADS : THREADS

mode = if control
         "control (#{CONTROL_THREADS} threads, inside the initial capacity)"
       elsif nogrow
         "nogrow (GCRY_STACK_BOUNDS_NOGROW: the pre-fix fixed table; the loss must show)"
       else
         "hold (#{THREADS} threads, past the initial capacity)"
       end
puts "arm #{child_arm}: #{mode}"

if nogrow && !control
  # The knob is read once at boot into the platform module; there is no getter
  # for it, so the arm's precondition is the counters themselves — asserted
  # below rather than here. What can be checked here is that the arm was not
  # asked for without the knob, which would measure the shipped fix.
  unless ENV["GCRY_STACK_BOUNDS_NOGROW"]? == "1"
    STDERR.puts "the nogrow arm needs GCRY_STACK_BOUNDS_NOGROW=1; without it this arm would " \
                "run the shipped growing table and require a loss that cannot happen."
    exit 64
  end
end

# Hold every thread alive across the collection. A thread that has exited is not
# visited, so a harness whose workers finish early measures the control arm
# under another name.
running = Atomic(Int32).new(0)
release = Atomic(Int32).new(0)
threads = [] of Thread
want.times do
  threads << Thread.new do
    running.add(1)
    # 25 ms, not microseconds. The first version polled at 200 us, which is
    # 100 threads x 5000 wakeups/s: fine on a 20-thread host and apparently
    # pathological on the 4-vCPU macOS runner, where this harness ran 18m37s
    # and took the Darwin job down at its 20-minute cap
    # (log/linux/2026-09-16-stack-bounds-gate/FINDINGS.md). Release latency of
    # 25 ms costs nothing here: the threads only have to still exist while two
    # collections happen.
    while release.get == 0
      Thread.sleep(25.milliseconds)
    end
  end
end
while running.get < want
  Thread.sleep(1.millisecond)
end

GC.collect
GC.collect

visited = Gcry::Platform.stack_bounds_visited
read = Gcry::Platform.stack_bounds_read
misses = Gcry::Platform.stack_bounds_capacity_misses

release.set(1)
threads.each(&.join)

puts "threads held: #{want} (plus this one and the collector's own)"
puts "stack_bounds_visited=#{visited} read=#{read} capacity_misses=#{misses}"
puts ""

failures = [] of String

# Precondition for every arm: a snapshot that visited nothing says nothing.
if visited == 0
  failures << "the snapshot visited no threads at all, so no arm below means anything — " \
              "either the pre-stop snapshot did not run or this platform reports zeros"
end

if control
  unless read == visited
    failures << "read=#{read} against visited=#{visited} with only #{CONTROL_THREADS} threads, " \
                "inside the initial #{64} slots — the table is losing threads it always had " \
                "room for, so the hold arm's reading would not be about growth"
  end
  unless misses == 0
    failures << "#{misses} capacity miss(es) inside the initial capacity"
  end
elsif nogrow
  # Both halves. A frozen table that also stopped counting would read as full
  # coverage of a smaller process.
  unless read < visited
    failures << "with the table frozen at its initial capacity and #{want} threads held, " \
                "read=#{read} still equals visited=#{visited} — GCRY_STACK_BOUNDS_NOGROW no " \
                "longer freezes the table, so the hold arm has no red direction"
  end
  unless misses > 0
    failures << "the frozen table recorded #{misses} capacity misses while dropping " \
                "#{visited - read} thread(s) — the counter that is supposed to name this loss " \
                "is silent, which is how the loss would go unnoticed in the field"
  end
else
  unless read == visited
    failures << "read=#{read} against visited=#{visited} with #{want} threads held: " \
                "#{visited - read} thread(s) were walked and had nowhere to record their " \
                "stack bounds, so their OS stacks are not scanned by the root scan"
  end
  unless misses == 0
    failures << "#{misses} capacity miss(es) past the initial capacity — the table is not " \
                "growing, which is the pre-fix fixed-64 behaviour"
  end
end

if failures.empty?
  if control
    puts "ok — inside the initial capacity the table records every thread it visits, so the " \
         "hold arm's equality is attributable to growth and not to the counters agreeing " \
         "trivially."
  elsif nogrow
    puts "ok — frozen at its initial capacity the table drops #{visited - read} thread(s) and " \
         "counts #{misses} miss(es), so the hold arm has a red direction and the counter that " \
         "names the loss works."
  else
    puts "ok — #{visited} threads visited, #{read} recorded, #{misses} misses: the table grew " \
         "past its initial capacity and the root scan has every thread's stack."
  end
  exit 0
end

failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
