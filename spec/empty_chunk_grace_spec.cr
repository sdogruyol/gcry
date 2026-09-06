require "./spec_helper"

# A fully free bitmap chunk past the warm budget is kept mapped for one more
# major before it is unmapped; taking it for allocation in between resets
# the grace. `ChunkHeader::Flags::IDLE`, `empty_chunk_grace_kept`.
private def grace_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.bitmap_alloc = true
  heap.nursery_enabled = false
  heap.gc_threshold = UInt64::MAX
  heap.release_empty_chunks = true
  heap.empty_chunk_warm_retain = 0_u64
  heap.empty_chunk_retain = 0_u64
  heap
end

describe "empty chunk grace" do
  it "unmaps a fully free chunk past the budget at the second major, not the first" do
    heap = grace_heap
    begin
      # 4 KiB blocks: a few chunks' worth, all garbage at the collection.
      200.times { heap.malloc(4096) }
      mapped = heap.heap_size
      (mapped // heap.small_chunk_bytes).should be >= 3
      kept = heap.empty_chunk_grace_kept
      heap.collect(scan_stack: false)
      heap.heap_size.should eq(mapped)
      heap.empty_chunk_grace_kept.should be > kept
      heap.collect(scan_stack: false)
      heap.heap_size.should be < mapped
    ensure
      heap.destroy
    end
  end

  it "keeps a chunk a cursor took during its grace cycle" do
    heap = grace_heap
    begin
      200.times { heap.malloc(4096) }
      heap.collect(scan_stack: false)
      # The lowest chunk with capacity is taken again; the block is rooted so
      # that chunk is no longer fully free at the second major.
      keep = heap.malloc(4096)
      before = heap.heap_size
      heap.collect(scan_stack: false, roots: [keep])
      heap.live?(keep).should be_true
      heap.heap_size.should be < before
      heap.size_class_chunk_count.should be >= 1
    ensure
      heap.destroy
    end
  end
end
