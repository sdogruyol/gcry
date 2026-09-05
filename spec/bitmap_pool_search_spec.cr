require "./spec_helper"

describe "bitmap pool capacity search" do
  it "does not repeat an empty search while growing an occupied class" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = true
      200.times { heap.malloc(8192) }
      heap.bitmap_pool_searches.should eq(1)
      heap.bitmap_pool_search_skips.should be > 10
      # Atomic capacity is a different pool, even at the same size.
      200.times { heap.malloc_atomic(8192) }
      heap.bitmap_pool_searches.should eq(2)
    ensure
      heap.destroy
    end
  end

  it "finds an explicitly freed block after a cached empty search" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = false
      first = heap.malloc(8192)
      199.times { heap.malloc(8192) }
      heap.free(first)
      found = false
      # At most one current chunk's tail remains ahead of the freed block.
      32.times { found = true if heap.malloc(8192) == first }
      found.should be_true
    ensure
      heap.destroy
    end
  end

  it "reuses swept capacity and retired partially occupied cursors" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = false
      heap.release_empty_chunks = false
      keep = heap.malloc(8192)
      199.times { heap.malloc(8192) }
      size = heap.heap_size
      heap.collect(scan_stack: false, roots: [keep])
      199.times { heap.malloc(8192) }
      heap.heap_size.should eq(size)
      heap.live?(keep).should be_true
    ensure
      heap.destroy
    end
  end

  it "rediscovers capacity when blacklisting is disabled" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = true
      first = heap.malloc(8192)
      199.times { heap.malloc(8192) }
      heap.free(first)
      heap.blacklist_address(first.address)
      32.times { heap.malloc(8192).should_not eq(first) }
      heap.blacklist_enabled = false
      found = false
      32.times { found = true if heap.malloc(8192) == first }
      found.should be_true
    ensure
      heap.destroy
    end
  end
end
