# The collector waits for the Monitor; the Monitor waits for the collector.
#
# `MonitorGate.close` is how a stop shuts out the one thread it never suspends.
# It sets `stopped`, and if the Monitor is already inside its work — `busy` set
# — it spins until that call finishes. The comment there calls the wait
# "bounded by that one call". It is not: nothing bounds the call itself.
#
# The Monitor allocates. An allocation that crosses the threshold calls
# `collect`, which waits on `@post_stw_mutex` — held for the duration of the
# stop by the very thread spinning on `busy`. Neither can move, and the Monitor
# is exempt from suspension by design, so no signal breaks it.
#
# That is the aarch64 CI hang: `make ec-queue-audit`, ten seconds in
# `phase=suspend`, step "entered, monitor gate not yet closed" (run
# 32725238411, after the step markers landed; four earlier sightings were
# misread as being past the suspend wait).
#
# The fix is to keep the Monitor from becoming the collector while it holds the
# bit — `suppress_collect_enter` across the busy window. This asks for it
# directly rather than waiting for the shape to occur:
#
#   monitor   MonitorGate.enter, allocate hard, MonitorGate.leave
#   collector GC.collect while that is running
#
#   default                        must finish
#   GCRY_MONITOR_GATE_UNSUPPRESSED=1  must hang — otherwise the arm above is
#                                     not evidence
#
#   crystal build -Dgc_none bench/monitor_gate_deadlock.cr -o bin/monitor_gate_deadlock
#   bin/monitor_gate_deadlock
require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "monitor_gate_deadlock requires -Dgc_none (gcry as process GC)" %}
{% end %}

COLLECTS = 400
WORKERS  =   3
# Attempts the control arm gets before it gives up; see where it is used.
CONTROL_TRIES = 6

if ARGV.includes?("--child")
  # The real Monitor does the spawning, via `GCRY_MONITOR_GATE_TEST_SPAWN=1`.
  # A harness thread cannot stand in for it: `@@busy` is a single shared bit,
  # so the Monitor's next back-off clears whatever hold the harness took.
  stop = Atomic(Int32).new(0)

  churn = Array(Thread).new(WORKERS)
  WORKERS.times do
    churn << Thread.new do
      until stop.get == 1
        b = Bytes.new(256)
        b[0] = 1_u8
      end
    end
  end

  COLLECTS.times { GC.collect }
  stop.set(1)
  churn.each(&.join)

  puts "child: finished, stw_waits=#{Gcry::MonitorGate.stw_waits} " \
       "monitor_blocks=#{Gcry::MonitorGate.monitor_blocks}"
  exit 0
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
budget = (ENV["MONITOR_GATE_TIMEOUT_S"]?.try(&.to_i?) || 60).seconds

puts "=== monitor gate deadlock ==="
puts "the real Monitor spawns a thread inside its handshake; #{COLLECTS} stops run against it"
puts ""

base = {"GCRY_MONITOR_GATE_TEST_SPAWN" => "1"}
fixed = BoundedChild.run(exe, ["--child"], base, budget)
puts "  default:                          #{fixed.ok ? "finished" : (fixed.timed_out ? "HUNG" : "failed")}"

# The control arm needs *one* hang to make its point, and the cycle is a race:
# the Monitor enters its handshake about every 10 ms and the collector has to be
# holding `@roots_lock` at that moment. A single attempt comes up empty about
# half the time — measured — so it gets tries rather than a budget, and stops at
# the first hang.
old_env = base.merge({"GCRY_MONITOR_GATE_LATE_CLOSE" => "1"})
hung = false
tries = 0
while tries < CONTROL_TRIES && !hung
  tries += 1
  hung = BoundedChild.run(exe, ["--child"], old_env, budget).timed_out
end
puts "  GCRY_MONITOR_GATE_LATE_CLOSE=1:   #{hung ? "HUNG on try #{tries}" : "finished #{tries} tries"}"
puts ""

failures = [] of String
failures << "the default arm did not finish — closing the gate before @roots_lock did not " \
            "break the cycle" unless fixed.ok
failures << "the late-close arm finished #{tries} tries — this harness did not reach the " \
            "deadlock, so the arm above proves nothing" unless hung

if failures.empty?
  puts "ok — gate closed before @roots_lock the stop completes; closed after, it wedges"
  exit 0
else
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
