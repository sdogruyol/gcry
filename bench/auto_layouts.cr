# Does `GCRY_DISABLE_AUTO_LAYOUTS` still disable the whole-program walk
# `GCRY_AUTO_LAYOUTS` opted into?
#
# `ivar-layout-roots` already runs under `GCRY_AUTO_LAYOUTS=1`, and that is
# the shipping route into the same `register` macro. It cannot see this knob:
# those arms also call `Gcry.register_layout` on the probe types explicitly,
# so the disable leaves them registered either way, and a survival assertion
# would not discriminate anyway — the conservative body scan reaches the
# same words. The orphan-knob census found the disable in no spec, recipe or
# CI step (`log/linux/2026-09-16-orphan-break-knobs/FINDINGS.md`).
#
# The contract is a pair of counters, not a live object:
#
#   layout_entries     `Gcry::Layout.size` after `GC.init`
#   probe_registered   whether a type this file declares, which
#                      `register_builtins` does not name, has an entry
#
# Three arms as children of this process, so the red direction is built
# every run:
#
#   builtins    neither knob. The curated table. `layout_entries > 0` and
#               the probe is *not* registered — otherwise `--auto` cannot
#               show that the whole-program walk did the work.
#
#   --auto      `GCRY_AUTO_LAYOUTS=1`. `layout_entries` must be strictly
#               greater than builtins, and the probe must be registered.
#               That is the opt-in doing what `docs/HARDENING.md` says.
#
#   --disabled  both knobs. Must match builtins on *both* counters. A
#               disable that no longer disables leaves every AUTO_LAYOUTS
#               arm in the tree green, which is this item's disease.
#
#   crystal build -Dgc_none bench/auto_layouts.cr -o bin/auto_layouts
#   bin/auto_layouts
#
# The parent forks; `GCRY_DISABLE_AUTO_LAYOUTS=1` is the breaking knob.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "auto_layouts requires -Dgc_none (gcry as process GC)" %}
{% end %}

# Concrete, with a Reference ivar, so `register` installs a precise entry
# rather than skipping or falling back to a cap. Not named by
# `register_builtins` — that is the whole point of the probe.
class AutoLayoutProbe < Reference
  property name : String = "probe"
end

PROBE_ID = AutoLayoutProbe.crystal_instance_type_id

def report : Nil
  registered = !Gcry::Layout.entry_for(PROBE_ID).nil?
  puts "layout_entries=#{Gcry::Layout.size}"
  puts "unsafe_skips=#{Gcry::Layout.unsafe_skips_count}"
  puts "probe_registered=#{registered}"
  puts "probe_type_id=#{PROBE_ID}"
end

if ARGV.includes?("--child")
  report
  exit 0
end

record Arm, name : String, entries : Int32, probe : Bool, text : String

def run_arm(exe : String, env : Hash(String, String), name : String) : Arm
  captured = IO::Memory.new
  status = Process.run(exe, ["--child"], env: env, output: captured, error: captured)
  text = captured.to_s
  unless status.success?
    STDERR.puts "FAIL: #{name}: the child did not exit cleanly (#{status.exit_code?.inspect})"
    STDERR.puts text.lines.first(8).join("\n")
    exit 1
  end
  entries_line = text.lines.find(&.starts_with?("layout_entries="))
  probe_line = text.lines.find(&.starts_with?("probe_registered="))
  unless entries_line && probe_line
    STDERR.puts "FAIL: #{name}: the child did not report its counters. What it said:"
    STDERR.puts text.lines.first(8).join("\n")
    exit 1
  end
  entries = entries_line.split('=')[1].to_i
  probe = probe_line.split('=')[1] == "true"
  Arm.new(name, entries, probe, text)
end

exe = Process.executable_path.not_nil!
failures = [] of String

puts "=== auto layouts, and the knob that turns them back off ==="

builtins = run_arm(exe, {} of String => String, "builtins")
auto = run_arm(exe, {"GCRY_AUTO_LAYOUTS" => "1"}, "auto")
disabled = run_arm(exe, {
  "GCRY_AUTO_LAYOUTS"         => "1",
  "GCRY_DISABLE_AUTO_LAYOUTS" => "1",
}, "disabled")

{builtins, auto, disabled}.each do |arm|
  puts "#{arm.name}: layout_entries=#{arm.entries} probe_registered=#{arm.probe}"
end

if builtins.entries <= 0
  failures << "builtins: layout_entries=#{builtins.entries} — register_builtins installed nothing, " \
              "so the other two arms have no table to compare against"
end
if builtins.probe
  failures << "builtins: AutoLayoutProbe is already registered. It is not a builtin; if it has an " \
              "entry here, --auto cannot show that the whole-program walk did the work"
end
if auto.entries <= builtins.entries
  failures << "auto: GCRY_AUTO_LAYOUTS=1 left layout_entries at #{auto.entries}, not above the " \
              "builtins table (#{builtins.entries}) — the opt-in did not register anything the " \
              "curated walk missed"
end
unless auto.probe
  failures << "auto: AutoLayoutProbe has no entry under GCRY_AUTO_LAYOUTS=1. The whole-program " \
              "walk did not reach a concrete Reference this file declares, so a larger " \
              "layout_entries count is not evidence it registered what it claims"
end
if disabled.entries != builtins.entries
  failures << "disabled: GCRY_DISABLE_AUTO_LAYOUTS=1 left layout_entries=#{disabled.entries} " \
              "against builtins #{builtins.entries} — the knob no longer returns the curated table"
end
if disabled.probe
  failures << "disabled: AutoLayoutProbe is still registered with GCRY_DISABLE_AUTO_LAYOUTS=1 — " \
              "the knob no longer disables the whole-program walk, and every AUTO_LAYOUTS arm " \
              "in the tree would stay green"
end

if failures.empty?
  puts
  puts "ok — GCRY_AUTO_LAYOUTS=1 grew the table #{builtins.entries} → #{auto.entries} and " \
       "registered a type builtins do not name; GCRY_DISABLE_AUTO_LAYOUTS=1 put both back " \
       "(#{disabled.entries}, probe_registered=false)."
  exit 0
end

puts
failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
