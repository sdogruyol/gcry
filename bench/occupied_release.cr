# A chunk released with a live block in it.
#
# The sweep unlinks an empty chunk from `@chunks` inside the stop and queues it
# for the post-STW flush, but its `@chunk_index` entry survives until that flush
# calls `index_remove`. The allocator validates a pooled chunk address against
# exactly that index, and `bitmap_pool_candidate?` accepts a chunk whose blocks
# are all free — which a queued chunk's are, by construction. So between the
# stop ending and the flush running, a mutator can take a block out of a chunk
# that is about to be unmapped.
#
# First read on CI 2026-09-14 (run `34787711949`), in the first sighting the
# crash report could interpret after the release ledger was hoisted above the
# heap-span test:
#
#   gcry: SIGSEGV at 0x7f6e5cea0014 — in a chunk gcry RELEASED — base
#   0x7f6e5cea0000, 131072 bytes, empty size-class chunk release, at collection
#   206; the write is 20 bytes into it. Collections since: 0. Blocks still
#   allocated at release: 1
#
# "Blocks still allocated at release" is a popcount of the occupancy bitmap at
# the moment of release, so that is not a stale pointer into freed memory: it is
# a live block inside memory the collector gave back.
#
#   bin/occupied_release            # the flush refuses an occupied chunk
#   bin/occupied_release --control  # GCRY_RELEASE_OCCUPIED=1: it releases anyway
#
# `GCRY_EMPTY_FLUSH_DELAY_MS` holds the flush with the world running so the
# window is reached on purpose; on CI it is reached about once in twenty-four
# children, which is a sighting rather than a test.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "occupied_release requires -Dgc_none (gcry as process GC)" %}
{% end %}

ROUNDS  = (ENV["OCCUPIED_ROUNDS"]?.try(&.to_i?) || 60)
THREADS = (ENV["OCCUPIED_THREADS"]?.try(&.to_i?) || 8)
DELAY   = (ENV["OCCUPIED_DELAY_MS"]?.try(&.to_u64?) || 20_u64)
SIZE    = 128
# Zero is the churn reproducer's shape exactly: threads that start and stop,
# allocating nothing of their own. It matters — with each thread allocating a
# few dozen blocks the class never empties and nothing is ever queued for
# release, measured as 0 chunks considered by the flush in 60 collections.
PER_THREAD = (ENV["OCCUPIED_PER_THREAD"]?.try(&.to_i?) || 0)

heap = Gcry.default_heap.not_nil!
control = ARGV.includes?("--control")
heap.empty_flush_delay_ms = DELAY
heap.release_occupied_anyway = true if control

puts "=== a chunk released with a live block in it ==="
puts "mode: #{control ? "control (release an occupied chunk anyway — the pre-fix behaviour)" : "shipped (refuse)"}"
puts "#{ROUNDS} collections, #{THREADS} short-lived allocating threads per batch, flush held #{DELAY} ms"
puts ""

# The shape has to be thread *churn*, not steady allocation, and the reason is
# the same mechanism the 2026-09-13 latch fix was about: with several mutators
# alive the sweep does not munmap excess empties at all (they go dormant and
# stay linked), so nothing is ever queued and there is no window — measured, 0
# chunks considered by the flush in 40 collections of steady allocation. A
# thread born *while the world is stopped* is not in the count the sweep
# latched, so the sweep takes the single-mutator path and queues empties — and
# that thread is running, and allocating, by the time the flush walks the queue.
stop = Atomic(Int32).new(0)
spawner = Thread.new do
  while stop.get == 0
    born = [] of Thread
    THREADS.times do
      born << Thread.new do
        keep = [] of Array(UInt8)
        48.times { keep << Array(UInt8).new(SIZE, 1_u8) }
        keep.size
      end
    end
    born.each(&.join)
  end
end

refused0 = heap.release_refused_occupied
flushed0 = heap.release_flush_chunks
ROUNDS.times { GC.collect }
refused = heap.release_refused_occupied - refused0
flushed = heap.release_flush_chunks - flushed0
stop.set(1)
spawner.join

puts "chunks the flush considered:      #{flushed}"
puts "chunks the flush found occupied: #{refused}"
puts ""

if refused == 0
  puts(flushed == 0 ? "INCONCLUSIVE nothing was queued for release at all, so there was no window to reach:" : "INCONCLUSIVE the window was never reached: no chunk queued as empty had a block in")
  puts "it by the time the flush ran, in #{ROUNDS} collections with the flush held #{DELAY} ms. The"
  puts "arms measure nothing, and the shipped arm's silence is not evidence of anything."
  exit 1
end

if control
  puts "ok — the pre-fix behaviour reaches the window #{refused} time(s) and releases anyway, which is"
  puts "a live block inside an unmapped (or guarded) range. That is what the shipped arm"
  puts "refuses, and it is why the refusal is not theoretical."
  exit 0
end
puts "ok — #{refused} chunk(s) were queued as empty and had blocks in them when the flush ran;"
puts "each was kept mapped and put back on the live list instead of being released."
exit 0
