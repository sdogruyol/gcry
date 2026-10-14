require "../../src/gcry"
require "spec"

# `free_bytes` — `GC.stats.free_bytes`, `GC_get_heap_usage_safe`'s
# `pfree_bytes`, `GC_get_prof_stats`, `/gc-stats` — must say how much of the
# heap is free. On the bitmap layout, the default since the headerless build,
# it never did: a size-class chunk's capacity was credited only by
# `refill_size_class`, the header allocator's, and the bitmap pool maps its
# chunks with `map_chunk` alone. So every allocation from a fresh chunk was
# subtracted from capacity that had never been added, the subtraction
# saturated at zero, and the counter came to mean "bytes reclaimed since the
# heap last ran dry". Measured on a quiet process heap after 20 collections:
# 0 against 2 199 744 bytes a walk found free; on a library heap, 0 against
# 1 033 216.
#
# Each phase ends quiescent — every thread joined, the cursor sets credited
# by the reader — and compares the counter with a walk of the chunk list
# (`Invariant.free_bytes_drift`), so no tolerance is needed: fresh chunks
# from eight threads, each on a class of its own and freeing three blocks in
# four ahead of its credit; large blocks allocated and freed into the cache;
# a collection that makes the empty chunks dormant; a round that revives
# them; and the two collections that unmap them (the first gives an empty
# bitmap chunk its one cycle of grace). Before the fix the walk found 1.30 to
# 1.51 MB more free than the counter at every phase up to the unmap, and
# 798 720 bytes (the large cache, with the counter at 0) after it, in 5 of 5
# runs; after it, 0 at every phase in 5 of 5 on each layout.

private FREE_CAPACITY_THREADS =    8
private FREE_CAPACITY_BLOCKS  = 4096

private def free_capacity_drift(heap : Gcry::Heap) : Int64
  Gcry::Invariant.free_bytes_drift(heap) || raise "free_bytes moved under a quiescent walk"
end

private def free_capacity_round(heap : Gcry::Heap, free_every : Int32) : Nil
  threads = Array(Thread).new(FREE_CAPACITY_THREADS) do |t|
    Thread.new do
      size = 16 * (t + 1)
      blocks = Pointer(Void*).malloc(FREE_CAPACITY_BLOCKS)
      FREE_CAPACITY_BLOCKS.times { |i| blocks[i] = heap.malloc(size) }
      FREE_CAPACITY_BLOCKS.times { |i| heap.free(blocks[i]) unless i % free_every == 0 }
    end
  end
  threads.each(&.join)
end

describe "Regression: free_bytes is the heap's free capacity" do
  it "agrees with a walk of the chunks through allocation, frees, release and revival" do
    heap = Gcry::Heap.new
    heap.nursery_enabled = false
    # Eight threads share this heap; see 76 for why this is set.
    heap.heap_counters_atomic = true
    heap.gc_threshold = UInt64::MAX
    heap.release_empty_chunks = true
    heap.parallel_empty_chunk_dormant = true
    heap.parallel_empty_chunk_munmap = true
    heap.empty_chunk_warm_retain = 0_u64
    heap.empty_chunk_retain = 64_u64 * 1024 * 1024
    begin
      drifts = {} of String => Int64

      free_capacity_round(heap, 4)
      drifts["fresh chunks, 3 in 4 freed"] = free_capacity_drift(heap)

      large = Array(Void*).new(4) { heap.malloc(262_144) }
      heap.free(large[0])
      heap.free(large[1])
      drifts["large blocks, 2 of 4 freed"] = free_capacity_drift(heap)

      # Nothing here roots the library heap's blocks, so the collection
      # reclaims them and the empty chunks go dormant within the retain.
      heap.collect
      heap.dormant_chunk_bytes.should be > 0 if heap.bitmap_alloc?
      drifts["collected, empties dormant"] = free_capacity_drift(heap)

      free_capacity_round(heap, 2)
      drifts["dormant chunks revived"] = free_capacity_drift(heap)

      heap.empty_chunk_retain = 0_u64
      2.times { heap.collect }
      # The header allocator does not unmap a dormant chunk; the bitmap one
      # does, after a cycle's grace.
      heap.released_chunk_bytes.should be > 0 if heap.bitmap_alloc?
      drifts["collected, empties unmapped"] = free_capacity_drift(heap)

      drifts.values.all?(&.zero?).should be_true, "walk - free_bytes by phase: #{drifts}"
    ensure
      heap.destroy
    end
  end
end
