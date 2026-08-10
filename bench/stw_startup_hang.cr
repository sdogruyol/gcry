# The collector must not ask glibc about a thread it has suspended.
#
# `scan_other_thread_stacks` used to call `pthread_getattr_np` for each thread's
# stack bounds *after* STW had frozen those threads. That call locks the target
# thread's descriptor, and a suspended thread can be holding its own — so the
# collector waited forever: no crash, no output, no diagnostic.
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
# **It is not "libc under STW" in general.** That was the first reading and it is
# wrong. Isolated against a positive control firing in the same binary:
#
#     live getattr for every thread        4 of 100 hang   (positive control)
#     live getattr for non-main threads    9 of 100 hang
#     live getattr for the main thread     0 of 100
#     LibC.malloc 64 KiB x8 under STW      0 of 100
#     fopen("/proc/self/maps") under STW   0 of 100
#     ~1999 finalizer queue_pending mallocs under STW (--finalizers)  0 of 150
#     the same plus four fibers churning the malloc arena (--libc-churn)  0 of 120
#
# So the main thread's `/proc/self/maps` parse is not the trigger, malloc is not
# the trigger, and the collector's other libc use — notably the finalizer
# registry's `LibC.malloc` per queued finalizer, which really does run with the
# world stopped — is not implicated. The rule this gate enforces is the narrow
# one: do not ask glibc about a suspended thread.
#
# Bisected by ingredient on this host (9950X/WSL2, EC parallelism 4):
#
#     resize(4) + GC.collect                           0 of 200 hang
#     resize(4) + a fiber that never yields + collect  18 of 150 hang   (12%)
#     the same, with the fix                            0 of 500
#     the same, fix reverted (both hunks)              12 of 150 hang    (8%)
#
# The trigger is a fiber that holds a worker across the first collection, which
# is what puts a frozen worker in the window where glibc still holds its
# descriptor lock.
#
# Two earlier readings were wrong and are recorded because they are the kind of
# wrong that looks convincing. `utime=0` on the waiting thread does not mean
# "never scheduled" — it means under one 10 ms tick, and that thread had already
# run `Thread#start`. And the two threads reporting `comm=SYSMON` are a Linux
# artefact: a new thread inherits its creator's name until it sets its own.
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
# `--finalizers` and `--libc-churn` are negative controls kept from that
# isolation: both put real libc allocation under STW and neither hangs.
#
# Exits non-zero if any child hangs. Green since the fix; it stays as the gate
# against reintroducing a glibc query about a suspended thread.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "stw_startup_hang requires -Dgc_none (gcry as process GC)" %}
{% end %}
{% unless flag?(:execution_context) %}
  {% raise "stw_startup_hang requires -Dpreview_mt -Dexecution_context" %}
{% end %}

PARALLELISM = 4

# A class with `finalize` gets a finalizer entry per instance.
class Finalizable
  @@sink = 0

  def initialize(@n : Int32)
  end

  def finalize
    @@sink = @@sink &+ @n
  end
end

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

  # Negative control. `enqueue_unreachable_finalizers` runs inside STW and queues
  # each unreachable entry through `Finalizers::Registry#queue_pending`, which
  # calls LibC.malloc — one per object, with the world stopped. Measured here:
  # 2022 entries in, 23 left, so ~1999 of those mallocs really do run under STW,
  # and it does not hang (0 of 150). That is why the finalizer registry was left
  # alone: the danger is querying a suspended thread, not allocating.
  if ARGV.includes?("--finalizers")
    2000.times { |i| Finalizable.new(i) }
  end

  # Negative control, stronger: keep other threads inside libc malloc when STW
  # freezes them, at sizes above glibc's tcache ceiling (1032 bytes) where the
  # arena lock is actually taken. Not a synthetic shape — any app with C bindings
  # mallocs on its mutator threads (acikturkiye runs pg + openssl). Still 0 of
  # 120, so arena contention across STW is not what wedges the collector.
  if ARGV.includes?("--libc-churn")
    4.times do
      spawn do
        n = 0_u64
        while true
          sz = LibC::SizeT.new(2048 + (n % 16) * 4096)
          p1 = LibC.malloc(sz)
          LibC.free(p1) unless p1.null?
          n &+= 1
          Fiber.yield if (n & 0x3ff) == 0
        end
      end
    end
    Fiber.yield
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
child_flags = ARGV.select { |a|
  a == "--spin" || a == "--scrub" || a == "--finalizers" || a == "--libc-churn"
}

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
              "Something under STW is waiting on a lock a suspended thread holds. " \
              "pthread_getattr_np was the one this gate was built for (fixed via " \
              "Platform.snapshotted_stack_bounds) — check what else the collect " \
              "path asks glibc about a thread it has just frozen."
  exit 1
end

puts "PASS — no hang in #{children} starts."
puts "Note the shape this cannot prove: absence over N starts bounds the rate, it"
puts "does not fix an unbounded wait. Raise --children before reading it as green."
