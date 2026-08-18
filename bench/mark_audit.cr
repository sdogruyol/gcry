# Does the mark reach everything a marked object points at — and would we know?
#
# `GCRY_MARK_AUDIT=1` walks every marked block after `mark_loop` and before
# `sweep` and reports any base pointer into a **used but unmarked** block: the
# sweep is about to free something a live object points at
# (`src/gcry/mark_audit.cr`). It was written for the 2026-08-16 use-after-free
# hunt, where every other reading had been eliminated and the question left was
# whether the mark was complete at all.
#
# An audit that reports nothing is worth nothing unless it can be shown to
# report something. This gate plants a missed edge it knows the shape of.
#
#   hold      an object whose `instance_sizeof` is smaller than its size class's
#             payload has **slack**, and under `GCRY_SCAN_CAPS=1` the mark stops
#             at `instance_sizeof` and never reads it. Writing a pointer into
#             that slack makes the child unreachable as far as the mark is
#             concerned, while the audit — which walks the whole payload — must
#             name it. This is not a collector defect: Crystal does not write
#             into slack, which is what makes the cap sound and this a usable
#             control. The arm sets `GCRY_SCAN_CAPS=1` itself, because the caps
#             are opt-in — without them the scan is fully conservative, the
#             slack *is* read, and the planted edge is not missed at all
#             (measured: 200 of 200 planted children survived).
#   clean     the same workload without the planted pointer: the audit must walk
#             a non-trivial number of edges and report **zero** misses. The edge
#             count is the half that matters — an audit that walks nothing also
#             reports zero, and that is how the Darwin RSS reader passed for
#             three releases.
#   --control the knob off: zero edges walked, so the other arms' numbers are
#             attributable to it.
#
#   crystal build -Dgc_none bench/mark_audit.cr -o bin/mark_audit
#   GCRY_MARK_AUDIT=1 bin/mark_audit
#   bin/mark_audit --control
#
# `--child=<arm>` is the half that runs under the collector; the parent reads
# its stderr, because the audit reports through `RawOut` from inside the pause.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "mark_audit requires -Dgc_none (gcry as process GC)" %}
{% end %}

# 24 bytes of ivars (type_id + two pointers) — one 32-byte size class, so there
# are 8 bytes of slack past `instance_sizeof` that the mark's `scan_cap` stops
# before and the audit still walks.
class Slacker
  @a : Pointer(Void) = Pointer(Void).null
  @b : Pointer(Void) = Pointer(Void).null

  def plant(child : Void*) : Nil
    # Past `instance_sizeof(Slacker)`, inside the block gcry handed out.
    (self.as(UInt8*) + instance_sizeof(Slacker)).as(Void**).value = child
  end

  def keep(child : Void*) : Nil
    @a = child
  end
end

def run_child(arm : String) : NoReturn
  heap = Gcry.default_heap
  keeper = [] of Slacker

  200.times do
    s = Slacker.new
    child = GC.malloc(48)
    case arm
    when "hold"
      # Reachable only through the slack: the mark cannot see it, the audit can.
      s.plant(child)
    when "clean"
      # Reachable through a real ivar: both see it.
      s.keep(child)
    end
    keeper << s
  end

  3.times { GC.collect }

  STDERR.puts "edges=#{heap.mark_audit_edges} misses=#{heap.mark_audit_misses}"
  # Keep the keeper alive across the collections above.
  Gcry::Roots.keep_alive(keeper.as(Void*))
  exit 0
end

ARGV.each do |arg|
  if arg =~ /--child=(.+)/
    run_child($1)
  end
end

control = ARGV.includes?("--control")
puts "=== mark completeness audit ==="
puts "mode: #{control ? "control (GCRY_MARK_AUDIT unset; nothing may be walked)" : "hold (audit on)"}"

exe = Process.executable_path.not_nil!
failures = [] of String

["hold", "clean"].each do |arm|
  env = control ? {"GCRY_MARK_AUDIT" => "0"} : {"GCRY_MARK_AUDIT" => "1"}
  # The cap is what makes the slack unreachable to the mark; see the header.
  env["GCRY_SCAN_CAPS"] = "1" if arm == "hold"
  captured = IO::Memory.new
  Process.run(exe, ["--child=#{arm}"], env: env, output: captured, error: captured)
  text = captured.to_s
  line = text.lines.find(&.starts_with?("edges="))
  unless line
    failures << "#{arm}: the child did not report its counters. What it said:\n#{text.lines.first(6).join("\n")}"
    next
  end
  edges = line.split(' ')[0].split('=')[1].to_u64
  misses = line.split(' ')[1].split('=')[1].to_u64
  puts "#{arm}: #{edges} edges walked, #{misses} missed"

  if control
    failures << "#{arm}: the knob is off but #{edges} edges were walked" if edges > 0
    next
  end

  if edges == 0
    failures << "#{arm}: the audit walked no edges at all, so a zero miss count means nothing"
    next
  end

  case arm
  when "hold"
    if misses == 0
      failures << "hold: a pointer living only in a block's scan_cap slack is an edge the mark " \
                  "does not follow, and the audit did not name it — it cannot detect a missed edge"
    end
  when "clean"
    if misses > 0
      failures << "clean: #{misses} missed edge(s) with nothing planted. Either the mark is " \
                  "incomplete on this workload, or the audit reports edges that are not real"
    end
  end
end

if failures.empty?
  puts
  if control
    puts "ok — with the knob off nothing is walked, so the other run's edge counts are attributable " \
         "to the audit"
  else
    puts "ok — the audit names a planted edge the mark does not follow, and reports none on the same " \
         "workload without it"
  end
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
