require "./spec_helper"

# A large object's scan must stop at the size it was allocated with, not at
# the end of its mapping. The large-chunk cache hands a freed mapping to the
# next request that fits, and `malloc` zeroes only the bytes asked for, so
# the tail past the new object's size still holds the previous occupant's
# words. Scanning that tail retains whatever the old object pointed at.
describe "large object scan bounds" do
  it "reports the allocated size, clamped to the mapping" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.nursery_enabled = false
      big = heap.malloc(200_000)
      found = 0
      heap.each_chunk do |chunk|
        next unless Gcry::ChunkHeader.large?(chunk) && Gcry::ChunkHeader.large_user(chunk) == big
        found += 1
        header = Gcry::ChunkHeader.large_header(chunk)
        size = heap.block_payload(chunk, header).to_u64
        size.should be >= 200_000_u64
        size.should be < 200_000_u64 + 64
        size.should eq(heap.diag_payload(header))
      end
      found.should eq(1)
    ensure
      heap.destroy
    end
  end

  it "does not scan a cached mapping's stale tail" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.nursery_enabled = false
      first = heap.malloc(300_000)
      victim = heap.malloc(48)
      # Word-aligned, or the scan can never read the pointer as one word.
      (first.as(UInt8*) + 299_504).as(Void**).value = victim
      heap.free(first)
      # Same page-rounded mapping size, so the cache returns the same mapping.
      second = heap.malloc(299_000)
      # The cache must have handed the same mapping back, or this proves nothing.
      second.should eq(first)
      (second.as(UInt8*) + 299_504).as(Void**).value.should eq(victim)
      heap.add_root(second)
      heap.collect(scan_stack: false)
      heap.live?(second).should be_true
      heap.live?(victim).should be_false
    ensure
      heap.destroy
    end
  end

  it "does not scan a large atomic object" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.nursery_enabled = false
      buffer = heap.malloc_atomic(200_000)
      victim = heap.malloc(48)
      (buffer.as(UInt8*) + 1_024).as(Void**).value = victim
      heap.add_root(buffer)
      heap.collect(scan_stack: false)
      heap.live?(buffer).should be_true
      heap.live?(victim).should be_false
    ensure
      heap.destroy
    end
  end

  it "realloc keeps a large object atomic" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.nursery_enabled = false
      buffer = heap.malloc_atomic(200_000)
      grown = heap.realloc(buffer, 400_000)
      victim = heap.malloc(48)
      (grown.as(UInt8*) + 1_024).as(Void**).value = victim
      heap.add_root(grown)
      heap.collect(scan_stack: false)
      heap.live?(grown).should be_true
      heap.live?(victim).should be_false
    ensure
      heap.destroy
    end
  end
end
