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

# ── Child: one collection, under whatever env the parent set ─────────────────
if ARGV.includes?("--child")
  GC.collect
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
puts ""

armed_stalled = run_child(self_path, {
  "GCRY_STW_WATCHDOG_MS"   => THRESHOLD_MS.to_s,
  "GCRY_STW_TEST_STALL_MS" => STALL_MS.to_s,
})
armed_quiet = run_child(self_path, {"GCRY_STW_WATCHDOG_MS" => THRESHOLD_MS.to_s})
unarmed_stalled = run_child(self_path, {"GCRY_STW_TEST_STALL_MS" => STALL_MS.to_s})

record["armed+stalled"] = armed_stalled
record["armed+quiet"] = armed_quiet
record["unarmed+stalled"] = unarmed_stalled

record.each do |name, stderr_text|
  first = stderr_text.lines.find(&.includes?("STOP-THE-WORLD"))
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
