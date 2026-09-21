# A chunk released with a live block in it — the window, constructed.
#
# The sweep unlinks an empty chunk from `@chunks` and queues it for the
# post-STW flush, but its `@chunk_index` entry survives until that flush calls
# `index_remove`. The allocator validates a pooled chunk address against
# exactly that index, and `bitmap_pool_candidate?` accepts a chunk whose blocks
# are all free — which a queued chunk's are, by construction. So between the
# sweep and the flush a mutator can take a block out of a chunk that is about
# to be unmapped.
#
# First read on CI 2026-09-14 (run `34787711949`):
#
#   gcry: SIGSEGV at 0x7f6e5cea0014 — in a chunk gcry RELEASED — base
#   0x7f6e5cea0000, 131072 bytes, empty size-class chunk release, at collection
#   206; the write is 20 bytes into it. Collections since: 0. Blocks still
#   allocated at release: 1
#
# Until 2026-09-21 this harness tried to *reach* that window with thread churn
# and a held flush, and on a developer host it did not — 0 of 48 — so both
# arms ran under `-` and the gate could not fail. The window has a shape that
# a single thread can walk on purpose, and this is it:
#
#   1. Fill a size class with garbage across several chunks; collect once.
#      Every chunk is empty and on its one cycle of grace (`IDLE`), and the
#      class's pool version is bumped by the reclaim.
#   2. Collect again, with a mutator on the collector's own thread at the two
#      points `Heap#post_stw_hook` offers:
#      - `:after_start_world` — the world runs, `@chunks` is intact, the
#        after-world sweep has not run. One allocation retires the settled
#        cursor and rebuilds the pool from that list: every idle chunk goes
#        in, the lowest is taken, the rest wait behind `next_index`.
#      - the sweep then finds the idle chunks still empty, frees nothing in
#        them (so the version stands), and queues them: off `@chunks`, still
#        in the index.
#      - `:before_flush` — exhaust the taken chunk. The refill pops the next
#        pooled address, the index still answers for it, `bitmap_pool_candidate?`
#        accepts it, and a block is handed out of a chunk queued for unmapping.
#   3. The flush runs. Shipped: it finds the chunk occupied, counts the
#      refusal, keeps it mapped and relinks it. Pre-fix
#      (`release_occupied_anyway`, `GCRY_RELEASE_OCCUPIED=1` on a process
#      heap): it unmaps the chunk under the block.
#
#   crystal build bench/occupied_release.cr -o bin/occupied_release
#   bin/occupied_release            # refused once; the block is in the heap and live
#   bin/occupied_release --broken   # released anyway; the block's chunk is gone
#
# Both arms require the window to have been hit — `release_refused_occupied`
# must go up by exactly one, and the block must have come out of a chunk that
# was already mapped rather than a fresh `map_chunk` — so a construction that
# stops reaching the window fails instead of passing on nothing. Dropping the
# refusal reddens the shipped arm; dropping the knob reddens `--broken`.
#
# A library heap, not the process GC: the harness's own strings and arrays go
# to Boehm, so nothing but this script allocates on the heap under test and
# the construction is exact.

require "../src/gcry"

SIZE = 4096_u64

broken = ARGV.includes?("--broken")

heap = Gcry::Heap.new
heap.bitmap_alloc = true
heap.nursery_enabled = false
heap.gc_threshold = UInt64::MAX
heap.release_empty_chunks = true
# The release is gated on the process having one mutator thread; these two
# only widen the multi-mutator branch and are what `spec/empty_chunk_grace_spec`
# uses for the same reason.
heap.parallel_empty_chunk_dormant = true
heap.parallel_empty_chunk_munmap = true
heap.empty_chunk_warm_retain = 0_u64
heap.empty_chunk_retain = 0_u64
# The window is between the after-world sweep and the flush; the in-STW sweep
# unlinks inside the stop and a pool built afterwards never sees the chunk.
heap.lazy_sweep = true
heap.release_occupied_anyway = broken

def chunk_of(heap : Gcry::Heap, p : Void*) : UInt64
  found = heap.find_block_with_chunk(p)
  raise "#{p} is not in the heap under test" unless found
  found[1].address
end

puts "=== a chunk released with a live block in it ==="
puts "mode: #{broken ? "broken (release an occupied chunk anyway — the pre-fix behaviour)" : "shipped (refuse)"}"

# 1. Several chunks of garbage; one major puts every chunk on grace.
blocks_per_chunk = heap.small_chunk_bytes // SIZE
(6 * blocks_per_chunk).times { heap.malloc(SIZE) }
heap.collect(scan_stack: false)
puts "chunks on grace after the first major: #{heap.empty_chunk_grace_kept}"

failures = [] of String
roots = [] of Void*
first_chunk = 0_u64
taken = Pointer(Void).null
taken_chunk = 0_u64
mapped_before = heap.chunks_mapped
refused_before = heap.release_refused_occupied
considered_before = heap.release_flush_chunks

heap.post_stw_hook = ->(stage : Symbol) do
  case stage
  when :after_start_world
    p = heap.malloc(SIZE)
    roots << p
    first_chunk = chunk_of(heap, p)
  when :before_flush
    n = 0
    loop do
      p = heap.malloc(SIZE)
      roots << p
      n += 1
      c = chunk_of(heap, p)
      if c != first_chunk
        taken = p
        taken_chunk = c
        break
      end
      if n > blocks_per_chunk + 1
        failures << "the cursor never left chunk 0x#{first_chunk.to_s(16)} in #{n} allocations"
        break
      end
    end
  end
end

# 2. The second major: the sweep queues the idle chunks, the hook takes one.
heap.collect(scan_stack: false, roots: roots)
heap.post_stw_hook = nil

refused = heap.release_refused_occupied - refused_before
considered = heap.release_flush_chunks - considered_before
fresh_maps = heap.chunks_mapped - mapped_before

puts "chunks the flush considered:      #{considered}"
puts "chunks the flush found occupied: #{refused}"
puts "chunks mapped during the window: #{fresh_maps}"
puts "block taken in the window:       #{taken} in chunk 0x#{taken_chunk.to_s(16)}"

failures << "no block was taken in the window" if taken.null?
failures << "the block came from a fresh map_chunk, not through the index (#{fresh_maps} mapped)" if fresh_maps != 0
failures << "the flush queued nothing, so there was no window (#{considered} considered)" if considered == 0
failures << "the window was not hit: #{refused} refusal(s), expected 1" if refused != 1

if failures.empty?
  in_heap = heap.is_heap_ptr(taken)
  if broken
    # The chunk is unmapped under the block; the cursor slot still names it,
    # so nothing below may allocate on this heap or destroy it.
    if in_heap
      failures << "release_occupied_anyway did not release the occupied chunk — the block is still in the heap"
    else
      puts "ok — the pre-fix behaviour reached the window and unmapped chunk 0x#{taken_chunk.to_s(16)} with"
      puts "a live block in it. That is what the shipped arm refuses, and why the refusal is not theoretical."
    end
  else
    if in_heap
      # Mapped: a write is safe, and it is the write the CI crash faulted on.
      taken.as(UInt8*).value = 0xA5_u8
      roots << taken
      heap.collect(scan_stack: false, roots: roots)
      failures << "the block was refused-for and kept mapped, then swept" unless heap.live?(taken)
    else
      failures << "the refusal was counted and the chunk was released anyway"
    end
    if failures.empty?
      puts "ok — the chunk was queued as empty, had a block in it when the flush ran, and was"
      puts "kept mapped and put back on the live list; the block survives a rooted collection."
    end
  end
end

unless failures.empty?
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
heap.destroy unless broken
exit 0
