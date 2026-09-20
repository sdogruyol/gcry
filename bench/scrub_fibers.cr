# Does `GCRY_DISABLE_SCRUB_FIBERS` still disable the parked-fiber wipe
# `GCRY_SCRUB_FIBERS` opted into?
#
# `samples/sound_profile.cr` already asserts the *flag*: default off,
# `GCRY_SCRUB_FIBERS=1` overrides `GCRY_SOUND`. It cannot see this knob:
# `GCRY_DISABLE_SCRUB_FIBERS=1` agrees with the default, so the sample
# never asks whether the disable still turns the opt-in back off. The
# spec sets `heap.scrub_fibers_enabled` as a property and never reads
# either env var. The orphan-knob census found the disable in no spec,
# recipe or CI step (`log/linux/2026-09-16-orphan-break-knobs/FINDINGS.md`).
#
# The contract is a pair of counters, not a live object:
#
#   scrub_fibers_enabled   the flag `apply_env_config` wrote
#   fiber_scrub_runs       how many times `scrub_parked_fiber_stacks`
#                          actually ran during `GC.collect`
#
# Three arms as children of this process, so the red direction is built
# every run:
#
#   default     neither knob. Flag off, runs stay 0 — otherwise `--on`
#               cannot show that the opt-in did the work, and a default-on
#               regression would be this item's disease in the other
#               direction.
#
#   --on        `GCRY_SCRUB_FIBERS=1`. Flag on, and `fiber_scrub_runs`
#               must move. A flag that is true while the collect path
#               never enters the wipe is a knob that silently does
#               nothing.
#
#   --disabled  both knobs. Must match default on *both* counters.
#               `apply_env_config` applies the opt-in first and the
#               disable second; a disable that no longer disables leaves
#               every `GCRY_SCRUB_FIBERS=1` arm in the tree green.
#
#   crystal build -Dgc_none bench/scrub_fibers.cr -o bin/scrub_fibers
#   bin/scrub_fibers
#
# The parent forks; `GCRY_DISABLE_SCRUB_FIBERS=1` is the breaking knob.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "scrub_fibers requires -Dgc_none (gcry as process GC)" %}
{% end %}

def park_and_collect : Nil
  done = Channel(Nil).new
  8.times do
    spawn { done.receive }
  end
  32.times { Fiber.yield }
  GC.collect
  8.times { done.send(nil) }
end

def report : Nil
  park_and_collect
  heap = Gcry.default_heap
  puts "scrub_fibers_enabled=#{heap.scrub_fibers_enabled}"
  puts "fiber_scrub_runs=#{heap.fiber_scrub_runs}"
  puts "fiber_scrub_bytes_total=#{heap.fiber_scrub_bytes_total}"
  puts "collections=#{heap.collections}"
end

if ARGV.includes?("--child")
  report
  exit 0
end

record Arm, name : String, enabled : Bool, runs : UInt64, collections : UInt64, text : String

def run_arm(exe : String, env : Hash(String, String), name : String) : Arm
  captured = IO::Memory.new
  status = Process.run(exe, ["--child"], env: env, output: captured, error: captured)
  text = captured.to_s
  unless status.success?
    STDERR.puts "FAIL: #{name}: the child did not exit cleanly (#{status.exit_code?.inspect})"
    STDERR.puts text.lines.first(8).join("\n")
    exit 1
  end
  enabled_line = text.lines.find(&.starts_with?("scrub_fibers_enabled="))
  runs_line = text.lines.find(&.starts_with?("fiber_scrub_runs="))
  collections_line = text.lines.find(&.starts_with?("collections="))
  unless enabled_line && runs_line && collections_line
    STDERR.puts "FAIL: #{name}: the child did not report its counters. What it said:"
    STDERR.puts text.lines.first(8).join("\n")
    exit 1
  end
  enabled = enabled_line.split('=')[1] == "true"
  runs = runs_line.split('=')[1].to_u64
  collections = collections_line.split('=')[1].to_u64
  Arm.new(name, enabled, runs, collections, text)
end

exe = Process.executable_path.not_nil!
failures = [] of String

puts "=== parked-fiber scrub, and the knob that turns it back off ==="

default = run_arm(exe, {} of String => String, "default")
on = run_arm(exe, {"GCRY_SCRUB_FIBERS" => "1"}, "on")
disabled = run_arm(exe, {
  "GCRY_SCRUB_FIBERS"         => "1",
  "GCRY_DISABLE_SCRUB_FIBERS" => "1",
}, "disabled")

{default, on, disabled}.each do |arm|
  puts "#{arm.name}: scrub_fibers_enabled=#{arm.enabled} fiber_scrub_runs=#{arm.runs} collections=#{arm.collections}"
end

{default, on, disabled}.each do |arm|
  if arm.collections == 0
    failures << "#{arm.name}: collections=0 — GC.collect did not run, so fiber_scrub_runs cannot speak"
  end
end

if default.enabled
  failures << "default: scrub_fibers_enabled=true — parked-fiber scrub is opt-in " \
              "(GCRY_SCRUB_FIBERS=1). See docs/SOUND-DEFAULTS.md"
end
if default.runs != 0
  failures << "default: fiber_scrub_runs=#{default.runs} with the flag off — " \
              "scrub_parked_fiber_stacks ran when apply_env_config left it disabled"
end
unless on.enabled
  failures << "on: GCRY_SCRUB_FIBERS=1 left scrub_fibers_enabled=false — the opt-in did not take"
end
if on.runs == 0
  failures << "on: GCRY_SCRUB_FIBERS=1 left fiber_scrub_runs=0 after a collection — " \
              "the flag is on but collect never entered scrub_parked_fiber_stacks, " \
              "so a larger flag is not evidence the wipe ran"
end
if disabled.enabled
  failures << "disabled: GCRY_DISABLE_SCRUB_FIBERS=1 left scrub_fibers_enabled=true — " \
              "the knob no longer turns the opt-in back off"
end
if disabled.runs != 0
  failures << "disabled: GCRY_DISABLE_SCRUB_FIBERS=1 left fiber_scrub_runs=#{disabled.runs} — " \
              "the wipe still ran, and every GCRY_SCRUB_FIBERS=1 arm in the tree would stay green"
end

if failures.empty?
  puts
  puts "ok — GCRY_SCRUB_FIBERS=1 set the flag and fiber_scrub_runs #{default.runs} → #{on.runs}; " \
       "GCRY_DISABLE_SCRUB_FIBERS=1 put both back " \
       "(enabled=#{disabled.enabled}, runs=#{disabled.runs})."
  exit 0
end

puts
failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
