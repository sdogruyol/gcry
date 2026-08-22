# Does the STW watchdog fire, and only when it should?
#
# `GCRY_STW_WATCHDOG_MS` arms a raw watcher thread that prints which phase the
# collector is stuck in when the world has been stopped too long. A watchdog is
# exactly the kind of thing that can sit in a codebase for a year doing nothing
# — nobody notices a diagnostic that never prints — so this drives it from both
# sides:
#
#   armed + stalled     must print, and must name the phase that stalled
#   armed + not stalled must stay silent (no false alarm on ordinary pauses)
#   stalled but unarmed must stay silent (the knob is what gates it)
#
# The stall is `GCRY_STW_TEST_STALL_MS`, a research knob that holds the world
# stopped inside the thread-stacks phase. It exists for this test: without a run
# the watchdog is *expected* to fire on, "it did not print" has two readings and
# only one of them is good.
#
#   crystal build -Dgc_none bench/stw_watchdog.cr -o bin/stw_watchdog
#   bin/stw_watchdog
#   bin/stw_watchdog --child        # one collection (used as the child)

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "stw_watchdog requires -Dgc_none (gcry as process GC)" %}
{% end %}

THRESHOLD_MS = 200
STALL_MS     = 900
# The "no false alarm" arm runs at a deliberately generous threshold. At 200 ms
# it would flake on a loaded CI runner, where the collector can simply be
# descheduled for that long — and it would not buy detection in exchange: a
# watchdog with its threshold check removed fires on *any* stopped phase, so this
# arm still catches that, while the stalled arm's duration bound is what actually
# pins the threshold (measured: with the check removed it reported 49 ms).
QUIET_THRESHOLD_MS = 5000

# ── Child: one collection, under whatever env the parent set ─────────────────
if ARGV.includes?("--child")
  # The suspend arm needs mutator threads, or `n of m already have` is `0 of 0`
  # and the count proves nothing. Cheap and harmless for the other arms.
  stop = Atomic(Int32).new(0)
  4.times do
    Thread.new do
      while stop.get == 0
        req = LibC::Timespec.new(tv_sec: 0, tv_nsec: 2_000_000)
        LibC.nanosleep(pointerof(req), Pointer(LibC::Timespec).null)
      end
    end
  end
  GC.collect
  stop.set(1)
  puts "collected"
  exit 0
end

# ── Parent ───────────────────────────────────────────────────────────────────
self_path = Process.executable_path || "bin/stw_watchdog"

record = {} of String => String

def run_child(self_path : String, env : Hash(String, String)) : String
  err = IO::Memory.new
  status = Process.run(self_path, ["--child"], env: env,
    output: Process::Redirect::Close, error: err)
  raise "child failed: #{status.exit_code}" unless status.success?
  err.to_s
end

puts "=== STW watchdog ==="
puts "threshold #{THRESHOLD_MS} ms, stall #{STALL_MS} ms in the thread-stacks phase"
puts "quiet arm runs at #{QUIET_THRESHOLD_MS} ms (CI runners deschedule; see the comment)"
puts ""

armed_stalled = run_child(self_path, {
  "GCRY_STW_WATCHDOG_MS"   => THRESHOLD_MS.to_s,
  "GCRY_STW_TEST_STALL_MS" => STALL_MS.to_s,
})
armed_quiet = run_child(self_path, {"GCRY_STW_WATCHDOG_MS" => QUIET_THRESHOLD_MS.to_s})
unarmed_stalled = run_child(self_path, {"GCRY_STW_TEST_STALL_MS" => STALL_MS.to_s})
# The suspend phase is a different one, and it is the only one the aarch64 hang
# has ever been seen in (2026-08-22, run `32575506486`). Its report names the
# thread being waited for, which `GCRY_STW_TEST_STALL_MS` cannot exercise
# because it holds thread-stacks instead.
armed_suspend = run_child(self_path, {
  "GCRY_STW_WATCHDOG_MS"           => THRESHOLD_MS.to_s,
  "GCRY_STW_TEST_SUSPEND_STALL_MS" => STALL_MS.to_s,
})

# And the report that runs *inside* the suspend wait rather than outside it: it
# is the only one that can ask whether the thread being waited for is still
# there. Fired by lowering its spin threshold, since arranging a thread that
# genuinely never answers is the defect itself.
armed_inspin = run_child(self_path, {
  "GCRY_STW_WATCHDOG_MS"     => THRESHOLD_MS.to_s,
  "GCRY_SUSPEND_STALL_SPINS" => "1",
})

record["armed+stalled"] = armed_stalled
record["armed+suspend"] = armed_suspend
record["armed+in-spin"] = armed_inspin
record["armed+quiet"] = armed_quiet
record["unarmed+stalled"] = unarmed_stalled

record.each do |name, stderr_text|
  first = stderr_text.lines.find { |l| l.includes?("STOP-THE-WORLD") || l.includes?("SUSPEND STALLED") }
  puts "  %-16s %s" % [name, first ? first.strip : "(silent)"]
end
puts ""

failures = [] of String

fired = armed_stalled.includes?("STOP-THE-WORLD STALLED")
unless fired
  failures << "armed + a #{STALL_MS} ms stall printed nothing — the watchdog cannot " \
              "be shown to work, so its silence elsewhere means nothing"
end

if fired && !armed_stalled.includes?("phase=thread-stacks")
  failures << "fired but named the wrong phase (expected thread-stacks): " \
              "#{armed_stalled.lines.find(&.includes?("STALLED"))}"
end

# The reported figure must be a real measurement, not a constant: it has to be at
# least the threshold and no more than the stall plus scheduling slack.
if fired
  if m = armed_stalled.match(/STALLED (\d+) ms/)
    ms = m[1].to_i
    if ms < THRESHOLD_MS || ms > STALL_MS + 500
      failures << "reported #{ms} ms, outside [#{THRESHOLD_MS}, #{STALL_MS + 500}] — " \
                  "the number is not tracking the actual stall"
    end
  else
    failures << "fired without a parseable duration"
  end
end

# The suspend arm: it must fire, name that phase, and name a thread. A report
# that says "stalled in suspend" and stops there is what the first sighting of
# the aarch64 hang produced, and it is one question short.
unless armed_suspend.includes?("phase=suspend")
  failures << "the suspend stall did not fire or named another phase — the report that " \
              "names the thread a stopped world is waiting for is unproven"
end
unless armed_suspend.includes?("to acknowledge its suspend signal")
  failures << "the suspend arm fired without naming the thread it was waiting for"
end
if m = armed_suspend.match(/(\d+) of (\d+) already have/)
  if m[2].to_i == 0
    failures << "the suspend report counted 0 threads to wait for, so its count says nothing"
  end
else
  failures << "the suspend report carried no acknowledged/expected count"
end

unless armed_inspin.includes?("SUSPEND STALLED on thread 0x")
  failures << "the in-spin report never fired with its threshold at one spin — the line that " \
              "names the thread a stop is waiting for is unproven"
end
# With every thread healthy the handle must read live; the other branch is the
# defect and cannot be arranged here.
if armed_inspin.includes?("SUSPEND STALLED") && !armed_inspin.includes?("the handle is live")
  failures << "the in-spin report fired but could not say whether the handle was live: " \
              "#{armed_inspin.lines.find(&.includes?("SUSPEND STALLED"))}"
end

if armed_quiet.includes?("STOP-THE-WORLD")
  failures << "armed but *not* stalled still printed — a watchdog that cries wolf on " \
              "an ordinary collection is worse than none"
end

if unarmed_stalled.includes?("STOP-THE-WORLD")
  failures << "printed while unarmed — GCRY_STW_WATCHDOG_MS does not gate it"
end

if failures.empty?
  puts "PASS — fires on a real stall, names the phase, silent otherwise."
  puts ""
  puts "What this does not cover: the watchdog is a raw pthread, so it keeps running"
  puts "while the world is stopped. That is the point, and it is also why it holds no"
  puts "GC object — its stack is never scanned."
else
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
