# Does the world come back whole when there are more threads than STW slots?
#
# Darwin stops the world with `thread_suspend`, which is synchronous and needs
# no signal — and until this gate went in, it resumed from a **64-entry port
# table** while the stop suspended every thread unconditionally:
#
#     kr = LibMach.thread_suspend(port)          # every thread with a port
#     if @@stw_port_count < MAX_STW_SP_SLOTS     # only the first 64
#       @@stw_ports[@@stw_port_count] = port
#
# `resume_suspended_ports` walked `0...@@stw_port_count`, so the 65th thread and
# up were suspended and never resumed. Not a slow collection — a frozen mutator,
# permanently, from a collection that reported success.
#
# Found from the other end: `bench/thread_startup_cost.cr` measured a Darwin
# collect arm at 7.6 ms for 8 threads, 32.3 ms for 32, and **120 s TIMEOUT** for
# 64 and 100, against 31.6/65.1/41.3/85.7 ms on Linux. An O(n²) curve was the
# first reading and it was wrong: the cliff is a bound
# (`bench/log/linux/2026-09-17-darwin-64-thread-cliff/`).
#
# The contract is an equality, and it is on `/gc-stats`:
#
#   stw_threads_suspended   threads `thread_suspend` returned KERN_SUCCESS for
#   stw_threads_resumed     threads `thread_resume` returned KERN_SUCCESS for
#
# Both counted on success only, so the equality is exact and breaks in two
# directions that are both defects: fewer resumes is a thread left frozen, more
# is gcry resuming a thread something else had suspended. The arms assert the
# equality **and** that every worker thread makes progress afterwards, because a
# counter pair can agree while the threads are dead and progress can look fine
# while the counters are not being written at all.
#
# Three arms, each a bounded child of this process, and the child's contract is
# the same in all three: exit 0 if the world came back whole. What differs is
# what the parent expects of that.
#
#   hold       more threads than `MAX_STW_SP_SLOTS`, shipped resume. The world
#              must come back whole. **This is the gate.**
#
#   bounded    the same thread count with `GCRY_STW_BOUNDED_RESUME=1`, which
#              restores the pre-fix table walk. The world must **not** come back
#              whole. A wedged child counts: a thread frozen while it held the
#              allocator's lock takes the rest of the process with it, and that
#              is the defect rather than an accident of the harness — which is
#              why the budget is bounded here instead of in the recipe.
#
#   control    the same knob with a thread count *inside* the table. The world
#              must come back whole, which is what stops the bounded arm's
#              failure from being "the knob breaks the resume" rather than "the
#              table is too short".
#
# Darwin only, and about the mechanism rather than the OS: Linux resumes by the
# suspended thread returning from `sigsuspend` — the collector never resumes
# anyone — and Windows refuses any stop it cannot record, checking the count
# *before* it suspends (`raise_thread_suspension_error` says "or exceeded 64
# threads"). Neither can leave a thread suspended, so `stw_threads_suspended` /
# `stw_threads_resumed` are real zeros there and there is nothing to assert.
#
#   crystal build -Dgc_none bench/darwin_stw_resume.cr -o bin/darwin_stw_resume
#   bin/darwin_stw_resume              # drives all three arms as bounded children
#   bin/darwin_stw_resume --child=hold

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "darwin_stw_resume requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% unless flag?(:darwin) %}
  puts "=== Darwin STW resume coverage ==="
  puts "SKIP — this platform does not resume the world from a record of its own:"
  puts "Linux threads resume by returning from sigsuspend and Windows refuses any stop"
  puts "it cannot record, so stw_threads_suspended/resumed are zeros by design."
  exit 0
{% end %}

HEAP = Gcry.default_heap.not_nil!

# The counters are read through the heap rather than `Gcry::Platform` so this
# file type-checks on every platform: the platform methods exist only on Darwin
# (deliberately — a zero-returning stub on Linux is the shape that cost
# v0.19.0 its register roots), while the heap wrappers are defined everywhere
# and answer 0 off Darwin.
def bounded_resume? : Bool
  {% if flag?(:darwin) %}
    Gcry::Platform.stw_bounded_resume?
  {% else %}
    false
  {% end %}
end

# Past `MAX_STW_SP_SLOTS` (64) by enough that several threads fall outside the
# table, and not so many that a 4-vCPU runner spends its time scheduling — the
# lesson of `stack_bounds_growth` taking the Darwin job to its 20-minute cap.
THREADS         = 70
CONTROL_THREADS =  8

# A wedged child is the bounded arm's evidence, so the budget has to be short
# enough to pay for it three times inside the macOS job's 20 minutes. The work
# itself is under two seconds.
ARM_BUDGET = 60.seconds

# Long enough that a runnable thread certainly ticks, short enough to keep the
# arm cheap. Workers tick every 5 ms.
PROGRESS_WINDOW = 250.milliseconds

child_arm = ARGV.find(&.starts_with?("--child=")).try(&.split('=', 2)[1])

ARGV.each do |arg|
  next if arg.starts_with?("--child=")
  STDERR.puts "unknown argument #{arg.inspect}: this harness takes no arguments (it drives " \
              "its three arms as bounded children) or exactly one --child=hold|bounded|control."
  exit 64
end

# ── Parent: drive each arm as a bounded child ─────────────────────────────────
unless child_arm
  exe = Process.executable_path.not_nil!
  bounded = {"GCRY_STW_BOUNDED_RESUME" => "1"}
  arms = [
    {"hold", {} of String => String, true},
    {"bounded", bounded, false},
    {"control", bounded, true},
  ]
  failures = [] of String
  puts "=== Darwin STW resume coverage ==="
  arms.each do |(arm, env, want_whole)|
    result = BoundedChild.run(exe, ["--child=#{arm}"], env, ARM_BUDGET)
    result.output.each_line do |line|
      puts "  #{line.rstrip}" unless line.strip.empty?
    end
    next if result.ok == want_whole

    failures << if want_whole && result.timed_out
                  "#{arm}: the child outlived its #{ARM_BUDGET.total_seconds.to_i}s budget, " \
                  "which is what a thread frozen inside the allocator does to the process"
                elsif want_whole
                  "#{arm}: the world did not come back whole"
                else
                  "#{arm}: the pre-fix table walk resumed every thread and every worker kept " \
                  "running, so GCRY_STW_BOUNDED_RESUME no longer restores the defect and the " \
                  "hold arm has no red direction"
                end
  end
  puts ""
  if failures.empty?
    puts "ok — past #{THREADS} threads the resume covers every thread it suspended, the " \
         "pre-fix 64-entry table demonstrably does not, and the same knob inside the table " \
         "is harmless: the hold arm's equality is about the bound and not about the knob."
    exit 0
  end
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end

unless child_arm.in?("hold", "bounded", "control")
  STDERR.puts "unknown arm #{child_arm.inspect}: expected hold, bounded or control."
  exit 64
end

bounded_arm = child_arm == "bounded"
control = child_arm == "control"
want = control ? CONTROL_THREADS : THREADS

if bounded_arm || control
  # The knob is read once at boot into the platform module. Running either of
  # these arms without it would measure the shipped resume under the wrong name
  # — the mistake a stale recipe made to `stack_bounds_growth`'s nogrow arm.
  unless bounded_resume?
    STDERR.puts "arm #{child_arm} needs GCRY_STW_BOUNDED_RESUME=1 to reach the pre-fix port " \
                "table; without it this arm would run the shipped resume."
    exit 64
  end
end

puts "arm #{child_arm}: #{want} worker threads, " \
     "#{bounded_resume? ? "pre-fix 64-entry port table" : "shipped thread-list"} resume"

# One slot per worker, written only by its own thread and read only after the
# world has restarted. A plain counter, not an `Atomic`: the question is whether
# the value changed at all, and a torn read cannot make a frozen thread look
# like it moved.
progress = Pointer(UInt64).malloc(want)
want.times { |i| progress[i] = 0_u64 }

running = Atomic(Int32).new(0)
release = Atomic(Int32).new(0)
threads = [] of Thread
want.times do |i|
  threads << Thread.new do
    running.add(1)
    while release.get == 0
      progress[i] = progress[i] + 1
      # Allocating keeps the arm honest: a thread suspended inside the
      # allocator is exactly the one whose freezing takes the process with it.
      Bytes.new(16)
      Thread.sleep(5.milliseconds)
    end
  end
end
while running.get < want
  Thread.sleep(1.millisecond)
end

GC.collect
GC.collect

suspended = HEAP.stw_threads_suspended
resumed = HEAP.stw_threads_resumed

before = Pointer(UInt64).malloc(want)
want.times { |i| before[i] = progress[i] }
sleep PROGRESS_WINDOW
stalled = 0
want.times { |i| stalled += 1 if progress[i] == before[i] }

puts "stw_threads_suspended=#{suspended} stw_threads_resumed=#{resumed} " \
     "stalled=#{stalled}/#{want} after #{PROGRESS_WINDOW.total_milliseconds.to_i}ms"

failures = [] of String

# Preconditions. Counters that never moved say nothing about coverage, and a
# harness whose workers all exited early would report a whole world for the
# reason that there was nothing left to resume.
if suspended == 0
  failures << "no thread was suspended at all, so nothing below is about resume coverage — " \
              "either the stop took a single-threaded path or the counter is not written"
end

unless suspended == resumed
  failures << "suspended=#{suspended} but resumed=#{resumed}: #{(suspended.to_i64 - resumed.to_i64).abs} " \
              "thread(s) were #{resumed < suspended ? "suspended and never resumed" : "resumed without this collector having suspended them"}"
end

if stalled > 0
  failures << "#{stalled} of #{want} worker threads made no progress in " \
              "#{PROGRESS_WINDOW.total_milliseconds.to_i}ms after the world restarted, which is " \
              "what a thread left suspended looks like from outside"
end

if failures.empty?
  # Only safe to join once every worker is known to be running: a frozen thread
  # never observes the release and `join` would wait for it forever, turning the
  # bounded arm's evidence into a hang.
  release.set(1)
  threads.each(&.join)
  puts "ok — #{suspended} suspends, #{suspended} resumes, every worker still running"
  exit 0
end

failures.each { |f| STDERR.puts "  - #{f}" }
STDERR.puts "the world did not come back whole"
exit 1
