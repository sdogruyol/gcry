require "../../src/gcry"
require "spec"

# A `GC.free` of a large block past the cache slack (`LARGE_FREE_TRIM_SLACK`)
# trims at once, and a trim of one chunk takes it off `@chunks` alone
# (`Heap#unlink_chunk`). The list is singly linked, and until 2026-10-14 that
# meant a walk from the head to the chunk in front of it: as many steps as
# the chunk sat deep, every free. With 40 000 large chunks alive a 4 MiB free
# cost 186 µs, 35.4 at 10 000 and 9.6 at 2 500, medians of three runs
# (`bench/log/linux/2026-10-14-large-free-unlink/`). A large chunk now carries
# a back-link to its predecessor (`ChunkHeader.large_prev`), kept by every
# list store, and the unlink checks it and follows it.
#
# The target sits between two runs of `UNLINK_SIDE` large blocks, allocated
# with collection off: a collection in between rebuilds the list in reverse,
# and one that came right after the target put it at the tail, and the
# collection below at the head — 0 steps on the old walk too. The collection
# below is the rebuild the links have to survive, and the depth is checked
# so the test cannot pass on a shallow target. Before the fix (6dc6e7d, with
# the two counters added) the free walked 283 steps here; after it, none.

private UNLINK_SIDE   = 256
private UNLINK_BLOCK  = 64 * 1024
private UNLINK_TARGET = 4 * 1024 * 1024

# How many chunks `@chunks` lists in front of the one holding *user*.
private def unlink_depth(heap : Gcry::Heap, user : Void*) : Int32
  depth = -1
  i = 0
  heap.each_chunk do |c|
    depth = i if depth < 0 && c.address <= user.address && user.address < c.address + c.value.mapped_bytes
    i += 1
  end
  depth
end

describe "Regression: a large free takes its chunk off the list without a walk" do
  it "unlinks a deep large chunk by its back-link" do
    heap = Gcry.default_heap.not_nil!
    GC.disable
    begin
      front = Array(Void*).new(UNLINK_SIDE) { GC.malloc_atomic(UNLINK_BLOCK) }
      target = GC.malloc_atomic(UNLINK_TARGET)
      back = Array(Void*).new(UNLINK_SIDE) { GC.malloc_atomic(UNLINK_BLOCK) }
    ensure
      GC.enable
    end
    GC.collect
    heap.is_heap_ptr(target).should be_true
    unlink_depth(heap, target).should be >= UNLINK_SIDE
    heap.chunk_back_link_faults.should eq(0)

    # Nothing else in the cache, so the trim has the target alone and takes
    # the single-chunk path. The second trim is for a recycling budget large
    # enough to keep the target cached.
    heap.trim_large_cache(0_u64)
    unlinks = heap.chunk_unlinks
    steps = heap.unlink_walk_steps
    GC.free(target)
    heap.trim_large_cache(0_u64)
    heap.is_heap_ptr(target).should be_false
    heap.chunk_unlinks.should be > unlinks
    (heap.unlink_walk_steps - steps).should be < 16
    heap.chunk_back_link_faults.should eq(0)

    # The neighbours: still allocated, and on the list.
    heap.is_heap_ptr(front.first).should be_true
    heap.is_heap_ptr(back.last).should be_true
    front.each { |p| GC.free(p) }
    back.each { |p| GC.free(p) }
    heap.trim_large_cache(0_u64)
    heap.chunk_back_link_faults.should eq(0)
  end
end
