# `stop_world` can wait forever for a worker that has not started yet.
#
# Found while building `bench/scrub_midswap.cr`, and it has nothing to do with
# the scrub: it reproduces with the scrub off, no manufactured state, and nothing
# in the program but EC parallelism, one fiber, and one collection.
#
# Bisected by ingredient on this host (9950X/WSL2, EC parallelism 4):
#
#     resize(4) + GC.collect                          0 of 200 hang
#     resize(4) + a fiber that never yields + collect  18 of 150 hang   (12%)
#
# So the trigger is a fiber that takes a worker and does not give it back while
# the first collection runs. `--scrub` adds nothing; it was in the shape that
# found it, not in the cause.
#
# `Heap#stop_world` (collect_stw.cr) signals every non-exempt thread and then
# spins, unbounded, until each one sets `@suspended`:
#
#     Thread.unsafe_each { |t| ... t.suspend }
#     Thread.unsafe_each { |t| ... until t.@suspended.get; Intrinsics.pause; end }
#
# Nothing bounds that second loop, and nothing re-signals. At the hang, every
# time:
#
#     tid A  comm=<program>  sigsuspend    utime=9     suspended, acked
#     tid B  comm=SYSMON     R, spinning   utime=533   the collector, in the loop above
#     tid C  comm=DEFAULT-1  futex_wait    utime=0     never executed a single instruction
#     tid D  comm=SYSMON     sigsuspend    utime=0     suspended, acked
#
# `DEFAULT-1` is the EC worker the collector is waiting for, and its `utime=0`
# says it has never run — so it cannot have taken the SIGPWR, and the pending
# signal cannot be handled until it is scheduled. It is parked in the futex of
# its own startup handshake, whose other side is a thread the collector has
# already frozen. Three-way: the worker waits on a suspended thread, the
# collector waits on the worker.
#
# (Two threads report `comm=SYSMON` because Linux gives a new thread its
# creator's name until it sets its own, so the collector here is a worker spawned
# by the Monitor. `stw_signal_exempt?` reads Crystal's `Thread#@name`, not `comm`,
# so that is cosmetic — but it is why the thread dump looks impossible at first.)
#
# This is the same family as the hang already recorded in `collect_stw.cr`
# ("GCRY_STRESS hang: main=futex_do_wait, SYSMON=sigsuspend"), which was closed
# by exempting SYSMON. A worker still inside startup is a second member of it,
# and it is not exempt.
#
# Not a crash, so it is not the acikturkiye SIGSEGV. It is a startup-window
# hang: an EC app whose first collection lands within milliseconds of raising
# parallelism can stop dead, with no diagnostic at all.
#
#   crystal build -Dgc_none -Dpreview_mt -Dexecution_context \
#     bench/stw_startup_hang.cr -o bin/stw_startup_hang
#   bin/stw_startup_hang --spin               # 200 starts, the shape that hangs
#   bin/stw_startup_hang --spin --children=500 --timeout=5
#   bin/stw_startup_hang                      # control: no spinner, expected green
#   bin/stw_startup_hang --child --spin       # one attempt (used as the child)
#
# Exits non-zero if any child hangs — i.e. it is red today, on purpose, and
# becomes a gate the moment the wait is bounded.

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

  # `resize` + `GC.collect` alone does NOT hang — measured, 0 of 200. The
  # ingredient is a fiber that takes a worker and never gives it back, so the
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
  puts "First hang, from /proc — the collector is the spinning thread, and the"
  puts "thread it is waiting for has utime=0, i.e. has never been scheduled:"
  puts dump
end

if hangs > 0
  pct = (hangs * 100.0 / children).round(2)
  STDERR.puts "FAIL: stop_world hung on #{hangs}/#{children} starts (#{pct}%). " \
              "The ack wait in Heap#stop_world is unbounded and does not re-signal, " \
              "so a worker that has not been scheduled yet wedges the collection."
  exit 1
end

puts "PASS — no hang in #{children} starts."
puts "Note the shape this cannot prove: absence over N starts bounds the rate, it"
puts "does not fix an unbounded wait. Raise --children before reading it as green."
