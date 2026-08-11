# Does the EC Monitor stay out of the stopped world?
#
# `Heap#stop_world` never signal-suspends the Monitor (SYSMON) — resume races
# left it wedged in `sigsuspend`, so it was meant to cooperate by blocking in
# `allocate` / `lock_read` instead. Measured, it did not: it woke ~100 times a
# second through a 4 s stop and ran `StackPool#collect` — which munmaps fiber
# stacks — *inside* the stop, while the collector was scanning thread stacks.
# `bench/log/linux/2026-08-11-sysmon-runs-during-stw/FINDINGS.md`.
#
# `Gcry::MonitorGate` replaces that assumption with a handshake. This drives it
# from both sides, in one binary:
#
#   gate on   no `sched.collect_stacks` inside the stopped window, and the
#             Monitor must be *observed* being held off — a window with no trace
#             line because nothing happened to be scheduled proves nothing
#   gate off  the same line must appear inside the window (positive control:
#             without it, "on" is not evidence that anything was closed)
#
# The window is `GCRY_STW_TEST_STALL_MS`, longer than `COLLECT_STACKS_EVERY`
# (5 s) so the Monitor is certain to want to collect during it.
#
#   crystal build -Dgc_none -Dtracing bench/stw_monitor_gate.cr -o bin/stw_monitor_gate
#   bin/stw_monitor_gate
#   bin/stw_monitor_gate --child          # one stalled collection (the child)

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "stw_monitor_gate requires -Dgc_none (gcry as process GC)" %}
{% end %}
{% unless flag?(:tracing) %}
  # The Monitor's work is stdlib-internal; `CRYSTAL_TRACE=sched` is how it can be
  # seen at all from outside. Without it this tool cannot answer its question.
  {% raise "stw_monitor_gate requires -Dtracing" %}
{% end %}

# Longer than COLLECT_STACKS_EVERY (5 s) several times over, so the control gets
# multiple chances to run inside the stop and a *count* can separate "the Monitor
# kept working" from "one call was already in flight when the stop began".
STALL_MS = 20_000

if ARGV.includes?("--child")
  # Give the stack pool something to hand back, so `collect_stacks` has work.
  100.times { spawn { sleep 5.milliseconds } }
  sleep 1.second

  STDERR.puts "MARK begin"
  STDERR.flush
  GC.collect
  STDERR.puts "MARK end"
  STDERR.flush
  STDERR.puts "GATE enabled=#{Gcry::MonitorGate.enabled?} " \
              "blocks=#{Gcry::MonitorGate.monitor_blocks} " \
              "stw_waits=#{Gcry::MonitorGate.stw_waits} " \
              "stw_wait_max_ns=#{Gcry::MonitorGate.stw_wait_max_ns}"
  STDERR.flush
  exit 0
end

self_path = Process.executable_path || "bin/stw_monitor_gate"

def run(self_path : String, gate : Bool) : String
  err = IO::Memory.new
  env = {"CRYSTAL_TRACE" => "sched", "GCRY_STW_TEST_STALL_MS" => STALL_MS.to_s}
  env["GCRY_MONITOR_GATE"] = "0" unless gate
  status = Process.run(self_path, ["--child"], env: env,
    output: Process::Redirect::Close, error: err)
  raise "child failed (#{status.exit_code})" unless status.success?
  err.to_s
end

# How many collect_stacks trace lines fall between the two marks.
#
# A count, not a boolean, and the reason is a CI failure: `Crystal.trace` emits
# its line *after* the work finishes (it reports `duration=`), so a call already
# in flight when the stop began lands after "MARK begin" even though the
# collector correctly waited it out. On a 2-vCPU runner that overlap is likely;
# on a 32-thread box it is rare, which is why this passed locally and failed in
# CI. One line is the in-flight case the handshake is documented to allow.
# Several lines mean the Monitor kept starting work inside the stop, which is
# the thing the gate exists to prevent.
def count_inside(text : String) : Int32
  inside = false
  count = 0
  text.each_line do |line|
    if line.includes?("MARK begin")
      inside = true
      next
    end
    break if line.includes?("MARK end")
    count += 1 if inside && line.includes?("sched.collect_stacks")
  end
  count
end

def field(text : String, key : String) : Int64
  if m = text.match(/#{key}=(\d+)/)
    m[1].to_i64
  else
    -1_i64
  end
end

puts "=== EC Monitor vs the stopped world ==="
puts "#{STALL_MS} ms stall, COLLECT_STACKS_EVERY is 5 s so the Monitor wants in"
puts ""

on = run(self_path, true)
off = run(self_path, false)

on_inside = count_inside(on)
off_inside = count_inside(off)
on_blocks = field(on, "blocks")
on_waits = field(on, "stw_waits")

puts "  gate on   collect_stacks inside the stop: #{on_inside}   held off #{on_blocks}x   stw_waits=#{on_waits}"
puts "  gate off  collect_stacks inside the stop: #{off_inside}   (control)"
puts ""

failures = [] of String

# The control must show the Monitor working *repeatedly* inside the stop. One
# line could be a single in-flight call; several can only be work it started
# while the world was stopped.
if off_inside < 2
  failures << "control (gate off) showed #{off_inside} collect_stacks inside a " \
              "#{STALL_MS} ms stop — expected several. The probe is not seeing the " \
              "behaviour the gate is supposed to prevent, so the passing case means nothing"
end

if on_inside > 1
  failures << "gate on: #{on_inside} collect_stacks inside the stopped world — the Monitor " \
              "started new work after the stop began"
end

# Deliberately *not* asserted: that a single line inside must be accounted for by
# `stw_waits`. That was tried and CI rejected it, correctly. A line can also be
# emitted between "MARK begin" and the moment the world actually stops — the
# child prints its mark before `GC.collect`, and reaching the stop goes through
# collect entry, the write lock and the roots/finalizer locks, which is not
# instant on a loaded runner. Work finishing in *that* window was never inside a
# stopped world, so requiring a wait for it asserted a mechanism the run does not
# have to exhibit. The count carries the signal on its own: broken measures 4
# (control and the break-gate run agree), working measures 0–1.
# `stw_waits` is still reported, because when it is non-zero it is the pause the
# handshake added.

if on_blocks <= 0
  failures << "gate on: the Monitor was never held off (blocks=#{on_blocks}), so the clean " \
              "window is not evidence the handshake did anything"
end

if failures.empty?
  waits = field(on, "stw_waits")
  maxns = field(on, "stw_wait_max_ns")
  puts "PASS — the Monitor is shut out, and was seen being shut out."
  puts ""
  puts "Cost, measured rather than argued: stop_world waited for work the Monitor had"
  puts "already started #{waits} time(s) in this run, worst #{maxns} ns. That wait is the"
  puts "only pause the handshake can add — the entry check keeps the Monitor from"
  puts "starting anything new, so what is left is one in-flight call at most."
else
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
