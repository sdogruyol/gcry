# Does the stop epoch make a suspend signal re-sendable, and does it decline
# the duplicate that made resending unsafe?
#
# The defect this gates: `stop_world` spins `until thread.@suspended.get`, and
# six aarch64 CI jobs ended at the 20-minute job timeout inside that loop — a
# thread that was signalled and never acknowledged. A job timeout reports as
# *cancelled* rather than failed, which is why it went unread from 2026-08-20
# until the watchdog named `phase=suspend`.
#
# The repair is the one `start_world` already makes for resume: send it again.
# It was refused twice because it is **unsafe on its own** — `SIG_SUSPEND` is
# blocked for the whole handler and inside `sigsuspend`, so a redundant one
# stays pending and is delivered *after* the thread resumes, suspending it
# again with nobody left to wake it. `Platform.begin_stop_epoch` /
# `admit_suspend_signal?` is what makes the duplicate a no-op, and this file is
# the evidence for both halves rather than the argument for them.
#
# Five arms. Each of the three shipped behaviours has a purpose-broken control
# that must be **red**, because a gate whose red arm has never been observed is
# a gate that proves nothing:
#
#   drop+resend      the first suspend signal of every stop is swallowed. The
#                    stop must still complete, and `stw_suspend_resends` must
#                    be non-zero — a run that completes without resending has
#                    not exercised anything.
#   drop+no-resend   RED. `GCRY_STW_RESEND=0`, same dropped signal: the stop
#                    must hang, which is the CI failure reproduced on demand.
#   double+epoch     a second `SIG_SUSPEND` is sent to every thread *after* the
#                    world restarts. It must be declined
#                    (`stw_suspend_stale_signals` non-zero) and the child must
#                    keep collecting.
#   double+no-epoch  RED. `GCRY_STW_EPOCH=0`, same duplicate: the thread
#                    suspends itself with the world running and the next stop
#                    waits on it forever. This is the hazard, demonstrated.
#   mute+dead        a thread deaf to every signal plus a handle probe forced to
#                    resends run out, the stop reports `SUSPEND ABANDONED` and
#                    completes instead of spinning. Unsound on purpose — the
#                    thread is alive — which is why `GCRY_STW_TEST_ESRCH` is
#                    research-only.
#
#   crystal build -Dgc_none bench/stw_epoch.cr -o bin/stw_epoch
#   bin/stw_epoch
#   bin/stw_epoch --child        # the half that runs under the collector

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "stw_epoch requires -Dgc_none (gcry as process GC)" %}
{% end %}

WORKERS     =  4
COLLECTIONS =  6
TIMEOUT_S   = 20

# ── Child: mutator threads the stop has to suspend, then collections ─────────
if ARGV.includes?("--child")
  stop = Atomic(Int32).new(0)
  WORKERS.times do
    Thread.new do
      # Allocating rather than only sleeping: a thread parked in `nanosleep`
      # takes its suspend signal on the way out of the syscall, and the point
      # of these arms is a thread that is actually running when it is hit.
      sink = [] of String
      while stop.get == 0
        sink << "w" * 24
        sink.clear if sink.size > 256
      end
    end
  end

  COLLECTIONS.times { GC.collect }
  stop.set(1)

  heap = Gcry.default_heap.not_nil!
  puts "collections=#{heap.collections} " \
       "resends=#{heap.stw_suspend_resends} " \
       "dropped=#{heap.stw_suspend_dropped_for_test} " \
       "abandoned=#{heap.stw_suspend_abandoned} " \
       "stale=#{heap.stw_suspend_stale_signals} " \
       "redundant=#{heap.stw_suspend_redundant_signals}"
  exit 0
end

# ── Parent ───────────────────────────────────────────────────────────────────
self_path = Process.executable_path || "bin/stw_epoch"

record Arm, name : String, env : Hash(String, String), expect_hang : Bool

record Result, name : String, hung : Bool, text : String, status : Int32

def run_arm(self_path : String, arm : Arm) : Result
  sink = IO::Memory.new
  process = Process.new(self_path, ["--child"], env: arm.env,
    output: sink, error: Process::Redirect::Inherit)

  reaped = Channel(Process::Status).new(1)
  spawn { reaped.send(process.wait) }

  hung = false
  code = 0
  select
  when status = reaped.receive
    code = status.exit_code
  when timeout TIMEOUT_S.seconds
    hung = true
    process.signal(:kill)
    reaped.receive
  end
  Result.new(arm.name, hung, sink.to_s.strip, code)
end

# One swallowed signal per stop is enough: the wait is per thread, so a single
# unanswered one holds the whole stop.
DROP = {"GCRY_STW_TEST_DROP_SUSPENDS" => "1"}
# The same thread, but deaf to the resends as well.
MUTE = {"GCRY_STW_TEST_MUTE_THREADS" => "1", "GCRY_STW_RESEND_LIMIT" => "2"}
# The resend threshold is 20 000 000 spins by default (~a tenth of the stall
# report). Lowered so the arms finish in seconds rather than making the gate
# a minute long; the path taken is identical.
FAST = {"GCRY_STW_RESEND_SPINS" => "200000"}

arms = [
  Arm.new("drop+resend", DROP.merge(FAST), false),
  Arm.new("drop+no-resend", DROP.merge(FAST).merge({"GCRY_STW_RESEND" => "0"}), true),
  Arm.new("double+epoch", {"GCRY_STW_TEST_DOUBLE_SUSPEND" => "1"}, false),
  Arm.new("double+no-epoch", {"GCRY_STW_TEST_DOUBLE_SUSPEND" => "1", "GCRY_STW_EPOCH" => "0"}, true),
  Arm.new("mute+dead", MUTE.merge(FAST).merge({"GCRY_STW_TEST_ESRCH" => "1"}), false),
  Arm.new("mute+live", MUTE.merge(FAST), true),
]

puts "=== STW stop epoch ==="
puts "#{WORKERS} mutator threads, #{COLLECTIONS} collections per arm, #{TIMEOUT_S}s timeout"
puts ""

results = arms.map { |arm| run_arm(self_path, arm) }
results.each do |r|
  puts "  %-16s %s" % [r.name, r.hung ? "HUNG (killed at #{TIMEOUT_S}s)" : r.text]
end
puts ""

def counter(line : String, name : String) : UInt64
  m = line.match(/#{name}=(\d+)/)
  m ? m[1].to_u64 : 0_u64
end

by_name = results.to_h { |r| {r.name, r} }
failures = [] of String

drop = by_name["drop+resend"]
if drop.hung
  failures << "a dropped suspend signal still hangs the stop with the resend on — the " \
              "repair does not work, which is the whole point of the epoch"
else
  if counter(drop.text, "dropped") == 0
    failures << "the drop arm never dropped a signal, so its completion says nothing — " \
                "GCRY_STW_TEST_DROP_SUSPENDS is not reaching the suspend loop"
  end
  if counter(drop.text, "resends") == 0
    failures << "the stop completed without resending, so something other than the resend " \
                "delivered the signal and this arm proves nothing"
  end
end

# The red arm. Without it "the resend works" has no control: a run that
# completes might have completed anyway.
unless by_name["drop+no-resend"].hung
  failures << "GCRY_STW_RESEND=0 completed with a signal dropped — the control arm is not " \
              "red, so the green one is not attributable to the resend"
end

dbl = by_name["double+epoch"]
if dbl.hung
  failures << "a redundant suspend signal after the resume hung the collector even with the " \
              "epoch on — the decline is not happening"
elsif counter(dbl.text, "stale") + counter(dbl.text, "redundant") == 0
  failures << "the double-signal arm declined nothing, so the duplicate never arrived and " \
              "the arm is measuring an empty run"
end

# The other red arm, and the one that matters most: it is the reason this
# repair was refused twice. If it ever goes green the epoch has stopped
# working and the resend above became unsafe again.
unless by_name["double+no-epoch"].hung
  failures << "GCRY_STW_EPOCH=0 survived a redundant suspend signal — the hazard the epoch " \
              "exists for is not being reproduced, so nothing here shows the epoch is load-bearing"
end

ab = by_name["mute+dead"]
if ab.hung
  failures << "the abandonment path did not fire: the stop is still spinning on a handle " \
              "libc says names no live thread, which is the aarch64 job timeout"
elsif counter(ab.text, "abandoned") == 0
  failures << "the mute+dead arm completed without abandoning anything — something other " \
              "than the ESRCH branch let the stop finish"
end

# The honest limit of this repair, and a control for the arm above: a thread
# that never answers and is *alive* still hangs the stop. The resend fixes a
# lost delivery; it does not fix a thread that cannot run its handler, and an
# arm that went green here would mean the abandonment is firing on live
# threads — which would be a collector that stops without stopping them.
unless by_name["mute+live"].hung
  failures << "a thread that ignores every signal and whose handle is live did not hang the " \
              "stop — the abandonment is firing on something other than a dead handle"
end

# Every arm that is expected to finish must have finished all its collections;
# a child that exits early would satisfy "did not hang" without stopping the
# world even once.
results.each do |r|
  next if r.hung
  next if counter(r.text, "collections") >= COLLECTIONS.to_u64
  failures << "#{r.name} exited after #{counter(r.text, "collections")} collections of " \
              "#{COLLECTIONS} — it did not hang because it did not run"
end

if failures.empty?
  puts "PASS — a dropped signal is recovered by the resend, a duplicate is declined,"
  puts "and both controls are red."
  puts ""
  puts "What this does not cover: why a thread fails to acknowledge in the first place."
  puts "The resend repairs a lost delivery; a thread that cannot run its handler at all"
  puts "is still only visible through `SUSPEND STALLED` and the abandonment report."
else
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
