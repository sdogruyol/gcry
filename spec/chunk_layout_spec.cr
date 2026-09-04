require "./spec_helper"

# The magic reciprocal replaces a 64-bit division on the collector's hottest
# path, so "it is exact" cannot be an argument — it has to be a check. This
# file runs the reciprocal against `//` for every size class at every block
# boundary and every last-byte-of-block within a chunk, at the two chunk sizes
# gcry ships and at the ceiling it asserts.
describe Gcry::Heap do
  it "block_magic is exact at every in-chunk offset, for every size class" do
    [Gcry::Heap::SMALL_CHUNK_BYTES, 262144_u64, 4_u64 * 1024 * 1024].each do |chunk_bytes|
      Gcry::SizeClasses::COUNT.times do |i|
        block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(i).to_u64
        magic = Gcry::Heap.block_magic(block_bytes)

        offset = 0_u64
        while offset < chunk_bytes
          # Both ends of each block: the boundary itself is what `find_block`
          # sees for a base pointer, the last byte is what it sees for the
          # worst-case interior pointer.
          Gcry::Heap.block_ordinal(offset, magic).should eq(offset // block_bytes)
          last = offset + block_bytes - 1
          Gcry::Heap.block_ordinal(last, magic).should eq(last // block_bytes)
          offset += block_bytes
        end
      end
    end
  end

  it "block_magic stays exact up to the chunk ceiling it asserts" do
    # Not a sample, and not a re-derivation either.
    #
    # The reciprocal's failure is not monotone — past the first bad offset the
    # two agree again at most offsets — so four offsets per class prove
    # nothing, and that is exactly how a real bound violation passed this
    # spec: under `-Dgcry_headerless` class 38 first disagrees at 51.2 MiB
    # while the ceiling allowed 64 MiB, and `limit - 1` happened to land in an
    # agreeing region.
    #
    # Recomputing `2^40 / e` here would not fix that: it is the same
    # expression `max_reciprocal_chunk_bytes` uses, so an error in the
    # derivation would appear identically on both sides and still pass. So the
    # first disagreement is **found by scanning**, with the quotient carried
    # incrementally rather than divided, and the ceiling has to sit at or
    # below it. That is an independent witness: it would catch a wrong shift,
    # a wrong `e`, or a class missing from the walk.
    limit = Gcry::Heap.max_reciprocal_chunk_bytes
    Gcry::SizeClasses::COUNT.times do |i|
      block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(i).to_u64
      magic = Gcry::Heap.block_magic(block_bytes)

      # Walk from the ceiling upward until the two disagree. Exactness below
      # the ceiling is what the next example proves exhaustively; this one
      # only has to show the ceiling is not past the cliff.
      offset = limit
      quotient = limit // block_bytes
      remainder = limit % block_bytes
      first_bad = nil.as(UInt64?)
      scanned = 0
      while scanned < 2_000_000
        if Gcry::Heap.block_ordinal(offset, magic) != quotient
          first_bad = offset
          break
        end
        offset += 1
        remainder += 1
        if remainder == block_bytes
          remainder = 0_u64
          quotient += 1
        end
        scanned += 1
      end

      # A class whose reciprocal is exact (`e == 0`) never disagrees, and a
      # class whose cliff is more than 2M bytes above the ceiling is equally
      # fine — in both cases the scan finds nothing, which is a pass.
      if bad = first_bad
        bad.should be > limit
      end

      [limit - 1, limit - block_bytes, limit // 2, limit // 3].each do |off|
        Gcry::Heap.block_ordinal(off, magic).should eq(off // block_bytes)
      end
    end
  end

  it "the reciprocal is exact at every offset of a default-sized chunk" do
    # The ceiling above is arithmetic; this is the configuration that ships.
    # Every offset, every class, no sampling.
    bytes = Gcry::Heap::SMALL_CHUNK_BYTES
    Gcry::SizeClasses::COUNT.times do |i|
      block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(i).to_u64
      magic = Gcry::Heap.block_magic(block_bytes)
      offset = 0_u64
      while offset < bytes
        Gcry::Heap.block_ordinal(offset, magic).should eq(offset // block_bytes)
        offset += 1
      end
    end
  end

  it "block_magic survives a divisor that is not a size class" do
    # GCRY_CHUNK_BYTES is user-settable, and a future class table could change.
    (1_u64..600_u64).each do |d|
      magic = Gcry::Heap.block_magic(d)
      [0_u64, 1_u64, d - 1, d, d + 1, 65535_u64, 131071_u64].each do |offset|
        Gcry::Heap.block_ordinal(offset, magic).should eq(offset // d)
      end
    end
  end

  it "block_magic(0) is defined rather than a division by zero" do
    Gcry::Heap.block_magic(0_u64).should eq(0_u64)
  end

  describe "chunk geometry" do
    it "keeps the whole metadata region inside page 0" do
      # The invariant every page-release site's safety rests on: the bitmaps
      # share page 0 with the ChunkHeader, and page 0 is never released because
      # a run starting there fails `run_start >= data_start`.
      page = Gcry::Platform.host_page_size
      [Gcry::Heap::SMALL_CHUNK_BYTES, 262144_u64].each do |chunk_bytes|
        Gcry::SizeClasses::COUNT.times do |i|
          block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(i).to_u64
          _, data_offset = Gcry::Heap.chunk_geometry(block_bytes, chunk_bytes, true)
          {% if flag?(:gcry_headerless) %}
            # Class 0 is a 16-byte block, so a 256 KiB chunk carries 2 x 2 KiB of
            # bitmaps and the region ends at byte 4128 — into page 1 on a 4 KiB
            # page host. That page is still never released: every page-release
            # walk only takes runs with `run_start >= data_start`, and page 1
            # starts before it. The invariant is "the page holding data_start is
            # never released", which page 0 satisfied by the same rule.
            data_offset.to_u64.should be < 2 * page
          {% else %}
            data_offset.to_u64.should be < page
          {% end %}
        end
      end
    end

    it "sizes the bitmap to cover every block the chunk actually holds" do
      # The fixed point: bitmap_words is derived from the block count with no
      # bitmap, which over-estimates, so it always covers the real count.
      [Gcry::Heap::SMALL_CHUNK_BYTES, 262144_u64].each do |chunk_bytes|
        Gcry::SizeClasses::COUNT.times do |i|
          block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(i).to_u64
          words, data_offset = Gcry::Heap.chunk_geometry(block_bytes, chunk_bytes, true)
          nblocks = Gcry::Heap.chunk_block_count(block_bytes, chunk_bytes, data_offset)
          (words.to_u64 * 64).should be >= nblocks
          # And not wastefully large: never more than one word of slack.
          # Slack: the words cover the whole chunk, so the blocks displaced by
          # the metadata region plus one word of rounding.
          (words.to_u64 * 64 - nblocks).should be < 64 + data_offset.to_u64 // block_bytes + 64
        end
      end
    end

    it "costs under 1% of a chunk even in the worst class" do
      block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(0).to_u64
      words, data_offset = Gcry::Heap.chunk_geometry(block_bytes, Gcry::Heap::SMALL_CHUNK_BYTES, true)
      {% if flag?(:gcry_headerless) %}
        # 16-byte blocks: 8192 bits per bitmap, two bitmaps, 1.6% of the chunk.
        words.should eq(128)
        data_offset.should eq(2080)
        (data_offset.to_f / Gcry::Heap::SMALL_CHUNK_BYTES.to_f).should be < 0.02
      {% else %}
        words.should eq(64)
        data_offset.should eq(1056)
        (data_offset.to_f / Gcry::Heap::SMALL_CHUNK_BYTES.to_f).should be < 0.01
      {% end %}
    end

    {% unless flag?(:gcry_headerless) %}
      # Bitmaps cannot be off under headerless; the geometry's off-branch is unreachable there.
      it "reports no bitmap and the bare header when bitmaps are off" do
        Gcry::SizeClasses::COUNT.times do |i|
          block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(i).to_u64
          words, data_offset = Gcry::Heap.chunk_geometry(block_bytes, Gcry::Heap::SMALL_CHUNK_BYTES, false)
          words.should eq(0_u32)
          data_offset.should eq(Gcry::ChunkHeader::SIZE.to_u32)
        end
      end
    {% end %}

    it "declines to carve a chunk too small to hold one block" do
      words, data_offset = Gcry::Heap.chunk_geometry(4096_u64, 64_u64, true)
      words.should eq(0_u32)
      data_offset.should eq(Gcry::ChunkHeader::SIZE.to_u32)
    end
  end

  describe "tail_mask" do
    it "covers exactly the blocks that exist" do
      Gcry::Heap.tail_mask(64_u64).should eq(UInt64::MAX)
      Gcry::Heap.tail_mask(128_u64).should eq(UInt64::MAX)
      Gcry::Heap.tail_mask(1_u64).should eq(1_u64)
      Gcry::Heap.tail_mask(63_u64).should eq((1_u64 << 63) - 1)
      Gcry::Heap.tail_mask(65_u64).should eq(1_u64)
    end

    it "masks off the blocks past data_end that ~occ would otherwise offer" do
      # 128 KiB, class 0: 4063 blocks in a 4096-bit map. Without the mask the
      # allocator would be handed 33 slots past the end of the chunk.
      block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(0).to_u64
      words, data_offset = Gcry::Heap.chunk_geometry(block_bytes, Gcry::Heap::SMALL_CHUNK_BYTES, true)
      nblocks = Gcry::Heap.chunk_block_count(block_bytes, Gcry::Heap::SMALL_CHUNK_BYTES, data_offset)
      {% if flag?(:gcry_headerless) %}
        nblocks.should eq(8062_u64)
        (words.to_u64 * 64 - nblocks).should eq(130_u64)
        Gcry::Heap.tail_mask(nblocks).popcount.should eq(8062 & 63)
      {% else %}
        nblocks.should eq(4063_u64)
        (words.to_u64 * 64 - nblocks).should eq(33_u64)
        Gcry::Heap.tail_mask(nblocks).popcount.should eq(4063 & 63)
      {% end %}
    end
  end

  describe "ChunkHeader" do
    it "keeps large chunks at the constant offset the back-references assume" do
      # heap.cr:1299 and five siblings, collect.cr:1017, collect_sweep.cr:386
      # and :751 all recover a large chunk as `header - ChunkHeader::SIZE`.
      # That is only correct while large chunks carry no bitmap region.
      bytes = 65536_u64
      raw = Pointer(UInt8).malloc(bytes)
      chunk = raw.as(Gcry::ChunkHeader*)
      chunk.value = Gcry::ChunkHeader.new(Pointer(Gcry::ChunkHeader).null, bytes, UInt32::MAX)
      Gcry::ChunkHeader.large?(chunk).should be_true
      chunk.value.data_offset.should eq(Gcry::ChunkHeader::SIZE.to_u32)
      Gcry::ChunkHeader.data_start(chunk).address.should eq(chunk.address + Gcry::ChunkHeader::SIZE)
      Gcry::ChunkHeader.occ_bitmap(chunk).should eq(Pointer(UInt64).null)
      Gcry::ChunkHeader.mark_bitmap(chunk).should eq(Pointer(UInt64).null)
    end

    it "places occ and mark back to back after the header" do
      bytes = Gcry::Heap::SMALL_CHUNK_BYTES
      raw = Pointer(UInt8).malloc(bytes)
      chunk = raw.as(Gcry::ChunkHeader*)
      block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(0).to_u64
      words, data_offset = Gcry::Heap.chunk_geometry(block_bytes, bytes, true)
      chunk.value = Gcry::ChunkHeader.new(Pointer(Gcry::ChunkHeader).null, bytes, 0_u32,
        0_u32, data_offset, words)

      occ = Gcry::ChunkHeader.occ_bitmap(chunk)
      mark = Gcry::ChunkHeader.mark_bitmap(chunk)
      occ.address.should eq(chunk.address + Gcry::ChunkHeader::SIZE)
      mark.address.should eq(occ.address + words.to_u64 * 8)
      # Both bitmaps end before the first block, with no overlap either way.
      (mark.address + words.to_u64 * 8).should be <= Gcry::ChunkHeader.data_start(chunk).address
    end
  end
  describe "allocation alignment" do
    # gcry's `GC.malloc` stands in for the platform allocator, so what it
    # returns has to be aligned for any type — `max_align_t` is 16 on x86-64
    # and aarch64, and Boehm returns 16-byte-aligned memory.
    #
    # It did not. Before the header grew, `data_start` was `chunk + 24` and a
    # block is `16 + payload`, so every user pointer landed at `chunk + 40`
    # plus a multiple of 16 — i.e. **8 mod 16, every allocation, small and
    # large**. Measured at c62f722: 140 of 140 misaligned. Anything needing
    # 16-byte alignment on GC memory (an SSE load, a C library handed a gcry
    # pointer, a type containing a 16-byte-aligned member) was relying on luck.
    #
    # `ChunkHeader::SIZE` 24 -> 32 makes `24 + 16 = 40` into `32 + 16 = 48` and
    # fixes it. That is currently a *consequence* of the bitmap work rather than
    # its purpose, which is exactly why it is pinned here: the next change to
    # the header size must not quietly undo it.
    it "returns 16-byte-aligned memory for every size class and for large objects" do
      heap = Gcry::Heap.new
      begin
        misaligned = 0
        checked = 0
        Gcry::SizeClasses::COUNT.times do |i|
          payload = Gcry::SizeClasses.payload(i)
          4.times do
            ptr = heap.malloc(payload.to_u64)
            next if ptr.null?
            checked += 1
            misaligned += 1 if (ptr.address % 16) != 0
          end
        end
        # Large objects take a different path and were equally misaligned.
        [40_000_u64, 100_000_u64, 300_000_u64].each do |size|
          4.times do
            ptr = heap.malloc(size)
            next if ptr.null?
            checked += 1
            misaligned += 1 if (ptr.address % 16) != 0
          end
        end
        checked.should be > 150
        misaligned.should eq(0)
      ensure
        heap.destroy
      end
    end

    it "derives that alignment from the layout rather than from luck" do
      # The property that makes it hold: the first block starts at a multiple
      # of 16 from a page-aligned chunk base, and every block stride is a
      # multiple of 16, so `data_offset + BlockHeader::SIZE` being 0 mod 16 is
      # what carries it to every block in the chunk.
      (Gcry::ChunkHeader::SIZE % 16).should eq(0)
      (Gcry::BlockHeader::SIZE % 16).should eq(0)
      Gcry::SizeClasses::COUNT.times do |i|
        block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(i).to_u64
        (block_bytes % 16).should eq(0)
        _, data_offset = Gcry::Heap.chunk_geometry(block_bytes, Gcry::Heap::SMALL_CHUNK_BYTES, true)
        ((data_offset.to_u64 + Gcry::BlockHeader::SIZE) % 16).should eq(0)
        # And with bitmaps off, which is the default until the cut says otherwise.
        _, plain = Gcry::Heap.chunk_geometry(block_bytes, Gcry::Heap::SMALL_CHUNK_BYTES, false)
        ((plain.to_u64 + Gcry::BlockHeader::SIZE) % 16).should eq(0)
      end
    end
  end
end
