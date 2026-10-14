require "../../src/gcry"
require "spec"

# `GC.realloc` grows a large block where it stands once a growth has reserved
# room past it (`Heap#grow_large`). Until 2026-10-14 every growth of a large
# block mapped a fresh chunk, faulted it in and copied into it, and left the
# old one for the next sweep: Revcomp's buffers double from 32 KiB to 126 MiB
# three times, 49 fresh mappings and 1 390 MiB in all, +160 000 minor faults
# over Boehm (`bench/log/linux/2026-10-04-revcomp-large-realloc/`). Moving the
# pages instead (`GCRY_REALLOC_MOVE=1`) leaves the old block reading zeroes,
# and Crystal's stdlib reads it after a growth
# (`30_realloc_old_block_readable_spec.cr`); in place, the old pointer *is*
# the grown block, so nothing it reads changes.
#
# The first growth of a block `malloc` sized copies, into a chunk with room
# reserved past it; the examples grow from there.

private GROW_FIRST = 1 << 20
private GROW_ROOM  = 2 << 20
private GROW_TAG   = 0x6600_DEAD_BEEF_0066_u64

private def grow_pattern(i : Int) : UInt8
  (i % 251 + 1).to_u8
end

# A block of `GROW_ROOM` bytes with room past it, its first `GROW_FIRST`
# bytes the pattern.
private def grown_with_room : Pointer(UInt8)
  first = GC.malloc(LibC::SizeT.new(GROW_FIRST)).as(UInt8*)
  GROW_FIRST.times { |i| first[i] = grow_pattern(i) }
  GC.realloc(first.as(Void*), LibC::SizeT.new(GROW_ROOM)).as(UInt8*)
end

private class GrowChild
  @@finalized = 0

  def self.finalized : Int32
    @@finalized
  end

  getter tag : UInt64

  def initialize(@tag : UInt64)
  end

  def finalize
    @@finalized += 1
  end
end

@[NoInline]
private def grow_store_child(slot : GrowChild*) : Nil
  slot.value = GrowChild.new(GROW_TAG)
end

@[NoInline]
private def grow_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

# On a fiber of its own, as in `43_large_object_over_4gib_spec`, so the slot
# in the grown pages is the child's only reference.
private def grow_store_on_fiber(slot : GrowChild*) : Nil
  done = Channel(Nil).new
  spawn do
    grow_store_child(slot)
    grow_scrub
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

{% if flag?(:linux) %}
  # The permissions `/proc/self/maps` gives the mapping holding *addr*, nil
  # when nothing is mapped there.
  private def grow_maps_perms(addr : UInt64) : String?
    File.each_line("/proc/self/maps") do |line|
      range, perms = line.split(' ', 3)
      lo, hi = range.split('-').map(&.to_u64(16))
      return perms if addr >= lo && addr < hi
    end
    nil
  end
{% end %}

describe "Regression: realloc grows a large block in place" do
  # The room holds at least one doubling (`Heap::LARGE_RESERVE_DOUBLINGS`),
  # so each example grows one, in steps.
  it "keeps the address and the contents, so the old pointer is the grown block" do
    block = grown_with_room
    GROW_FIRST.times { |i| block[i].should eq(grow_pattern(i)) }
    size = GROW_ROOM
    {GROW_ROOM + GROW_ROOM // 2, GROW_ROOM * 2}.each do |to|
      grown = GC.realloc(block.as(Void*), LibC::SizeT.new(to)).as(UInt8*)
      grown.should eq(block)
      # Zeroes past the old size, as a fresh block's (`gc.h`).
      (block + size).to_slice(to - size).all?(&.zero?).should be_true
      size = to
      Gcry.usable_size(block.as(Void*)).should be >= size
    end
    GROW_FIRST.times { |i| block[i].should eq(grow_pattern(i)) }
  end

  it "keeps what the grown pages hold alive through collections" do
    block = grown_with_room
    grown = GC.realloc(block.as(Void*), LibC::SizeT.new(GROW_ROOM * 2)).as(UInt8*)
    grown.should eq(block)
    slot = (block + GROW_ROOM + GROW_ROOM // 2).as(GrowChild*)
    before = GrowChild.finalized
    grow_store_on_fiber(slot)
    3.times { GC.collect }
    GrowChild.finalized.should eq(before)
    Gcry.default_heap.live?(slot.value.as(Void*)).should be_true
    slot.value.tag.should eq(GROW_TAG)
  end

  {% if flag?(:linux) %}
    it "counts only the pages it commits, and gives the room back when the block dies" do
      heap = Gcry.default_heap
      page = Gcry::Platform.host_page_size
      data = Gcry::ChunkHeader.large_data_offset.to_u64
      GC.disable
      begin
        block = grown_with_room
        base = heap.chunk_address_of(block.as(Void*))
        large_before = heap.large_mapped_bytes
        # Into part of the room, so some is left to see given back.
        to = GROW_ROOM + GROW_ROOM // 2
        GC.realloc(block.as(Void*), LibC::SizeT.new(to)).as(UInt8*).should eq(block)
        mapped = Gcry::Heap.align_up(data + to, page)
        committed = mapped - Gcry::Heap.align_up(data + GROW_ROOM, page)
        # Large bytes, not `Gcry.os_mapped_bytes`: another thread of this
        # process may map a size-class chunk or a radix leaf meanwhile.
        heap.large_mapped_bytes.should eq(large_before + committed)
        # Past the block's pages, its room: reserved and inaccessible.
        tail = base + mapped
        grow_maps_perms(tail).should eq("---p")
        GC.free(block.as(Void*))
        # Unmapped, unless a mapping made since took the hole.
        grow_maps_perms(tail).should_not eq("---p")
      ensure
        GC.enable
      end
    end
  {% end %}
end
