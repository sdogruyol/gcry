require "./spec_helper"

module ReallocMoveSpec
  # Out of line, so the referents' addresses do not stay in the spec's frame
  # and the moved buffer is what keeps them alive.
  @[NoInline]
  def self.store_referents(heap : Gcry::Heap, buf : UInt64*, count : Int32) : Nil
    count.times do |i|
      obj = heap.malloc(64).as(UInt64*)
      8.times { |w| obj[w] = 0xC0DE_0000_u64 | (i &* 8 &+ w) }
      buf[i] = obj.address
    end
  end
end

{% unless flag?(:win32) %}
  lib LibC
    fun mincore(addr : Void*, length : SizeT, vec : UInt8*) : Int
  end
{% end %}

module ReservationSpec
  # Is every page of `[addr, addr + len)` mapped (accessible or not)? `mincore`
  # refuses an unmapped page (`ENOMEM`). A page at a time into a byte on the
  # stack: an allocation here could map memory into a hole just released.
  # Nil on Windows, where the room goes with the chunk's release instead.
  def self.mapped?(addr : UInt64, len : UInt64) : Bool?
    {% if flag?(:win32) %}
      nil
    {% else %}
      page = Gcry::Platform.host_page_size
      vec = 0_u8
      at = addr
      while at < addr + len
        return false unless LibC.mincore(Pointer(Void).new(at), LibC::SizeT.new(page), pointerof(vec)) == 0
        at += page
      end
      true
    {% end %}
  end

  # Base of the chunk holding a large block, and the room reserved from it.
  def self.chunk_of(heap : Gcry::Heap, user : Void*) : {UInt64, UInt64}
    base = heap.chunk_address_of(user)
    {base, heap.large_grow_extent(Pointer(Gcry::ChunkHeader).new(base))}
  end
end

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

  it "usable_size covers the request, and realloc within it keeps the block" do
    heap = Gcry::Heap.new
    heap.gc_threshold = UInt64::MAX
    begin
      [1, 16, 17, 255, 8193, 16385, 32769, 100_000].each do |request|
        ptr = heap.malloc(request)
        usable = heap.usable_size(ptr)
        usable.should be >= request.to_u64
        heap.realloc(ptr, usable).should eq(ptr)
      end
    ensure
      heap.destroy
    end
  end

  it "usable_size answers for interior pointers, and 0 outside live blocks" do
    heap = Gcry::Heap.new
    heap.gc_threshold = UInt64::MAX
    begin
      small = heap.malloc(64)
      large = heap.malloc(100_000)
      heap.usable_size(small + 8).should eq(heap.usable_size(small))
      heap.usable_size(large + 99_999).should eq(heap.usable_size(large))

      foreign = LibC.malloc(64)
      heap.usable_size(foreign).should eq(0)
      LibC.free(foreign)
      heap.usable_size(Pointer(Void).null).should eq(0)

      freed = heap.malloc(64)
      heap.free(freed)
      heap.usable_size(freed).should eq(0)
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

  {% if flag?(:linux) %}
    # Recycling hands a cached chunk's pages to a new block at an address the
    # kernel picks: a stale pointer to the dead block must not name the new
    # one (that kept Revcomp's 65 MB strings alive), the new block reads
    # zeroes where the dead one wrote, and a split's remainder and a grown
    # tail are counted where they are. The exception is an exact fit for a
    # chunk the program freed itself, taken where it is as without recycling.
    it "recycles a cached large chunk at a fresh address, zeroed, with the rest still cached" do
      heap = Gcry::Heap.new
      begin
        heap.gc_threshold = UInt64::MAX
        heap.large_recycle = true
        # What a major leaves the recycler; with none, a free unmaps.
        heap.large_recycle_budget = UInt64::MAX
        live = heap.malloc(200_000)
        live.as(UInt8*).fill(200_000, 0xCD_u8)
        live_mapped = heap.large_mapped_bytes
        old = heap.malloc(1_000_000)
        old.as(UInt8*).fill(1_000_000, 0xAB_u8)
        old_mapped = heap.large_mapped_bytes - live_mapped
        heap.free(old)
        heap.large_free_bytes.should eq(old_mapped)
        os_before = Gcry.os_mapped_bytes

        # Smaller: the front of the cached chunk, the rest cached again.
        front = heap.malloc(400_000)
        heap.large_recycles.should eq(1)
        heap.is_heap_ptr(old).should be_false
        heap.find_block(old).should be_nil
        front.should_not eq(old)
        heap.live?(front).should be_true
        front.as(UInt8*).to_slice(400_000).all?(&.zero?).should be_true
        front_mapped = heap.large_mapped_bytes - live_mapped - heap.large_free_bytes
        heap.large_free_bytes.should eq(old_mapped - front_mapped)
        Gcry.os_mapped_bytes.should eq(os_before)

        # Larger than anything cached: the remainder grown, its tail fresh.
        rest = heap.large_free_bytes
        grown = heap.malloc(2_000_000)
        heap.large_recycles.should eq(2)
        heap.large_free_bytes.should eq(0)
        grown.as(UInt8*).to_slice(2_000_000).all?(&.zero?).should be_true
        grown_mapped = heap.large_mapped_bytes - live_mapped - front_mapped
        Gcry.os_mapped_bytes.should eq(os_before + grown_mapped - rest)

        # An exact fit for a chunk the program freed is taken in place, as the
        # exact-size cache takes it: no mapping, no move.
        front.as(UInt8*).fill(400_000, 0xEE_u8)
        heap.free(front)
        again = heap.malloc(400_000)
        heap.large_recycles.should eq(2)
        again.should eq(front)
        heap.large_free_bytes.should eq(0)
        again.as(UInt8*).to_slice(400_000).all?(&.zero?).should be_true

        # Any other exact fit moves: here a split's remainder, which nothing
        # freed explicitly, like the chunks a sweep caches.
        heap.free(grown)
        part = heap.malloc(400_000)
        heap.large_recycles.should eq(3)
        remainder = heap.large_free_bytes
        exact = heap.malloc(remainder - Gcry::ChunkHeader.large_data_offset.to_u64)
        heap.large_recycles.should eq(4)
        heap.large_free_bytes.should eq(0)
        heap.live?(part).should be_true
        heap.live?(exact).should be_true

        live.as(UInt8*).to_slice(200_000).all? { |b| b == 0xCD_u8 }.should be_true
        heap.large_mapped_bytes.should eq(heap.heap_size)
      ensure
        heap.destroy
      end
    end
  {% end %}

  # A trim of several chunks takes them off the list and out of the index in
  # one batch pass (`unlink_detached_large`). The freed chunks are interleaved
  # with live ones on both, so a pass that drops the wrong neighbour, or
  # leaves list and index disagreeing, shows here.
  it "trims several interleaved large chunks and keeps their live neighbours" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.large_cache_retain = 64_u64 << 20
      ptrs = Array(Void*).new(12) { heap.malloc(100_000) }
      ptrs.each_with_index { |p, i| p.as(UInt8*)[99_999] = i.to_u8 }
      freed = ptrs.each_slice(2).map(&.first).to_a
      kept = ptrs.each_slice(2).map(&.last).to_a
      freed.each { |p| heap.free(p) }
      heap.trim_large_cache(0)

      freed.each { |p| heap.is_heap_ptr(p).should be_false }
      kept.each_with_index do |p, j|
        heap.is_heap_ptr(p).should be_true
        p.as(UInt8*)[99_999].should eq((2 * j + 1).to_u8)
      end
      listed = 0
      heap.each_chunk do |c|
        heap.chunk_containing_public?(c.address + 64).should be_true
        listed += 1
      end
      listed.should eq(heap.@chunk_index_count)
      heap.large_free_bytes.should eq(0)

      # The list still takes prepends and single unlinks afterwards.
      fresh = heap.malloc(100_000)
      heap.free(kept.first)
      heap.trim_large_cache(0)
      heap.is_heap_ptr(kept.first).should be_false
      heap.is_heap_ptr(fresh).should be_true
      kept.skip(1).each { |p| heap.is_heap_ptr(p).should be_true }
    ensure
      heap.destroy
    end
  end

  # `free` lets the cache run up to `LARGE_FREE_TRIM_SLACK` past the retain,
  # then trims all of it in one batch. The collector trims to the retain
  # itself at the end of every collection.
  it "trims large cache down to large_cache_retain once frees pass the slack" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.large_cache_retain = 0
      ptrs = [] of Void*
      4.times { ptrs << heap.malloc(100_000) }
      ptrs.each { |p| heap.free(p) }
      # Under the slack: still cached, and reusable.
      heap.large_free_bytes.should eq(heap.large_mapped_bytes)
      heap.large_free_bytes.should be <= Gcry::Heap::LARGE_FREE_TRIM_SLACK
      heap.trim_large_cache
      heap.large_free_bytes.should eq(0)
      heap.large_mapped_bytes.should eq(0)

      # Past the slack: the free that crosses it trims everything.
      big = [] of Void*
      30.times { big << heap.malloc(100_000) }
      big.each { |p| heap.free(p) }
      heap.large_free_bytes.should be <= Gcry::Heap::LARGE_FREE_TRIM_SLACK
      heap.large_mapped_bytes.should eq(heap.large_free_bytes)
      big.count { |p| heap.is_heap_ptr(p) }.should be < 30
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

  # A large block grows by `realloc` without a copy in two ways: in place,
  # into room reserved past it (`Heap#grow_large`, the default), and with
  # `realloc_move` on (opt-in), Linux hands its pages to the grown block
  # (`Heap#move_large_contents`). Every step of a growth chain has to carry
  # the same bytes, read zeroes past them, and keep what they point at alive
  # through a collection — the pointers now live only in pages committed in
  # place, or in pages the kernel moved.
  {true, false}.each do |in_place|
    it "realloc of a large block keeps contents, zero tail and referents through a growth chain (#{in_place ? "in place" : "moving"})" do
      heap = Gcry::Heap.new
      begin
        heap.gc_threshold = UInt64::MAX
        heap.realloc_in_place = in_place
        heap.realloc_move = !in_place
        size = 40_000 # words: 320 KB, past REALLOC_MOVE_MIN
        buf = heap.malloc(size * 8).as(UInt64*)
        size.times { |i| buf[i] = 0x5EED_0000_0000_u64 | i }
        referents = 64
        ReallocMoveSpec.store_referents(heap, buf, referents)
        12.times do
          grown = size + size // 2
          buf = heap.realloc(buf.as(Void*), grown * 8).as(UInt64*)
          (size...grown).each { |i| buf[i].should eq(0_u64) }
          (size...grown).each { |i| buf[i] = 0x5EED_0000_0000_u64 | i }
          size = grown
        end
        (referents...size).each { |i| buf[i].should eq(0x5EED_0000_0000_u64 | i) }

        heap.collect
        # Reuse whatever the collection freed, so a referent it wrongly freed
        # is overwritten.
        4096.times { heap.malloc(64).as(UInt64*).value = 0xBAD_u64 }
        referents.times do |i|
          obj = Pointer(UInt64).new(buf[i])
          heap.live?(obj.as(Void*)).should be_true
          8.times { |w| obj[w].should eq(0xC0DE_0000_u64 | (i &* 8 &+ w)) }
        end
        if in_place
          # The first growth copies (the block came from `malloc`, with no
          # room), and so does each that outgrows its room; most of the
          # twelve grow in place.
          heap.realloc_in_place_grows.should be >= 6
          heap.realloc_moves.should eq(0)
        else
          heap.realloc_in_place_grows.should eq(0)
          {% if flag?(:linux) %}
            heap.realloc_moves.should be > 0
          {% end %}
        end
      ensure
        heap.destroy
      end
    end
  end

  # The first growth of a large block copies into a chunk with room reserved
  # past it; the next grows into the room where it stands. Only the pages a
  # growth commits count as mapped, and the room shrinks by as much. A buffer
  # of a power of two, as `IO::Memory` and `String::Builder` keep, grows
  # exactly `large_reserve_doublings` times in place, though its headers put
  # its mapping one page past that power, and the next growth copies.
  it "realloc grows a large block in place into room an earlier growth reserved" do
    heap = Gcry::Heap.new
    begin
      heap.chunk_radix = false # its leaves are mapped too: os_mapped_bytes below is exact
      heap.gc_threshold = UInt64::MAX
      heap.large_reserve_doublings = 2
      page = Gcry::Platform.host_page_size
      data = Gcry::ChunkHeader.large_data_offset.to_u64
      first = heap.malloc(1 << 20)
      grown = heap.realloc(first, 2 << 20)
      grown.should_not eq(first)
      heap.large_reservations.should eq(1)
      base, extent = ReservationSpec.chunk_of(heap, grown)
      mapped = Gcry::Heap.align_up(data + (2 << 20), page)
      extent.should eq((8 << 20) + page)
      heap.large_reserved_bytes.should eq(extent - mapped)
      grown.as(UInt8*).to_slice(2 << 20).fill(0x5A_u8)

      large_before = heap.large_mapped_bytes
      heap_before = heap.heap_size
      os_before = Gcry.os_mapped_bytes
      heap.realloc(grown, 4 << 20).should eq(grown)
      same = heap.realloc(grown, 8 << 20)
      same.should eq(grown)
      heap.realloc_in_place_grows.should eq(2)
      committed = Gcry::Heap.align_up(data + (8 << 20), page) - mapped
      heap.large_mapped_bytes.should eq(large_before + committed)
      heap.heap_size.should eq(heap_before + committed)
      Gcry.os_mapped_bytes.should eq(os_before + committed)
      heap.large_reserved_bytes.should eq(extent - mapped - committed)
      heap.usable_size(same).should eq(8 << 20)
      bytes = same.as(UInt8*)
      bytes.to_slice(2 << 20).all? { |b| b == 0x5A_u8 }.should be_true
      (bytes + (2 << 20)).to_slice(6 << 20).all?(&.zero?).should be_true
      # The new pages are the block's: an interior pointer there finds it.
      heap.find_block(Pointer(Void).new(same.address + (8 << 20) - 1)).should eq(heap.find_block(same))
      ReservationSpec.mapped?(base, extent).should_not be_false

      # The room is used up: this one copies, into room of its own.
      heap.realloc(same, 16 << 20).should_not eq(same)
      heap.realloc_in_place_grows.should eq(2)
      heap.large_reservations.should eq(2)
    ensure
      heap.destroy
    end
  end

  # The room goes back when the block dies, by `free` or by a collection,
  # and when the heap does; a cached chunk is only its mapping, so a trim
  # unmaps all that is left. Each block grows into part of its room, so
  # both the committed pages and the room past them are there to give back.
  it "gives the room back when the block is freed" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      page = Gcry::Platform.host_page_size
      grown = heap.realloc(heap.malloc(1 << 20), 2 << 20)
      heap.realloc(grown, 3 << 20).should eq(grown)
      base, extent = ReservationSpec.chunk_of(heap, grown)
      extent.should be > 0
      ReservationSpec.mapped?(base + extent - page, page).should_not be_false
      large_before = heap.large_mapped_bytes
      heap.free(grown)
      heap.large_reserved_bytes.should eq(0)
      heap.large_grow_extent(Pointer(Gcry::ChunkHeader).new(base)).should eq(0)
      # Cached: the mapping stays, the room past it does not.
      ReservationSpec.mapped?(base, page).should_not be_false
      ReservationSpec.mapped?(base + extent - page, page).should_not be_true
      heap.trim_large_cache(0)
      ReservationSpec.mapped?(base, page).should_not be_true
      heap.large_mapped_bytes.should be < large_before
    ensure
      heap.destroy
    end
  end

  it "gives the room back when a collection frees the block" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      page = Gcry::Platform.host_page_size
      grown = heap.realloc(heap.malloc(1 << 20), 2 << 20)
      heap.realloc(grown, 3 << 20).should eq(grown)
      base, extent = ReservationSpec.chunk_of(heap, grown)
      extent.should be > 0
      ReservationSpec.mapped?(base + extent - page, page).should_not be_false
      heap.collect(scan_stack: false)
      heap.live?(grown).should be_false
      heap.large_reserved_bytes.should eq(0)
      ReservationSpec.mapped?(base + extent - page, page).should_not be_true
    ensure
      heap.destroy
    end
  end

  it "gives a live block's room back when the heap is destroyed" do
    heap = Gcry::Heap.new
    heap.gc_threshold = UInt64::MAX
    grown = heap.realloc(heap.malloc(1 << 20), 2 << 20)
    base, extent = ReservationSpec.chunk_of(heap, grown)
    extent.should be > 0
    ReservationSpec.mapped?(base, extent).should_not be_false
    heap.destroy
    heap.large_reserved_bytes.should eq(0)
    page = Gcry::Platform.host_page_size
    ReservationSpec.mapped?(base, page).should_not be_true
    ReservationSpec.mapped?(base + extent - page, page).should_not be_true
  end

  # Without room, a growth that still fits the block's last page stays in
  # place, and what that page held past the block reads zeroes: here the
  # bytes a larger block wrote into the same cached chunk before it.
  it "realloc grows a large block within its own last page, clearing what was there" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.large_recycle = false
      page = Gcry::Platform.host_page_size.to_i32
      # Two payloads with one mapping: 100 pages and the large header, and as
      # much of the 101st page as the header leaves.
      narrow = 100 * page
      wide = 101 * page - Gcry::ChunkHeader.large_data_offset
      old = heap.malloc(wide)
      old.as(UInt8*).to_slice(wide).fill(0xEE_u8)
      heap.free(old)
      block = heap.malloc(narrow)
      block.should eq(old)
      same = heap.realloc(block, wide)
      same.should eq(block)
      heap.realloc_in_place_grows.should eq(1)
      (same.as(UInt8*) + narrow).to_slice(wide - narrow).all?(&.zero?).should be_true
    ensure
      heap.destroy
    end
  end

  {% if flag?(:linux) %}
    # A recycled chunk's pages move into a mapping with room when a growth
    # takes them; the chunk they came from had its own room returned when
    # it died, so nothing is left reserved behind it.
    it "recycles a cached chunk into a growth's room and grows in place from there" do
      heap = Gcry::Heap.new
      begin
        heap.gc_threshold = UInt64::MAX
        heap.large_recycle = true
        heap.large_recycle_budget = UInt64::MAX
        dead = heap.realloc(heap.malloc(1 << 20), 4 << 20)
        dead.as(UInt8*).to_slice(4 << 20).fill(0xAB_u8)
        heap.free(dead)
        heap.large_reserved_bytes.should eq(0)

        small = heap.malloc(4096)
        recycles = heap.large_recycles
        grown = heap.realloc(small, 1 << 20)
        heap.large_recycles.should eq(recycles + 1)
        _, extent = ReservationSpec.chunk_of(heap, grown)
        extent.should be > 0
        grown.as(UInt8*).to_slice(1 << 20).all?(&.zero?).should be_true
        same = heap.realloc(grown, 2 << 20)
        same.should eq(grown)
        same.as(UInt8*).to_slice(2 << 20).all?(&.zero?).should be_true
      ensure
        heap.destroy
      end
    end
  {% end %}

  # Boehm's `GC_realloc(p, 0)` frees `p` and answers null; null grows from
  # nothing, as `malloc`.
  it "realloc to zero frees the block and returns null" do
    heap = Gcry::Heap.new
    begin
      {64, 1 << 20}.each do |size|
        p = heap.malloc(size)
        heap.usable_size(p).should be >= size
        heap.realloc(p, 0).null?.should be_true
        heap.usable_size(p).should eq(0)
      end
      q = heap.realloc(Pointer(Void).null, 64)
      heap.usable_size(q).should be >= 64
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
end
