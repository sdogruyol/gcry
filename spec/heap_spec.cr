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

  # Reuse is representation-specific: the freelist hands a freed block straight
  # back (LIFO); the bitmap pool hands out the lowest free bit, so the freed
  # block comes back within one chunk's worth of allocations. Both are checked
  # in the header build; headerless has only the bitmap path.
  [false, true].each do |bitmap|
    it "malloc re-zeros a reused block after free (bitmap_alloc=#{bitmap})" do
      heap = Gcry::Heap.new
      heap.bitmap_alloc = bitmap
      heap.gc_threshold = UInt64::MAX
      # A freed block in a nursery chunk comes back at the next minor, not to
      # the cursor; reuse before any collection is a mature-chunk property.
      heap.nursery_enabled = false
      begin
        ptr = heap.malloc(64)
        64.times { |i| ptr.as(UInt8*)[i] = 0xCD_u8 }
        heap.free(ptr)
        again = Pointer(Void).null
        4096.times do
          p = heap.malloc(64)
          if p == ptr
            again = p
            break
          end
        end
        again.should eq(ptr)
        64.times { |i| again.as(UInt8*)[i].should eq(0) }
      ensure
        heap.destroy
      end
    end

    it "malloc_atomic does not clear a reused block (bitmap_alloc=#{bitmap})" do
      heap = Gcry::Heap.new
      heap.bitmap_alloc = bitmap
      heap.gc_threshold = UInt64::MAX
      # A freed block in a nursery chunk comes back at the next minor, not to
      # the cursor; reuse before any collection is a mature-chunk property.
      heap.nursery_enabled = false
      begin
        ptr = heap.malloc_atomic(64)
        64.times { |i| ptr.as(UInt8*)[i] = 0xAB_u8 }
        heap.free(ptr)
        again = Pointer(Void).null
        4096.times do
          p = heap.malloc_atomic(64)
          if p == ptr
            again = p
            break
          end
        end
        again.should eq(ptr)
        again.as(UInt8*)[0].should eq(0xAB_u8)
      ensure
        heap.destroy
      end
    end

    it "free makes a small block available for reuse (bitmap_alloc=#{bitmap})" do
      heap = Gcry::Heap.new
      heap.bitmap_alloc = bitmap
      heap.gc_threshold = UInt64::MAX
      # A freed block in a nursery chunk comes back at the next minor, not to
      # the cursor; reuse before any collection is a mature-chunk property.
      heap.nursery_enabled = false
      begin
        a = heap.malloc(16)
        b = heap.malloc(16)
        heap.free(a)
        heap.free(b)
        heap.live_objects.should eq(0)
        seen = [] of Void*
        4096.times do
          c = heap.malloc(16)
          seen << c
          break if seen.includes?(a) && seen.includes?(b)
        end
        seen.includes?(a).should be_true
        seen.includes?(b).should be_true
      ensure
        heap.destroy
      end
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

  it "frees a large object whatever its first bytes hold, and detects its double free" do
    heap = Gcry::Heap.new
    begin
      ptr = heap.malloc(200_000)
      # Under headerless the object starts where a header would; these bytes
      # must never be read as one.
      ptr.as(UInt32*)[0] = 0xFFFF_FFFF_u32
      ptr.as(UInt32*)[1] = 0xFFFF_FFFF_u32
      heap.free(ptr)
      heap.live_objects.should eq(0)
      expect_raises(ArgumentError, /double free/) { heap.free(ptr) }
      heap.live_objects.should eq(0)
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

  # Process-GC style: type_id_gate rejects raw buffers on the stack. Growing via
  # realloc must pin the old block so a collect inside allocate cannot reclaim it
  # (Kemal HTTP::Headers Hash resize → double free).
  it "realloc survives collect under type_id_gate (raw buffer)" do
    heap = Gcry::Heap.new
    begin
      heap.type_id_gate = true
      heap.allow_interior_pointers = false
      heap.gc_threshold = UInt64::MAX
      heap.nursery_enabled = false

      # Poison first word like Hash::Entry.@hash so ambient type_id_gate rejects.
      ptr = heap.malloc(64)
      ptr.as(UInt32*).value = 0xDEADBEEF_u32
      4.upto(63) { |i| ptr.as(UInt8*)[i] = i.to_u8 }

      heap.gc_threshold = 1
      grown = heap.realloc(ptr, 256)
      grown.as(UInt32*).value.should eq(0xDEADBEEF_u32)
      4.upto(63) { |i| grown.as(UInt8*)[i].should eq(i.to_u8) }
      heap.live?(grown).should be_true
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
    saved = Gcry.default_heap
    heap = Gcry::Heap.new
    Gcry.default_heap = heap
    begin
      ptr = Gcry.malloc(24)
      bytes = ptr.as(UInt8*)
      24.times { |i| bytes[i].should eq(0) }
      Gcry.is_heap_ptr(ptr).should be_true
      Gcry.free(ptr)
    ensure
      Gcry.default_heap = saved
    end
  end

  it "reports a version" do
    Gcry::VERSION.should_not be_nil
  end
end
