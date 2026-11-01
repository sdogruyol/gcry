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
#             payload has **slack**, and a pointer written there is the last
#             word of the block. `GCRY_MARK_TEST_SHORT_TID` makes the mark stop
#             one word short on blocks of that type, so the child is
#             unreachable as far as the mark is concerned, while the audit —
#             which walks the whole payload — must name it. The knob is a
#             planted miss and nothing else: since 2026-10-04 the mark reads
#             every word of every non-atomic block. Until then the arm used
#             `GCRY_SCAN_CAPS=1`, whose cap the mark no longer applies
#             (`bench/log/linux/2026-10-04-layout-union-collision/`); without a
#             planted miss the scan is fully conservative, the slack *is* read,
#             and the planted edge is not missed at all (measured: 200 of 200
#             planted children survived).
#   clean     the same workload without the planted pointer: the audit must walk
#             a non-trivial number of edges and report **zero** misses. The edge
#             count is the half that matters — an audit that walks nothing also
#             reports zero, and that is how the Darwin RSS reader passed for
#             three releases.
#   --control the knob off: zero edges walked, so the other arms' numbers are
#             attributable to it.
#
# The batch scan has two word loops (`scan_batch_prefetched`): one copy of the
# candidate code for a cycle after a major that scanned under
# `MARK_UNROLL_MIN_SCANNED`, as these small heaps do, and the unrolled loop
# otherwise. `hold-unrolled` and `clean-unrolled` repeat the two arms with
# 1 MiB of pointer slots held, so the collections that see the planted
# pointers run the unrolled loop; each child reports which loop its first of
# them ran, and the parent checks it.
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

# 24 bytes of ivars (type_id + two pointers) — one 32-byte size class, so the
# block's last word is 8 bytes of slack past `instance_sizeof`, which the
# planted miss stops before and the audit still walks.
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
  # Null slots, read word by word: the next major's loop choice comes from
  # this collection's scanned bytes.
  ballast = arm.ends_with?("-unrolled") ? Array(Void*).new(131_072, Pointer(Void).null) : [] of Void*
  GC.collect

  200.times do
    s = Slacker.new
    child = GC.malloc(48)
    if arm.starts_with?("hold")
      # Reachable only through the slack: the mark cannot see it, the audit can.
      s.plant(child)
    else
      # Reachable through a real ivar: both see it.
      s.keep(child)
    end
    keeper << s
  end

  # The planted children are missed, and freed, in the first of these.
  GC.collect
  unrolled = heap.mark_scan_unrolled?
  2.times { GC.collect }

  STDERR.puts "edges=#{heap.mark_audit_edges} misses=#{heap.mark_audit_misses} unrolled=#{unrolled}"
  # Keep the keeper and the ballast alive across the collections above.
  Gcry::Roots.keep_alive(keeper.as(Void*))
  Gcry::Roots.keep_alive(ballast.as(Void*))
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

["hold", "clean", "hold-unrolled", "clean-unrolled"].each do |arm|
  env = control ? {"GCRY_MARK_AUDIT" => "0"} : {"GCRY_MARK_AUDIT" => "1"}
  # The planted miss is what makes the slack unreachable to the mark; see the header.
  env["GCRY_MARK_TEST_SHORT_TID"] = Slacker.crystal_instance_type_id.to_s if arm.starts_with?("hold")
  captured = IO::Memory.new
  Process.run(exe, ["--child=#{arm}"], env: env, output: captured, error: captured)
  text = captured.to_s
  line = text.lines.find(&.starts_with?("edges="))
  unless line
    failures << "#{arm}: the child did not report its counters. What it said:\n#{text.lines.first(6).join("\n")}"
    next
  end
  fields = line.split(' ').to_h { |f| {f.split('=')[0], f.split('=')[1]} }
  edges = fields["edges"].to_u64
  misses = fields["misses"].to_u64
  unrolled = fields["unrolled"]? == "true"
  puts "#{arm}: #{edges} edges walked, #{misses} missed, #{unrolled ? "unrolled" : "one-copy"} loop"

  if unrolled != arm.ends_with?("-unrolled")
    failures << "#{arm}: the planted collection ran the #{unrolled ? "unrolled" : "one-copy"} loop, " \
                "so this arm does not test the loop it is named for"
  end

  if control
    failures << "#{arm}: the knob is off but #{edges} edges were walked" if edges > 0
    next
  end

  if edges == 0
    failures << "#{arm}: the audit walked no edges at all, so a zero miss count means nothing"
    next
  end

  case arm
  when .starts_with?("hold")
    if misses == 0
      failures << "#{arm}: a pointer the mark was made to stop short of is an edge it does not " \
                  "follow, and the audit did not name it — it cannot detect a missed edge"
    end
  else
    if misses > 0
      failures << "#{arm}: #{misses} missed edge(s) with nothing planted. Either the mark is " \
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
