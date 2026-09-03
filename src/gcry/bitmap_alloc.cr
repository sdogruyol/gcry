require "./block"
require "./kernels"

module Gcry
  class Heap
    # Bitmap-driven small allocation: the `occ` half of the representation.
    #
    # ## Why this cannot be split from the sweep
    #
    # `occ` says which blocks are allocated. It is only sound if *allocation
    # itself* sets the bit — an `occ` maintained beside a freelist is the design
    # `bench/log/linux/2026-08-01-ec4-alloc-bits/summary.md` rejected at
    # `/json` 54k → 44k, and `-ec4-used-count-v2` names the failure class:
    # "accounting that enables skip is not free on the HTTP alloc path".
    #
    # It is tempting to think `occ` could be derived purely at sweep time, since
    # the sweep publishes `occ = mark`. It cannot: between two sweeps the
    # allocator would see every block allocated since the last one as free in
    # `~occ` and hand out live memory. So the bit is set on the allocation path
    # or the representation is wrong — and the only way that is affordable is
    # for the allocation path to already hold the chunk.
    #
    # ## The pool cursor is what makes it affordable
    #
    # Per size class the heap keeps `{chunk, word, free_mask, word_base}`. The
    # fast path is: `tzcnt` the cached mask, clear that bit from it, set the
    # `occ` bit, return `word_base + ordinal * block_bytes`. **No chunk lookup,
    # no freelist chase, no dependent load through free memory.** The size-class
    # lock is taken once per *word* of 64 blocks rather than once per block.
    #
    # That is the whole reason a chunk lookup may never appear here: 2026-08-01's
    # v1 added `chunk_containing` per small allocation and took quiet `/json` to
    # **56.3%** of Boehm.
    #
    # ## The free mask is not `~occ`
    #
    # Three corrections, each of which would otherwise hand out memory that must
    # not be handed out:
    #
    # - **Tail bits.** A 128 KiB class-0 chunk holds 4063 blocks in a 4096-bit
    #   map, so `~occ` offers 33 slots past `data_end`.
    # - **Released pages.** `rebuild_size_class_freelist` deliberately omits free
    #   blocks sitting on `MADV_DONTNEED`'d page runs (collect_sweep.cr), because
    #   handing one back refaults a page that was just released and, on the
    #   DONTNEED path, returns a zeroed header. `~occ` knows nothing about that.
    # - **Blacklisted pages.** A page the blacklist has excluded must not be
    #   allocated from at all.
    #
    # So the mask is `~occ & tail_mask & usable_mask`, where `usable_mask` is
    # built once per chunk when the chunk enters the pool rather than per word.

    # Pool cursor, one per size class. `@pool_free_mask` is the live one: a set
    # bit is a free block in `@pool_word` of `@pool_chunk`.
    @pool_chunk = uninitialized StaticArray(ChunkHeader*, SIZE_CLASS_COUNT)
    @pool_word = uninitialized StaticArray(Int32, SIZE_CLASS_COUNT)
    @pool_free_mask = uninitialized StaticArray(UInt64, SIZE_CLASS_COUNT)
    @pool_word_base = uninitialized StaticArray(UInt64, SIZE_CLASS_COUNT)

    getter bitmap_alloc_fast : UInt64 = 0_u64
    getter bitmap_alloc_refills : UInt64 = 0_u64
    getter bitmap_alloc_chunk_advances : UInt64 = 0_u64

    protected def bitmap_alloc_init : Nil
      @pool_chunk = StaticArray(ChunkHeader*, SIZE_CLASS_COUNT).new(Pointer(ChunkHeader).null)
      @pool_word = StaticArray(Int32, SIZE_CLASS_COUNT).new(0)
      @pool_free_mask = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      @pool_word_base = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
    end

    # Blocks this chunk actually holds.
    @[AlwaysInline]
    protected def chunk_block_count(chunk : ChunkHeader*) : UInt64
      class_index = chunk.value.size_class.to_i32
      return 0_u64 if class_index < 0 || class_index >= SIZE_CLASS_COUNT
      Heap.chunk_block_count(@block_bytes[class_index], chunk.value.mapped_bytes,
        chunk.value.data_offset)
    end

    # Free blocks in one bitmap word, with every correction applied. See the
    # note above for why each is needed.
    @[AlwaysInline]
    protected def chunk_free_mask(chunk : ChunkHeader*, word : Int32, nblocks : UInt64) : UInt64
      occ = ChunkHeader.occ_bitmap(chunk)
      return 0_u64 if occ.null?
      mask = ~occ[word]
      last_word = ((nblocks - 1) >> 6).to_i32
      mask &= Heap.tail_mask(nblocks) if word == last_word
      mask
    end

    # Allocate one block from the size-class pool. Caller holds the size-class
    # lock. Returns null when the pool could not be refilled.
    #
    # This is the hot path and it is deliberately short: mask test, `tzcnt`,
    # `blsr`, one `occ` store, one address computation.
    protected def bitmap_alloc_locked(index : Int32, payload : UInt32, flags : UInt32) : Void*
      mask = @pool_free_mask[index]
      if mask == 0_u64
        return Pointer(Void).null unless bitmap_refill_pool(index, payload)
        mask = @pool_free_mask[index]
        return Pointer(Void).null if mask == 0_u64
      end

      bit = mask.trailing_zeros_count
      # `blsr`: clear the lowest set bit. The cached mask is thread-private
      # under the size-class lock, so this needs no atomic — unlike the `occ`
      # store below, which shares a word with 63 other blocks.
      @pool_free_mask[index] = mask & (mask &- 1)

      chunk = @pool_chunk[index]
      occ = ChunkHeader.occ_bitmap(chunk)
      word = @pool_word[index]
      bit_mask = 1_u64 << bit
      # Atomic: a concurrent `free` or a mutator allocating from another size
      # class in the same chunk can touch this word. Same hazard as the mark
      # bit, same reasoning — see `chunk_set_mark`.
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, occ + word, bit_mask,
        LLVM::AtomicOrdering::Monotonic, false)

      # `@freelist_clean` is a freelist-shaped claim — "this class's next block
      # comes straight off a fresh chunk, so `allocate` may skip the memset".
      # The pool cursor hands out reused blocks from `~occ` with no such
      # guarantee, and a stale `true` here would hand a caller dirty memory that
      # Crystal assumes is zeroed (`Reference.allocate` zeroes nothing itself).
      # Always false on this path until the cursor tracks cleanliness per chunk.
      @freelist_clean[index] = false

      header_addr = @pool_word_base[index] &+ bit.to_u64 &* @block_bytes[index]
      header = Pointer(BlockHeader).new(header_addr)
      BlockHeader.set_used(header, payload, flags)
      @bitmap_alloc_fast &+= 1
      BlockHeader.user_from(header)
    end

    # Advance the cursor to the next word with a free block, taking another
    # chunk from the class's pool list when the current one is exhausted.
    protected def bitmap_refill_pool(index : Int32, payload : UInt32) : Bool
      loop do
        chunk = @pool_chunk[index]
        if chunk.null?
          chunk = bitmap_take_pool_chunk(index, payload)
          return false if chunk.null?
          @pool_chunk[index] = chunk
          @pool_word[index] = 0
          @bitmap_alloc_chunk_advances &+= 1
        end

        nblocks = chunk_block_count(chunk)
        words = ((nblocks + 63) >> 6).to_i32
        word = @pool_word[index]
        while word < words
          mask = chunk_free_mask(chunk, word, nblocks)
          if mask != 0_u64
            @pool_word[index] = word
            @pool_free_mask[index] = mask
            @pool_word_base[index] = ChunkHeader.data_start(chunk).address &+
                                     (word.to_u64 << 6) &* @block_bytes[index]
            @bitmap_alloc_refills &+= 1
            return true
          end
          word += 1
        end

        # Chunk is full. Drop it; it comes back when a sweep frees something in
        # it. Ascending address order matters on the way back in — the
        # descending list cost `simdgc3.c` 25%, because refill then walked
        # memory backwards and defeated both the hardware prefetcher and the
        # allocation cursor's own locality.
        @pool_chunk[index] = Pointer(ChunkHeader).null
        @pool_free_mask[index] = 0_u64
      end
    end

    # Next chunk of this class with any free block, or a freshly mapped one.
    protected def bitmap_take_pool_chunk(index : Int32, payload : UInt32) : ChunkHeader*
      # Walk the chunk list in address order looking for capacity. This is the
      # slow path — once per exhausted chunk, not once per allocation — so a
      # walk is affordable where a lookup on the fast path would not be.
      best = Pointer(ChunkHeader).null
      each_chunk do |chunk|
        next if ChunkHeader.large?(chunk)
        next unless chunk.value.size_class == index.to_u32
        next if ChunkHeader.dormant?(chunk)
        next if ChunkHeader.nursery?(chunk)
        nblocks = chunk_block_count(chunk)
        next if nblocks == 0
        words = ((nblocks + 63) >> 6).to_i32
        w = 0
        while w < words
          if chunk_free_mask(chunk, w, nblocks) != 0_u64
            best = chunk if best.null? || chunk.address < best.address
            break
          end
          w += 1
        end
      end
      return best unless best.null?

      map_chunk(@small_chunk_bytes, index.to_u32, 0_u32)
    end

    # Release one block back to `occ`. The bit is shared with 63 others, so the
    # clear is atomic for the same reason the set is.
    @[AlwaysInline]
    protected def bitmap_free_block(chunk : ChunkHeader*, header : BlockHeader*) : Nil
      occ = ChunkHeader.occ_bitmap(chunk)
      return if occ.null?
      ordinal = chunk_block_ordinal(chunk, header.address)
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And, occ + (ordinal >> 6),
        ~(1_u64 << (ordinal & 63)), LLVM::AtomicOrdering::Monotonic, false)
    end

    # Drop any cursor pointing into `chunk`. Called before a chunk is made
    # dormant or unmapped: a cursor left pointing at released memory would hand
    # out blocks from a chunk the heap no longer owns.
    protected def bitmap_drop_pool_chunk(chunk : ChunkHeader*) : Nil
      SIZE_CLASS_COUNT.times do |i|
        next unless @pool_chunk[i] == chunk
        @pool_chunk[i] = Pointer(ChunkHeader).null
        @pool_free_mask[i] = 0_u64
        @pool_word[i] = 0
      end
    end
  end
end
