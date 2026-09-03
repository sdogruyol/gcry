require "./block"
require "./size_classes"

module Gcry
  class Heap
    # Where a size-class chunk's bitmaps live, and how an address inside it
    # becomes a block ordinal.
    #
    # ## Bitmaps inside the chunk
    #
    # `occ` and `mark` sit between the `ChunkHeader` and the first block, so a
    # chunk's metadata is one contiguous run, the bitmaps are freed with the
    # chunk, and there is no side arena to allocate, free-list or keep alive.
    # Worst case is class 0: 64 words each, 1024 B of a 128 KiB chunk, 0.78%.
    #
    # The reason this is safe against `MADV_DONTNEED` is worth stating, because
    # it is inherited rather than designed. `release_free_pages_in_chunk`
    # (collect_sweep.cr) builds page runs from `data0 & ~(page-1)` — the chunk
    # base, since chunks are page-aligned — but releases a run only when
    # `run_start >= data0` (collect_sweep.cr:1175, and the twin at :803). Since
    # `data_start` is strictly inside page 0, a run starting at page 0 always
    # fails that test, so **page 0 is never released**. That was already true of
    # the 24-byte header; moving `data_start` forward keeps it true for free.
    # The other two release sites round *up* from `data_start` (:615, :1059) and
    # so cannot reach the bitmaps either.
    #
    # The invariant that rests on is asserted, not assumed:
    # `data_offset < Platform.host_page_size` — the whole metadata region lives
    # in page 0. It holds with margin everywhere gcry runs (1056 B for a 128 KiB
    # chunk, 2080 B for Darwin's 256 KiB, against a 4 KiB or 16 KiB page); a
    # future chunk size that broke it would put bitmap bytes in page 1, which
    # *is* releasable.
    #
    # ## Sizing is a fixed point, resolved by rounding up
    #
    # `bitmap_words` depends on the block count, which depends on `data_offset`,
    # which depends on `bitmap_words`. Sizing from the block count a chunk would
    # hold with *no* bitmap (`n0`) always over-estimates, so the bitmap is
    # always at least large enough. The few unused tail bits are what
    # `tail_mask` exists to mask off — `~occ` would otherwise offer blocks past
    # `data_end`.

    # The largest chunk for which the shift-40 reciprocal below is exact.
    #
    # With `e = magic*d - 2^40`, the first offset where `(off*magic) >> 40`
    # disagrees with `off // d` is `2^40 / e`. Across the 40 size classes the
    # tightest is `block_bytes = 24592`, which first fails at 86.3 MiB. 64 MiB
    # is that bound rounded down to something memorable, and it is 512x the
    # 128 KiB default and 256x Darwin's 256 KiB. `GCRY_CHUNK_BYTES` is
    # user-settable with no upper bound (gc_override.cr), which is why this is
    # checked rather than trusted.
    MAX_RECIPROCAL_CHUNK_BYTES = 64_u64 * 1024 * 1024

    RECIPROCAL_SHIFT = 40

    # `ceil(2^40 / block_bytes)`, so that `(offset * magic) >> 40` is exactly
    # `offset // block_bytes` for every offset within a chunk.
    #
    # Replaces a 64-bit division on the hottest path in the collector:
    # `find_block` divides once per accepted candidate word (collect.cr), and
    # the bitmap adds an address-to-ordinal conversion on top. The widest
    # intermediate is 58 bits at a 4 MiB chunk, so nothing overflows.
    def self.block_magic(block_bytes : UInt64) : UInt64
      return 0_u64 if block_bytes == 0
      ((1_u64 << RECIPROCAL_SHIFT) + block_bytes - 1) // block_bytes
    end

    # Block ordinal of `offset` bytes into a chunk's data area.
    @[AlwaysInline]
    def self.block_ordinal(offset : UInt64, magic : UInt64) : UInt64
      (offset * magic) >> RECIPROCAL_SHIFT
    end

    # Bitmap words per bitmap, and the resulting data offset, for a size-class
    # chunk of `mapped_bytes`. `{0, ChunkHeader::SIZE}` when the bitmap
    # representation is off — the chunk then looks exactly as it did before,
    # apart from the eight bytes the header itself grew.
    def self.chunk_geometry(block_bytes : UInt64, mapped_bytes : UInt64,
                            bitmaps : Bool) : {UInt32, UInt32}
      # Large chunks (bitmaps == false) hold exactly one object and keep a real
      # block header — under headerless it is reserved *inside the metadata
      # region*, between ChunkHeader and data_start, rather than in front of the
      # object. Large blocks need somewhere to store the freelist and
      # pending-large-cache links that `cache_large_chunk` and `sweep_large`
      # chain them through, and with no header those writes land on the object's
      # own bytes. One header per large chunk is free; one per small block is
      # the 16 bytes this phase exists to remove.
      unless bitmaps
        {% if flag?(:gcry_headerless) %}
          return {0_u32, (ChunkHeader::SIZE + 16).to_u32}
        {% else %}
          return {0_u32, ChunkHeader::SIZE.to_u32}
        {% end %}
      end
      return {0_u32, ChunkHeader::SIZE.to_u32} if block_bytes == 0

      headerless = mapped_bytes - ChunkHeader::SIZE
      return {0_u32, ChunkHeader::SIZE.to_u32} if headerless < block_bytes

      # Upper bound on blocks: what would fit with no bitmap at all.
      n0 = headerless // block_bytes
      words = ((n0 + 63) // 64).to_u32
      # Two bitmaps, then round the first block up to 16 so payloads keep the
      # alignment they have today.
      offset = ChunkHeader::SIZE.to_u64 + words.to_u64 * 2 * 8
      offset = (offset + 15) & ~15_u64
      {words, offset.to_u32}
    end

    # Blocks a chunk actually holds, given where its data starts.
    def self.chunk_block_count(block_bytes : UInt64, mapped_bytes : UInt64,
                               data_offset : UInt32) : UInt64
      return 0_u64 if block_bytes == 0 || mapped_bytes <= data_offset
      (mapped_bytes - data_offset) // block_bytes
    end

    # Mask for the last bitmap word: set bits are real blocks.
    #
    # `nblocks` is not a multiple of 64 — a 128 KiB class-0 chunk holds 4063
    # blocks in a 4096-bit map — so `~occ` without this offers 33 blocks past
    # `data_end`. Every word below the last is all-ones.
    def self.tail_mask(nblocks : UInt64) : UInt64
      rem = nblocks & 63
      rem == 0 ? UInt64::MAX : (1_u64 << rem) - 1
    end
  end
end
