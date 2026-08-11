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

STALL_MS = 8000

if ARGV.includes?("--child")
  # Give the stack pool something to hand back, so `collect_stacks` has work.
  100.times { spawn { sleep 5.milliseconds } }
  sleep 1.second

  STDERR.puts "MARK begin"
  GC.collect
  STDERR.puts "MARK end"
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

# True when a collect_stacks trace line falls between the two marks.
def collected_inside?(text : String) : Bool
  inside = false
  text.each_line do |line|
    inside = true if line.includes?("MARK begin")
    return true if inside && line.includes?("sched.collect_stacks")
    return false if line.includes?("MARK end")
  end
  false
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

on_inside = collected_inside?(on)
off_inside = collected_inside?(off)
on_blocks = field(on, "blocks")

puts "  gate on   collect_stacks inside the stop: #{on_inside}   monitor held off #{on_blocks}x"
puts "  gate off  collect_stacks inside the stop: #{off_inside}   (control)"
puts ""

failures = [] of String

unless off_inside
  failures << "control (gate off) showed no collect_stacks inside the stopped window — " \
              "the probe saw nothing, so the passing case below would mean nothing"
end

if on_inside
  failures << "gate on: the Monitor still ran collect_stacks inside the stopped world"
end

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
