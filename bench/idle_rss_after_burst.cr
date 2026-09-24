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
# The major that *sees* the drop, then exactly one more, and the count is the
# test. The major that reclaims the burst keeps the old threshold's worth warm
# (64 MiB here) and graces the rest; the next, at the adapted threshold,
# unmaps what that one graced but finds those 64 MiB of warm chunks past the
# new budget and graces *them*; a third unmaps them. So the uncapped grace
# leaks in exactly one idle window — after the major following the drop — and
# a gate that waited for a third passed both arms (20.4 MB mapped uncapped,
# measured while writing this).
#
# Counted from the drop as observed, not from the end of `burst`: a stale
# conservative root can keep the list alive through the first major after it,
# which moves the window one major later. "Two majors after `burst` returns"
# then measured before the window and the uncapped arm passed — once on CI
# (run 36002274356, threshold still 64 MiB, nothing unmapped yet) and 1 in 30
# locally. The live set is read after every major until it is below a
# `DROPPED_BELOW`: gone, not merely shrinking — a partly reclaimed burst leaves
# its size as the threshold the next sweep runs under.
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
DROPPED_BELOW = 16_i64 * 1024 * 1024
burst(burst_mb)

majors = stats["major_collections"].as_i64
sink = nil.as(BurstNode?)
# Allocate until a major reports the burst gone...
dropped_at = -1_i64
seen = majors
while dropped_at < 0
  2000.times { sink = BurstNode.new }
  s = stats
  now = s["major_collections"].as_i64
  next if now == seen
  seen = now
  if s["size_class_live_bytes"].as_i64 < DROPPED_BELOW
    dropped_at = now
  elsif now - majors > 20
    puts "FAIL: the burst was still live #{now - majors} majors after it was dropped — this run tests nothing"
    exit 1
  end
end
# ...then exactly one more. Its sweep runs under the budgets in force *now* —
# `adapt_after_sweep` resets them after it — so they are read here, not after.
# Read after, they are the adapted 8 MiB, while the sweep they are compared
# with ran at whatever the drop major left: a burst only partly reclaimed
# there (live still 20-45 MB) sets a threshold that size for the next sweep,
# and the capped arm then legitimately kept 43-92 MB against a bound of 16 —
# 4 failures in 100 of a gate whose arm was within its design.
s = stats
warm = s["empty_chunk_warm_retain"].as_i64
threshold = s["gc_threshold"].as_i64
while stats["major_collections"].as_i64 < dropped_at + 1
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
bound = warm + threshold

puts "burst #{burst_mb} MB, dropped as of major #{dropped_at - majors} after it, then one more, then idle"
puts "  small_mapped_bytes #{mapped}"
puts "  empty chunks kept  #{kept_empty} = fully free #{fully_free} - unmapped #{released} - dormant #{dormant}"
puts "  bound              #{bound} = warm #{warm} + threshold #{threshold}, as in force for that sweep"
if kept_empty <= bound
  puts "PASS: the empty chunks left mapped fit what one cycle can reuse"
else
  puts "FAIL: #{kept_empty - bound} bytes of emptied chunks stay mapped with no major coming to release them"
  exit 1
end
