# Does a process that goes idle after a burst give the burst's memory back?
#
# An emptied bitmap chunk past the warm budget is kept mapped for one cycle
# ("unmap grace", `collect_sweep.cr`) and unmapped at the next major unless a
# cursor takes it. An idle process has no next major, so whatever the last
# major graced stays mapped for good. Uncapped, that was every emptied chunk
# past the budget: a 200 MB burst whose live set then dropped idled at 78.7 MB
# RSS with an 8 MiB threshold, against 6.3 MB after `GC.collect`. Capped at one
# threshold (2026-09-23) it idles at 22.4 MB.
#
# Two automatic majors after the drop, not three, and the count is the test.
# The first keeps the old threshold's worth warm (64 MiB here) and graces the
# rest; the second, at the adapted threshold, unmaps what the first graced but
# finds those 64 MiB of warm chunks past the new budget and graces *them*; a
# third unmaps them. So the uncapped grace leaks in exactly one idle window —
# after the second major — and a gate that waited for a third passed both arms
# (20.4 MB mapped uncapped, measured while writing this).
#
# The check is on heap counters, not RSS, so it is exact and portable: of the
# chunks the last sweep found empty, the ones it left mapped (neither unmapped
# nor made dormant) must fit what it is allowed to keep —
#
#     fully_free - released - dormant <= warm budget + one threshold of grace
#
# A first version bounded the whole small mapping with a guess at how many
# chunks the live data spans, and passed by one chunk in an unoptimised build.
# The red arm is `GCRY_UNMAP_GRACE_UNBOUNDED=1`, which must fail it.
#
#   crystal build -Dgc_none bench/idle_rss_after_burst.cr -o bin/idle_rss_after_burst
#   bin/idle_rss_after_burst                                  # PASS
#   GCRY_UNMAP_GRACE_UNBOUNDED=1 bin/idle_rss_after_burst     # FAIL

require "../src/gcry"
require "json"

class BurstNode
  @link : BurstNode? = nil
  @pad = StaticArray(Int64, 6).new(0_i64)
  property link
end

def stats : JSON::Any
  JSON.parse(Gcry::Observability.json_stats)
end

# In its own frame, not inlined, so nothing in the caller's frame still points
# at the list once it returns: in an unoptimised build a slot of the top-level
# frame kept the head, the conservative scan followed it, and all 200 MB stayed
# live (`live 209783264`) — the gate then measured a heap with no burst to drop.
@[NoInline]
def burst(mb : Int32) : Nil
  head = nil.as(BurstNode?)
  (mb.to_i64 * 1024 * 1024 // 64).times do
    n = BurstNode.new
    n.link = head
    head = n
  end
end

burst_mb = (ENV["BURST_MB"]? || "200").to_i
burst(burst_mb)

majors = stats["major_collections"].as_i64
sink = nil.as(BurstNode?)
while stats["major_collections"].as_i64 < majors + 2
  2000.times { sink = BurstNode.new }
end

s = stats
mapped = s["small_mapped_bytes"].as_i64
# What the last sweep kept mapped among the chunks it found empty: all of them,
# minus the ones it unmapped, minus the ones it made dormant (no resident pages).
fully_free = s["fully_free_chunk_bytes"].as_i64
released = s["released_chunk_bytes"].as_i64
dormant = s["dormant_chunk_bytes"].as_i64
kept_empty = fully_free - released - dormant
warm = s["empty_chunk_warm_retain"].as_i64
threshold = s["gc_threshold"].as_i64
bound = warm + threshold

puts "burst #{burst_mb} MB, then 2 automatic majors, then idle"
puts "  small_mapped_bytes #{mapped}"
puts "  empty chunks kept  #{kept_empty} = fully free #{fully_free} - unmapped #{released} - dormant #{dormant}"
puts "  bound              #{bound} = warm #{warm} + threshold #{threshold}"
if kept_empty <= bound
  puts "PASS: the empty chunks left mapped fit what one cycle can reuse"
else
  puts "FAIL: #{kept_empty - bound} bytes of emptied chunks stay mapped with no major coming to release them"
  exit 1
end
