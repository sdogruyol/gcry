require "./spec_helper"

# Each thread allocates through its own cursor set: two threads in the same
# size class draw from different chunks, a chunk under a cursor is never
# taken by another, and a stop-the-world retires every idle set so its
# chunks return to the pool.
describe "per-thread cursor sets" do
  it "gives two threads different chunks of the same class" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      a = heap.malloc(48)
      b = Pointer(Void).null
      t = Thread.new { b = heap.malloc(48) }
      t.join
      heap.cursor_set_count.should eq(2)
      ca = heap.chunk_address_of(a)
      cb = heap.chunk_address_of(b)
      ca.should_not eq(0_u64)
      cb.should_not eq(0_u64)
      ca.should_not eq(cb)
      heap.cursor_held_chunks.should eq(2)
      # Both cursors are idle at this collection, so it retires them.
      heap.collect(scan_stack: false, roots: [a, b])
      heap.cursor_held_chunks.should eq(0)
      heap.live?(a).should be_true
      heap.live?(b).should be_true
    ensure
      heap.destroy
    end
  end

  it "credits the hit path's bytes to the heap at a collection" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      before = heap.total_bytes
      64.times { heap.malloc(48) }
      heap.collect(scan_stack: false)
      (heap.total_bytes - before).should be >= 64_u64 * 48
    ensure
      heap.destroy
    end
  end

  it "fits every medium byte size exactly like the general allocator" do
    (2049_u64..32768_u64).each do |size|
      payload, index = Gcry::SizeClasses.fit_medium(size)
      expected, expected_index = Gcry::SizeClasses.fit(size)
      payload.to_u64.should eq(expected)
      index.should eq(expected_index)
    end
  end

  it "uses cursor hits for medium classes and clears reused pointerful blocks" do
    [2049, 2560, 2561, 4096, 4097, 8192, 8193, 16384, 16385, 32768].each do |size|
      heap = Gcry::Heap.new
      begin
        heap.bitmap_alloc = true
        heap.nursery_enabled = false
        heap.gc_threshold = UInt64::MAX
        heap.release_empty_chunks = false
        heap.malloc(size)
        second = heap.malloc(size)
        size.times { |i| second.as(UInt8*)[i] = 0xa5_u8 }
        heap.collect(scan_stack: false)
        heap.malloc(size)
        before = heap.fast_path_objects
        reused = heap.malloc(size)
        reused.should eq(second)
        heap.fast_path_objects.should eq(before + 1)
        size.times { |i| reused.as(UInt8*)[i].should eq(0_u8) }
        heap.malloc_atomic(size)
        before = heap.fast_path_objects
        atomic = heap.malloc_atomic(size)
        heap.fast_path_objects.should eq(before + 1)
        heap.collect(scan_stack: false, roots: [reused, atomic])
        heap.live?(reused).should be_true
        heap.live?(atomic).should be_true
        before = heap.fast_path_objects
        large = heap.malloc(32769)
        heap.fast_path_objects.should eq(before)
        heap.collect(scan_stack: false, roots: [large])
        heap.live?(large).should be_true
      ensure
        heap.destroy
      end
    end
  end
end
