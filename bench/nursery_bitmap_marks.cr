# Does a minor collection clear the mark the next one will read?
#
# The nursery keeps the **header** representation under every setting: the
# bitmap allocator's chunks are old-generation only (`sweep_small_blocks`
# dispatches per chunk, and a bitmap sweep of a nursery chunk whose `occ` is
# all zero would compute `live == 0` and reclaim every live object in it). So
# `bitmap_chunk?` — the predicate every mark *read* goes through — excludes
# nursery chunks.
#
# Both mark *clear* sites used to gate on the global `@bitmap_marks` instead.
# On a nursery chunk that meant `clear_nursery_marks` zeroed a bitmap nothing
# ever writes while the header mark stayed set, and `clear_block_mark` skipped
# the header clear for the same reason. The block then read marked forever:
# `mark_impl` returns early on a marked block without scanning it, so anything
# reachable **only** through it was never traced and was reclaimed while live.
#
# Until 2026-09-20 this was a hollow gate on the compile default:
# `Heap#nursery_enabled=` is a no-op without `-Dgcry_block_headers`, so
# `minor_collect` returned immediately and the child survived as an ordinary
# uncollected object. `bitmap_marks=` is the same no-op there. Both arms
# would have stayed green through the global-flag clear.
#
# One minor is enough to show it. The order matters: the parent must carry a
# mark out of a major, and the child must be allocated after that major so it
# is unmarked and reachable only through the parent.
#
#   crystal build -Dgc_none -Dgcry_block_headers bench/nursery_bitmap_marks.cr -o bin/nursery_bitmap_marks
#   bin/nursery_bitmap_marks
#   GCRY_NURSERY_MARKS_GLOBAL=1 bin/nursery_bitmap_marks --disabled
#
# Dropping `-Dgcry_block_headers`: exit 64 (nursery never on). Dropping the
# knob from `--disabled`: exit 64. Either way the gate goes red rather than
# hiding.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "nursery_bitmap_marks requires -Dgc_none (gcry as process GC)" %}
{% end %}

CANARY           = 0x00C0_FFEE_C0FF_EE00_u64
REISSUE_ATTEMPTS =                       400

DISABLED = ARGV.includes?("--disabled")
GLOBAL   = ENV["GCRY_NURSERY_MARKS_GLOBAL"]? == "1"

if DISABLED && !GLOBAL
  STDERR.puts "--disabled needs GCRY_NURSERY_MARKS_GLOBAL=1: without the global clear this arm would require a live child to vanish while the per-chunk clear is still scanning it."
  exit 64
end

record Arm, label : String, marks : Bool, alloc : Bool
record Outcome, live : Bool, reissued : Int32, intact : Bool

# Returns an Outcome, or a failure string from the setup.
def run(arm : Arm) : Outcome | String
  heap = Gcry::Heap.new
  heap.nursery_enabled = true
  heap.nursery_threshold = UInt64::MAX
  heap.adaptive_nursery = false
  heap.nursery_marks_global = GLOBAL
  if arm.alloc
    heap.bitmap_alloc = true
  else
    heap.bitmap_marks = arm.marks
  end

  begin
    unless heap.nursery_enabled
      return "nursery did not enable (headerless compile default, or GCRY_DISABLE_NURSERY). Build with -Dgcry_block_headers."
    end
    if DISABLED && !heap.nursery_marks_global
      return "--disabled needs GCRY_NURSERY_MARKS_GLOBAL=1: the property is off, so the per-chunk clear is still running."
    end

    parent = heap.malloc(64)
    heap.add_root(parent)

    # Major: the parent is marked. Under the bitmap representation nothing
    # clears that mark per block, so it has to be the minor's job.
    heap.collect(scan_stack: false)

    child = heap.malloc(64)
    child_addr = child.address
    child.as(UInt64*)[1] = CANARY
    # The parent's first word is the only reference to the child.
    parent.as(UInt64*).value = child_addr
    child = Pointer(Void).null

    heap.minor_collect(scan_stack: false)

    live = heap.live?(Pointer(Void).new(child_addr))
    reissued = 0
    REISSUE_ATTEMPTS.times do
      reissued += 1 if heap.malloc(64).address == child_addr
    end
    intact = Pointer(UInt64).new(child_addr)[1] == CANARY

    puts "  #{arm.label}: child_live=#{live} reissued=#{reissued} canary_intact=#{intact}"
    Outcome.new(live, reissued, intact)
  ensure
    heap.destroy
  end
end

puts "=== nursery marks under the bitmap representation ==="
puts DISABLED ? "mode: disabled (GCRY_NURSERY_MARKS_GLOBAL=1, the pre-fix global clear)" : "mode: shipped (per-chunk clear)"
puts ""

failures = [] of String
arms = [
  Arm.new("header marks     ", false, false),
  Arm.new("bitmap marks     ", true, false),
  Arm.new("bitmap allocator ", true, true),
]
arms.each do |arm|
  result = run(arm)
  if result.is_a?(String)
    STDERR.puts "FAIL: #{arm.label.strip}: #{result}"
    exit 64 if result.includes?("did not enable") || result.includes?("GCRY_NURSERY_MARKS_GLOBAL")
    failures << "#{arm.label.strip}: #{result}"
    next
  end

  bitmap_arm = arm.marks || arm.alloc
  if DISABLED && bitmap_arm
    if result.live
      failures << "#{arm.label.strip}: the child survived a global-flag clear — GCRY_NURSERY_MARKS_GLOBAL no longer leaves the header mark set, so the only way this gate can fail is a hand edit of clear_nursery_marks again"
    end
  elsif DISABLED && !bitmap_arm
    unless result.live && result.reissued == 0 && result.intact
      failures << "#{arm.label.strip}: the header-marks control died under the knob — the break has to be the global @bitmap_marks gate, not 'every minor loses the child'"
    end
  else
    unless result.live
      failures << "#{arm.label.strip}: the child was reclaimed after one minor, and the parent holding it was rooted — the minor did not clear the parent's mark, so the parent was never scanned"
    end
    if result.reissued > 0
      failures << "#{arm.label.strip}: the child's address was handed out again #{result.reissued} times while it was still reachable"
    end
    unless result.intact
      failures << "#{arm.label.strip}: the child's payload was overwritten while it was still reachable"
    end
  end
end

if failures.empty?
  puts
  if DISABLED
    puts "ok — the global-flag clear reclaims a child reachable only through a marked nursery parent"
    puts "on the bitmap arms, and the header-marks control still keeps it"
  else
    puts "ok — a minor clears the mark the next read consults, in both representations"
  end
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
