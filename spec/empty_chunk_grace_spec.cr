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
      # State on failure: this assertion is one of five that fail together on
      # aarch64 CI and nowhere else, and the grace counter alone cannot say
      # whether the chunks were kept, released early or never emptied.
      if heap.empty_chunk_grace_kept <= kept
        fail "no empty chunk was kept for the grace cycle — kept_before=#{kept} " \
             "kept_now=#{heap.empty_chunk_grace_kept} heap_size=#{heap.heap_size} " \
             "mapped=#{mapped} chunk_bytes=#{heap.small_chunk_bytes} " \
             "page=#{LibC.sysconf(LibC::SC_PAGESIZE)} compiled_page=#{Gcry::Roots::PAGE_SIZE}"
      end
      heap.collect(scan_stack: false)
      if heap.heap_size >= mapped
        fail "the second collection did not release the grace-kept chunks — " \
             "heap_size=#{heap.heap_size} mapped=#{mapped} " \
             "grace_kept=#{heap.empty_chunk_grace_kept} " \
             "released_bytes=#{heap.released_chunk_bytes} " \
             "flush_considered=#{heap.release_flush_chunks} " \
             "refused_occupied=#{heap.release_refused_occupied}"
      end
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
      if heap.heap_size >= before
        fail "the heap did not shrink after the live-root collection — " \
             "heap_size=#{heap.heap_size} before=#{before} " \
             "flush_considered=#{heap.release_flush_chunks} " \
             "refused_occupied=#{heap.release_refused_occupied} " \
             "released_bytes=#{heap.released_chunk_bytes}"
      end
      heap.size_class_chunk_count.should be >= 1
    ensure
      heap.destroy
    end
  end
end
