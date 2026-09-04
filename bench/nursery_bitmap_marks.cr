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
# One minor is enough to show it. The order matters: the parent must carry a
# mark out of a major, and the child must be allocated after that major so it
# is unmarked and reachable only through the parent.
#
#   crystal build -Dgc_none bench/nursery_bitmap_marks.cr -o bin/nursery_bitmap_marks
#   bin/nursery_bitmap_marks
#
# The header arm is the control: it always passed, and if it ever fails the
# harness is wrong rather than the collector.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "nursery_bitmap_marks requires -Dgc_none (gcry as process GC)" %}
{% end %}

CANARY           = 0x00C0_FFEE_C0FF_EE00_u64
REISSUE_ATTEMPTS =                       400

record Arm, label : String, marks : Bool, alloc : Bool

# Returns a failure string, or nil.
def run(arm : Arm) : String?
  heap = Gcry::Heap.new
  heap.nursery_enabled = true
  heap.nursery_threshold = UInt64::MAX
  heap.adaptive_nursery = false
  if arm.alloc
    heap.bitmap_alloc = true
  else
    heap.bitmap_marks = arm.marks
  end

  begin
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

    unless live
      return "#{arm.label}: the child was reclaimed after one minor, and the parent " \
             "holding it was rooted — the minor did not clear the parent's mark, so " \
             "the parent was never scanned"
    end
    if reissued > 0
      return "#{arm.label}: the child's address was handed out again #{reissued} times " \
             "while it was still reachable"
    end
    unless intact
      return "#{arm.label}: the child's payload was overwritten while it was still reachable"
    end
    nil
  ensure
    heap.destroy
  end
end

puts "=== nursery marks under the bitmap representation ==="

failures = [] of String
[Arm.new("header marks     ", false, false),
 Arm.new("bitmap marks     ", true, false),
 Arm.new("bitmap allocator ", true, true)].each do |arm|
  if failure = run(arm)
    failures << failure
  end
end

if failures.empty?
  puts
  puts "ok — a minor clears the mark the next read consults, in both representations"
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
