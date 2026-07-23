require "./spec_helper"

describe "Gcry::Heap collection" do
  it "keeps explicitly rooted objects alive" do
    heap = Gcry::Heap.new
    begin
      keep = heap.malloc(64)
      garbage = heap.malloc(64)
      heap.add_root(keep)

      before = heap.live_objects
      heap.collect(scan_stack: false)
      heap.collections.should eq(1)
      heap.live?(keep).should be_true
      heap.live?(garbage).should be_false
      heap.live_objects.should eq(before - 1)
      heap.bytes_since_gc.should eq(0)
    ensure
      heap.destroy
    end
  end

  it "traces pointers inside non-atomic objects" do
    heap = Gcry::Heap.new
    begin
      child = heap.malloc(32)
      parent = heap.malloc(16)
      # Store child pointer in parent payload.
      parent.as(Void**).value = child

      heap.add_root(parent)
      heap.collect(scan_stack: false)

      heap.live?(parent).should be_true
      heap.live?(child).should be_true
      heap.live_objects.should eq(2)
    ensure
      heap.destroy
    end
  end

  it "does not trace inside atomic objects" do
    heap = Gcry::Heap.new
    begin
      child = heap.malloc(32)
      parent = heap.malloc_atomic(16)
      parent.as(Void**).value = child

      heap.add_root(parent)
      heap.collect(scan_stack: false)

      heap.live?(parent).should be_true
      heap.live?(child).should be_false
    ensure
      heap.destroy
    end
  end

  it "reclaims large unmarked objects" do
    heap = Gcry::Heap.new
    begin
      keep = heap.malloc(100_000)
      drop = heap.malloc(100_000)
      heap.add_root(keep)
      before = heap.heap_size

      heap.collect(scan_stack: false)

      heap.live?(keep).should be_true
      heap.live?(drop).should be_false
      # Large objects are cached (no munmap in STW); force trim to release RSS.
      heap.trim_large_cache(0)
      heap.heap_size.should be < before
    ensure
      heap.destroy
    end
  end

  it "finds objects via interior pointers" do
    heap = Gcry::Heap.new
    begin
      obj = heap.malloc(64)
      interior = (obj.as(UInt8*) + 24).as(Void*)
      header = heap.find_object(interior)
      header.should_not be_nil
      Gcry::BlockHeader.user_from(header.not_nil!).should eq(obj)

      heap.add_root(interior)
      heap.collect(scan_stack: false)
      heap.live?(obj).should be_true
    ensure
      heap.destroy
    end
  end

  it "accepts extra roots passed to collect" do
    heap = Gcry::Heap.new
    begin
      a = heap.malloc(16)
      b = heap.malloc(16)
      heap.collect(scan_stack: false, roots: [a])
      heap.live?(a).should be_true
      heap.live?(b).should be_false
    ensure
      heap.destroy
    end
  end

  it "auto-collects when the threshold is crossed" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = 1024
      heap.disable
      40.times { heap.malloc(64) } # 40 * 64 = 2560 rounded sizes... each is 64
      heap.bytes_since_gc.should be > 1024
      heap.enable
      # Next allocation triggers maybe_collect
      heap.malloc(16)
      heap.collections.should be > 0
      heap.bytes_since_gc.should be < heap.gc_threshold
    ensure
      heap.destroy
    end
  end

  it "scans the stack when stack_bottom is set" do
    heap = Gcry::Heap.new
    begin
      # Capture a high stack address as bottom, then allocate locals below it.
      bottom = Pointer(Void).null
      local = 0
      bottom = (pointerof(local).as(UInt8*) + 4096).as(Void*)
      heap.set_stackbottom(bottom)

      keep = heap.malloc(32)
      # keep is on this stack frame; collect with stack scan should retain it.
      heap.collect(scan_stack: true)
      heap.live?(keep).should be_true
    ensure
      heap.destroy
    end
  end
end

it "munmaps fully free size-class chunks on major" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.release_empty_chunks = true
    heap.nursery_enabled = false

    keep = heap.malloc(64)
    heap.add_root(keep)
    # Several 256 KiB chunks of garbage (~80 B/block → need >4k objects).
    8_000.times { heap.malloc(64) }

    before = heap.heap_size
    before.should be > Gcry::Heap::SMALL_CHUNK_BYTES
    heap.collect(scan_stack: false)
    heap.live?(keep).should be_true
    heap.unmapped_bytes.should be > 0
    heap.released_chunk_bytes.should eq(heap.unmapped_bytes)
    heap.fully_free_chunk_bytes.should eq(heap.released_chunk_bytes)
    heap.heap_size.should be < before
    # Freelist still works after rebuild from remaining chunks.
    heap.malloc(64).should_not be_nil
  ensure
    heap.destroy
  end
end

it "reports fully_free_chunk_bytes when empty chunks are retained" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.release_empty_chunks = false
    heap.nursery_enabled = false

    keep = heap.malloc(64)
    heap.add_root(keep)
    8_000.times { heap.malloc(64) }

    before = heap.heap_size
    heap.collect(scan_stack: false)
    heap.live?(keep).should be_true
    heap.released_chunk_bytes.should eq(0)
    heap.fully_free_chunk_bytes.should be > 0
    heap.size_class_chunk_count.should be > 0
    # Retained: heap_size does not drop by the fully-free amount.
    heap.heap_size.should eq(before)
    heap.unmapped_bytes.should eq(0)
  ensure
    heap.destroy
  end
end

it "reports size_class_live_bytes and fill histogram after major" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.release_empty_chunks = false
    heap.nursery_enabled = false

    keep = heap.malloc(64)
    heap.add_root(keep)
    8_000.times { heap.malloc(64) }

    heap.collect(scan_stack: false)
    heap.size_class_live_bytes.should be > 0
    fill_sum = heap.chunk_fill_lt25 + heap.chunk_fill_lt50 + heap.chunk_fill_lt75 + heap.chunk_fill_ge75
    fill_sum.should eq(heap.size_class_chunk_count)
    # Empty retained chunks land in lt25.
    heap.chunk_fill_lt25.should be > 0
  ensure
    heap.destroy
  end
end

it "allocates with a custom small_chunk_bytes" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.small_chunk_bytes = 131072_u64 # 128 KiB
    ptr = heap.malloc(64)
    heap.is_heap_ptr(ptr).should be_true
    # One refill maps a 128 KiB chunk.
    heap.heap_size.should eq(131072)
    heap.free(ptr)
  ensure
    heap.destroy
  end
end
