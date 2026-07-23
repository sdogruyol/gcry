require "./spec_helper"

describe Gcry::Heap do
  it "rounds sizes to size classes" do
    Gcry::Heap.round_size(0).should eq(16)
    Gcry::Heap.round_size(1).should eq(16)
    Gcry::Heap.round_size(16).should eq(16)
    Gcry::Heap.round_size(17).should eq(32)
    Gcry::Heap.round_size(8192).should eq(8192)
    Gcry::Heap.round_size(8193).should eq(10240)
    Gcry::Heap.round_size(16384).should eq(16384)
    Gcry::Heap.round_size(16385).should eq(20480) # medium size class (≤32 KiB ceiling)
    Gcry::Heap.round_size(32768).should eq(32768)
    Gcry::Heap.round_size(32769).should eq(32776) # aligned up, large path
  end

  it "malloc returns zeroed memory" do
    heap = Gcry::Heap.new
    begin
      ptr = heap.malloc(32)
      bytes = ptr.as(UInt8*)
      32.times { |i| bytes[i].should eq(0) }
      heap.is_heap_ptr(ptr).should be_true
      heap.live_objects.should eq(1)
    ensure
      heap.destroy
    end
  end

  it "malloc re-zeros freelist reuse after free" do
    heap = Gcry::Heap.new
    begin
      ptr = heap.malloc(64)
      64.times { |i| ptr.as(UInt8*)[i] = 0xCD_u8 }
      heap.free(ptr)
      again = heap.malloc(64)
      again.should eq(ptr)
      64.times { |i| again.as(UInt8*)[i].should eq(0) }
    ensure
      heap.destroy
    end
  end

  it "malloc re-zeros large objects taken from the cache" do
    heap = Gcry::Heap.new
    begin
      ptr = heap.malloc(100_000)
      ptr.as(UInt8*)[0] = 0xEF_u8
      ptr.as(UInt8*)[99_999] = 0xFE_u8
      heap.free(ptr)
      again = heap.malloc(100_000)
      again.as(UInt8*)[0].should eq(0)
      again.as(UInt8*)[99_999].should eq(0)
    ensure
      heap.destroy
    end
  end

  it "malloc_atomic does not clear memory" do
    heap = Gcry::Heap.new
    begin
      ptr = heap.malloc_atomic(64)
      bytes = ptr.as(UInt8*)
      # Write then free then realloc from freelist — may see old data.
      64.times { |i| bytes[i] = 0xAB_u8 }
      heap.free(ptr)

      again = heap.malloc_atomic(64)
      # Same size class freelist reuse; contents need not be zero.
      again.should eq(ptr)
      again.as(UInt8*)[0].should eq(0xAB_u8)
    ensure
      heap.destroy
    end
  end

  it "free returns small blocks to the freelist" do
    heap = Gcry::Heap.new
    begin
      a = heap.malloc(16)
      b = heap.malloc(16)
      heap.free(a)
      heap.free(b)
      heap.live_objects.should eq(0)

      c = heap.malloc(16)
      # LIFO freelist
      c.should eq(b)
    ensure
      heap.destroy
    end
  end

  it "detects double free" do
    heap = Gcry::Heap.new
    begin
      ptr = heap.malloc(16)
      heap.free(ptr)
      expect_raises(ArgumentError, /double free/) { heap.free(ptr) }
    ensure
      heap.destroy
    end
  end

  it "allocates and frees large objects" do
    heap = Gcry::Heap.new
    begin
      ptr = heap.malloc(100_000)
      bytes = ptr.as(UInt8*)
      heap.is_heap_ptr(ptr).should be_true
      bytes[0] = 1_u8
      bytes[99_999] = 2_u8
      before = heap.heap_size
      heap.large_mapped_bytes.should eq(before)
      heap.free(ptr)
      # Cached on large freelist (still a heap mapping until trim).
      heap.is_heap_ptr(ptr).should be_true
      heap.live_objects.should eq(0)
      heap.large_free_bytes.should eq(before)
      heap.trim_large_cache(0)
      heap.is_heap_ptr(ptr).should be_false
      heap.heap_size.should be < before
      heap.large_mapped_bytes.should eq(0)
    ensure
      heap.destroy
    end
  end

  it "does not reuse an oversized large mapping for a smaller need" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      fat = heap.malloc(512_000)
      fat_mapped = heap.large_mapped_bytes
      heap.free(fat)
      heap.large_free_bytes.should eq(fat_mapped)

      # Much smaller large alloc must mmap fresh (exact-fit only).
      slim = heap.malloc(40_000)
      slim.should_not eq(fat)
      # Fat stays on freelist; slim is a new mapping.
      heap.large_free_bytes.should eq(fat_mapped)
      heap.large_mapped_bytes.should be > fat_mapped

      heap.trim_large_cache(0)
      heap.is_heap_ptr(fat).should be_false
      heap.is_heap_ptr(slim).should be_true
      heap.large_free_bytes.should eq(0)
      heap.large_mapped_bytes.should be < fat_mapped
    ensure
      heap.destroy
    end
  end

  it "trims large cache down to large_cache_retain" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.large_cache_retain = 0
      ptrs = [] of Void*
      4.times { ptrs << heap.malloc(100_000) }
      ptrs.each { |p| heap.free(p) }
      # free() already trims to retain; with retain 0 cache should be empty.
      heap.large_free_bytes.should eq(0)
      heap.large_mapped_bytes.should eq(0)
    ensure
      heap.destroy
    end
  end

  it "realloc grows and preserves contents" do
    heap = Gcry::Heap.new
    begin
      ptr = heap.malloc(16)
      bytes = ptr.as(UInt8*)
      16.times { |i| bytes[i] = i.to_u8 }

      grown = heap.realloc(ptr, 128)
      grown_bytes = grown.as(UInt8*)
      16.times { |i| grown_bytes[i].should eq(i.to_u8) }
      # New tail is zeroed for non-atomic realloc growth via malloc.
      grown_bytes[16].should eq(0)
      heap.is_heap_ptr(grown).should be_true
    ensure
      heap.destroy
    end
  end

  it "realloc shrinking keeps the same pointer" do
    heap = Gcry::Heap.new
    begin
      ptr = heap.malloc(128)
      same = heap.realloc(ptr, 32)
      same.should eq(ptr)
    ensure
      heap.destroy
    end
  end

  it "is_heap_ptr is false for foreign pointers" do
    heap = Gcry::Heap.new
    begin
      heap.is_heap_ptr(Pointer(Void).null).should be_false
      stack = 0
      heap.is_heap_ptr(pointerof(stack).as(Void*)).should be_false
      libc = LibC.malloc(16)
      begin
        heap.is_heap_ptr(libc).should be_false
      ensure
        LibC.free(libc)
      end
    ensure
      heap.destroy
    end
  end

  it "survives a random alloc/free fuzz" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.nursery_threshold = UInt64::MAX
      rng = Random.new(42)
      live = [] of Void*
      2000.times do
        if live.empty? || rng.next_bool
          size = rng.rand(1..12_000)
          atomic = rng.next_bool
          ptr = atomic ? heap.malloc_atomic(size) : heap.malloc(size)
          heap.is_heap_ptr(ptr).should be_true
          live << ptr
        else
          idx = rng.rand(live.size)
          ptr = live.delete_at(idx)
          heap.free(ptr)
        end
      end
      live.each { |ptr| heap.free(ptr) }
      heap.live_objects.should eq(0)
    ensure
      heap.destroy
    end
  end
end

describe Gcry do
  it "exposes module-level allocators on the default heap" do
    heap = Gcry::Heap.new
    Gcry.default_heap = heap
    begin
      ptr = Gcry.malloc(24)
      bytes = ptr.as(UInt8*)
      24.times { |i| bytes[i].should eq(0) }
      Gcry.is_heap_ptr(ptr).should be_true
      Gcry.free(ptr)
    ensure
      Gcry.default_heap = Gcry::Heap.new
    end
  end

  it "reports a version" do
    Gcry::VERSION.should_not be_nil
  end
end
