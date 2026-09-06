require "./spec_helper"

# The warm-chunk budget keeps emptied chunks mapped for the *next* allocation-
# driven cycle. An explicit `collect(release_warm: true)` - what `GC.collect`
# and the emergency retry before OutOfMemoryError pass - is a request for
# memory back, so it sweeps with the budget and the unmap grace off.
describe "explicit collect releases warm chunks" do
  it "keeps emptied chunks on an automatic collect and releases them on request" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.release_empty_chunks = true
      heap.empty_chunk_retain = 0_u64
      heap.empty_chunk_warm_retain = 64_u64 * 1024 * 1024
      # 4 KiB blocks: a few chunks' worth, all garbage at the collection.
      200.times { heap.malloc(4096) }
      full = heap.heap_size
      (full // heap.small_chunk_bytes).should be >= 3

      heap.collect(scan_stack: false)
      heap.heap_size.should eq(full)

      heap.collect(scan_stack: false, release_warm: true)
      heap.heap_size.should be < full
      heap.warm_released_collects.should eq(1_u64)
    ensure
      heap.destroy
    end
  end
end
