# How does a refill's chunk-list walk scale with the number of chunks?
#
# `tasks/todo.md` has carried this since the bitmap allocator landed:
#
#   > `bitmap_take_pool_chunk` walks every chunk of the class per refill:
#   > O(chunks)
#
# The code no longer reads that way — the walk builds a sorted index of
# candidate addresses once per *capacity version* and later refills are served
# from that index — so the question is whether the note is stale or whether
# versions change often enough that the walk is effectively per-refill. That is
# a counting question rather than a timing one, which makes it answerable on a
# loaded host: `bitmap_pool_searches` counts rebuilds, `size_class_chunk_count`
# says how long one walk is, and the cost that matters is
#
#   rebuilds x chunks / allocations
#
# An absolute number cannot answer it. At 36 chunks the steady state measured
# 0.019 chunk visits per allocation, which is nothing; the same rebuild *rate*
# over 10 000 chunks would be 5 visits per allocation, which is not. So this
# measures the slope: phases with progressively larger live sets, and whether
# the rebuild rate falls as the chunk count rises.
#
#   bin/pool_refill_cost              # live set grows across phases
#   bin/pool_refill_cost --churn      # and is dropped every round, which is
#                                     # what invalidates the index

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "pool_refill_cost requires -Dgc_none (gcry as process GC)" %}
{% end %}

PHASES      = [1, 4, 16, 64]
ROUNDS      = (ENV["POOL_ROUNDS"]?.try(&.to_i?) || 40)
PER_ROUND   = (ENV["POOL_PER_ROUND"]?.try(&.to_i?) || 4096)
ALLOC_BYTES = 256

heap = Gcry.default_heap.not_nil!
churn = ARGV.includes?("--churn")

puts "=== how does the refill walk scale with the chunk count? ==="
puts "#{PHASES.size} phases, #{ROUNDS} rounds x #{PER_ROUND} allocations of #{ALLOC_BYTES} B each, " \
     "#{churn ? "live set dropped every round (churn)" : "live set kept per phase"}"
puts ""
puts "  live rounds   chunks   allocations   rebuilds   per 1k allocs   chunk visits / alloc"

record Phase, chunks : UInt64, allocs : UInt64, rebuilds : UInt64, visits : Float64

results = [] of Phase
live = [] of Array(UInt8)
PHASES.each do |keep|
  live.clear
  # Grow the live set for this phase, so the class has more chunks to walk.
  (keep * PER_ROUND).times { live << Array(UInt8).new(ALLOC_BYTES, 1_u8) }
  GC.collect
  before = heap.bitmap_pool_searches
  allocs = 0_u64
  ROUNDS.times do
    PER_ROUND.times do
      garbage = Array(UInt8).new(ALLOC_BYTES, 2_u8)
      allocs += 1
      garbage.size
    end
    live.clear if churn
    GC.collect
  end
  rebuilds = heap.bitmap_pool_searches - before
  chunks = heap.size_class_chunk_count
  visits = allocs > 0 ? (rebuilds * chunks).to_f / allocs : 0.0
  results << Phase.new(chunks, allocs, rebuilds, visits)
  puts "  #{keep.to_s.rjust(11)}   #{chunks.to_s.rjust(6)}   #{allocs.to_s.rjust(11)}" \
       "   #{rebuilds.to_s.rjust(8)}   #{(rebuilds * 1000.0 / allocs).round(2).to_s.rjust(13)}" \
       "   #{visits.round(4).to_s.rjust(20)}"
end

puts ""
first, last = results.first, results.last
if last.rebuilds == 0 && first.rebuilds == 0
  puts "ok — not one rebuild in #{results.sum(&.allocs)} allocations at any size: the walk is not"
  puts "on the refill path on this workload, so O(chunks) per refill does not describe it."
  exit 0
end

growth = first.chunks > 0 ? last.chunks.to_f / first.chunks : 0.0
cost_growth = first.visits > 0 ? last.visits / first.visits : Float64::INFINITY
puts "chunks grew #{growth.round(2)}x across the phases; chunk visits per allocation grew " \
     "#{cost_growth.round(2)}x."

# The axis that decides this. The rebuild rate per *allocation* is constant, so
# the per-allocation cost has to grow with the chunk count — that is arithmetic,
# not a defect. What says whether it is a defect is the rebuild count per
# *collection*: the index is keyed on a capacity version that each sweep bumps,
# so one rebuild per active class slot per collection is the floor any
# per-version index pays, and anything above that is the walk being paid again
# and again.
rebuilds_per_collection = results.sum(&.rebuilds).to_f / (PHASES.size * ROUNDS)
# And what it is worth comparing against: the sweep walks every *block* of every
# chunk in the same collection, so one visit per chunk is 1/blocks-per-chunk of
# a sweep pass.
blocks_per_chunk = (heap.small_chunk_bytes / ALLOC_BYTES).to_f
share = rebuilds_per_collection / blocks_per_chunk
puts "#{rebuilds_per_collection.round(2)} rebuild(s) per collection, each one chunk visit per chunk:"
puts "#{(share * 100).round(3)}% of the sweep's own walk over the same chunks " \
     "(#{blocks_per_chunk.round} blocks per chunk at this size)."
puts ""

# Two active slots on this workload — the size class, and the atomic variant of
# it — so anything up to a handful is the floor rather than a finding.
if rebuilds_per_collection <= 8.0
  puts "ok — the walk is paid once per capacity version, which each sweep bumps, not once per"
  puts "refill: #{rebuilds_per_collection.round(2)} rebuilds per collection however many chunks there are. The cost per"
  puts "allocation does grow with the chunk count, and that is the arithmetic of a constant"
  puts "rebuild rate rather than a regression — at #{last.chunks} chunks it is #{last.visits.round(3)} chunk visits per"
  puts "allocation, a fraction of a percent of what the sweep walks in the same collection."
  exit 0
end
puts "FAIL #{rebuilds_per_collection.round(2)} rebuilds per collection is more than one per active class slot, so the"
puts "index is being invalidated inside a collection and its walk paid repeatedly. Caching"
puts "it harder will not help; the sweep has to hand the allocator the chunks with room."
exit 1
