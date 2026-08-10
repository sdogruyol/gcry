# The collector must not call libc while the world is stopped.
#
# `scan_other_thread_stacks` used to ask `pthread_getattr_np` for each thread's
# stack bounds *after* STW had frozen those threads. That call takes the target
# thread's descriptor lock, and for the main thread glibc has no recorded
# stackblock, so it parses `/proc/self/maps` through stdio — which mallocs. Both
# can be held by a thread the collector has just suspended, and then the
# collector waits for it forever: no crash, no output, no diagnostic.
#
# Located by marker, not by argument. The hang is inside that one call:
#
#     DBG pass2 done, world stopped     <- the world stops fine
#     DBG static-done
#     DBG scan_other_thread_stacks begin
#     DBG about to getattr_np / returned   (thread 1)
#     DBG about to getattr_np / returned   (thread 2)
#     DBG about to getattr_np              (thread 3 — never returns)
#
# Fixed by taking the bounds in `stop_world`, under `Thread.lock` and before the
# first suspend signal, and doing a table lookup under STW
# (`Platform.snapshotted_stack_bounds`). Same number of `pthread_getattr_np`
# calls per collection; they just no longer run inside the suspension window.
#
# Bisected by ingredient on this host (9950X/WSL2, EC parallelism 4):
#
#     resize(4) + GC.collect                           0 of 200 hang
#     resize(4) + a fiber that never yields + collect  18 of 150 hang   (12%)
#     the same, with the fix                            0 of 500
#     the same, fix reverted (both hunks)              12 of 150 hang    (8%)
#
# The trigger is a fiber that holds a worker across the first collection: it
# keeps another thread busy in the window where startup still mallocs, which is
# what puts a frozen thread inside the arena lock. `--scrub` adds nothing; it was
# in the shape that found this, not in the cause.
#
# Two earlier readings of this were wrong and are recorded because they are the
# kind of wrong that looks convincing. `utime=0` on the waiting thread does not
# mean "never scheduled" — it means under one 10 ms tick, and that thread had
# already run `Thread#start`. And the two threads reporting `comm=SYSMON` are a
# Linux artefact: a new thread inherits its creator's name until it sets its own.
# Neither observation had anything to do with the cause.
#
# Not a crash, so it was never the acikturkiye SIGSEGV.
#
#   crystal build -Dgc_none -Dpreview_mt -Dexecution_context \
#     bench/stw_startup_hang.cr -o bin/stw_startup_hang
#   bin/stw_startup_hang --spin               # the shape that used to hang
#   bin/stw_startup_hang --spin --children=500 --timeout=5
#   bin/stw_startup_hang                      # control: no spinner
#   bin/stw_startup_hang --child --spin       # one attempt (used as the child)
#
# Exits non-zero if any child hangs. Green since the fix; it stays as the gate
# against calling anything lock-taking from inside STW again.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "stw_startup_hang requires -Dgc_none (gcry as process GC)" %}
{% end %}
{% unless flag?(:execution_context) %}
  {% raise "stw_startup_hang requires -Dpreview_mt -Dexecution_context" %}
{% end %}

PARALLELISM = 4

# ── Child: the whole reproducer ──────────────────────────────────────────────
if ARGV.includes?("--child")
  Fiber::ExecutionContext.default.resize(PARALLELISM)

  # `resize` + `GC.collect` alone did NOT hang — measured, 0 of 200. The
  # ingredient is a fiber that holds a worker across the first collection, so the
  # child is built from flags and the parent reports which combination wedges.
  if ARGV.includes?("--spin")
    spinning = Atomic(Int32).new(0)
    ready = Atomic(Int32).new(0)
    spawn do
      # Park once, so this fiber has a real saved context, then never yield
      # again — from here the worker running it is unavailable.
      Fiber.yield
      ready.set(1)
      while spinning.get == 0
      end
    end
    # Yielding here hands this fiber to another worker, which is the shape the
    # hang was first seen in.
    until ready.get != 0
      Fiber.yield
    end
  end

  if ARGV.includes?("--scrub")
    heap = Gcry.default_heap.not_nil!
    heap.scrub_fibers_enabled = true
    heap.scrub_audit_foreign_sp = true
    {% if flag?(:linux) %}
      Gcry::Platform.audit_refresh_tids
    {% end %}
  end

  GC.collect
  puts "ok"
  exit 0
end

# ── Parent: run it many times, bound each one ────────────────────────────────
children = 200
timeout_s = 10

ARGV.each do |arg|
  case arg
  when /--children=(\d+)/ then children = $1.to_i
  when /--timeout=(\d+)/  then timeout_s = $1.to_i
  end
end

self_path = Process.executable_path || "bin/stw_startup_hang"
child_flags = ARGV.select { |a| a == "--spin" || a == "--scrub" }

hangs = 0
ok = 0
first_dump = nil.as(String?)

children.times do |i|
  process = Process.new(self_path, ["--child"] + child_flags,
    output: Process::Redirect::Close, error: Process::Redirect::Inherit)

  reaped = Channel(Process::Status).new(1)
  spawn { reaped.send(process.wait) }

  hung = false
  select
  when reaped.receive
    # fall through
  when timeout timeout_s.seconds
    hung = true
    # Capture the evidence before killing: /proc is the only witness, there is
    # no core and the process is wedged inside STW so it cannot report anything
    # itself.
    if first_dump.nil?
      io = IO::Memory.new
      io << "hung child pid #{process.pid} (attempt #{i + 1})\n"
      Dir.each_child("/proc/#{process.pid}/task") do |tid|
        base = "/proc/#{process.pid}/task/#{tid}"
        comm = File.read("#{base}/comm").chomp rescue "?"
        stat = (File.read("#{base}/stat") rescue "").split(' ')
        wchan = File.read("#{base}/wchan").chomp rescue "?"
        io << "  tid #{tid} comm=#{comm} state=#{stat[2]? || "?"} " \
              "wchan=#{wchan} utime=#{stat[13]? || "?"}\n"
      end
      first_dump = io.to_s
    end
    process.signal(:kill)
    reaped.receive
  end

  hung ? (hangs += 1) : (ok += 1)
end

puts "=== stop_world startup ack wait ==="
puts "#{children} child processes: resize(#{PARALLELISM})#{child_flags.empty? ? "" : " " + child_flags.join(" ")} then one `GC.collect`"
puts "  completed : #{ok}"
puts "  hung      : #{hangs}  (killed after #{timeout_s}s)"
puts ""

if dump = first_dump
  puts "First hang, from /proc. Read it carefully: `utime=0` means under one"
  puts "10 ms tick, not \"never scheduled\", and comm=SYSMON on two threads is"
  puts "name inheritance. Both misled this investigation once:"
  puts dump
end

if hangs > 0
  pct = (hangs * 100.0 / children).round(2)
  STDERR.puts "FAIL: the collector hung on #{hangs}/#{children} starts (#{pct}%). " \
              "Something called under STW is waiting on a lock a suspended thread " \
              "holds — pthread_getattr_np was the first one (fixed via " \
              "Platform.snapshotted_stack_bounds); check what else the collect " \
              "path calls into libc while the world is stopped."
  exit 1
end

puts "PASS — no hang in #{children} starts."
puts "Note the shape this cannot prove: absence over N starts bounds the rate, it"
puts "does not fix an unbounded wait. Raise --children before reading it as green."
