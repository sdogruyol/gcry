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

    # Pool cursor, two per size class (see POOL_SLOTS): pointerful at `class`,
    # atomic at `class + SIZE_CLASS_COUNT`. `@pool_free_mask` is the live one: a
    # set bit is a free block in `@pool_word` of `@pool_chunk`.
    @pool_chunk = uninitialized StaticArray(ChunkHeader*, POOL_SLOTS)
    @pool_word = uninitialized StaticArray(Int32, POOL_SLOTS)
    @pool_free_mask = uninitialized StaticArray(UInt64, POOL_SLOTS)
    @pool_word_base = uninitialized StaticArray(UInt64, POOL_SLOTS)

    # The user pointer of the block each pool slot is handing out right now,
    # rooted by the collector (`mark_bitmap_alloc_in_flight`).
    #
    # The `occ` bit is set well before the caller has the pointer: the store is
    # one instruction, but between it and `BlockHeader.user_from(header)` the
    # only thing this thread holds is the *header* address, and `mark_impl`'s
    # default `base_only` policy rejects a header (`addr != user_of(...)`). So
    # a mutator frozen by the STW signal inside that span leaves a block that
    # is `occ=1, mark=0` and referenced by nothing the scan accepts, and
    # `occ &= mark` clears the bit under a caller that is about to be handed
    # the block — the same memory then goes out again from `~occ`.
    #
    # This is the shape `@large_alloc_in_flight` closes on the large path
    # (`dormant-flush-race`, 2026-09-04). One slot per pool slot rather than
    # one for the heap, because small allocation is serialised per size class,
    # not globally: two mutators can be in `bitmap_alloc_locked` at once for
    # different classes.
    @pool_in_flight = uninitialized StaticArray(Void*, POOL_SLOTS)

    getter bitmap_alloc_fast : UInt64 = 0_u64
    getter bitmap_alloc_refills : UInt64 = 0_u64
    getter bitmap_alloc_chunk_advances : UInt64 = 0_u64
    getter bitmap_dormant_revives : UInt64 = 0_u64

    protected def bitmap_alloc_init : Nil
      @pool_chunk = StaticArray(ChunkHeader*, POOL_SLOTS).new(Pointer(ChunkHeader).null)
      @pool_word = StaticArray(Int32, POOL_SLOTS).new(0)
      @pool_free_mask = StaticArray(UInt64, POOL_SLOTS).new(0_u64)
      @pool_word_base = StaticArray(UInt64, POOL_SLOTS).new(0_u64)
      @pool_in_flight = StaticArray(Void*, POOL_SLOTS).new(Pointer(Void).null)
    end

    # Root every block a pool slot is mid-handover on. Called from the root
    # phase, like `mark_large_alloc_in_flight`. A null slot is the common case
    # — the window is a handful of instructions wide — so this is 96 loads of
    # a static array against losing a live block.
    protected def mark_bitmap_alloc_in_flight : Nil
      return unless @bitmap_alloc
      i = 0
      while i < POOL_SLOTS
        u = @pool_in_flight[i]
        mark_explicit_root(u) unless u.null?
        i += 1
      end
    end

    # Drop the slot's copy once the caller's frame holds the pointer.
    protected def clear_bitmap_alloc_in_flight(index : Int32, flags : UInt32) : Nil
      slot = (flags & BlockHeader::Flags::ATOMIC) != 0 ? index + SIZE_CLASS_COUNT : index
      @pool_in_flight[slot] = Pointer(Void).null
    end

    # Public reads for the diagnostics, which live outside `Heap` and must not
    # be allowed to disagree with the collector about what is allocated. The
    # header's FREE flag is not that answer on a bitmap chunk.
    # Occupancy for one block, for specs and diagnostics that walk a chunk.
    # Spec/diagnostic read of the mark bit, through the collector's own accessor.
    def block_marked_public?(chunk : ChunkHeader*, header : BlockHeader*) : Bool
      block_marked_in?(chunk, header)
    end

    def block_allocated_public?(chunk : ChunkHeader*, header : BlockHeader*) : Bool
      block_allocated?(chunk, header)
    end

    def bitmap_alloc_chunk_public?(chunk : ChunkHeader*) : Bool
      bitmap_alloc_chunk?(chunk)
    end

    # Allocated blocks in a chunk, straight from `occ` — one popcount pass
    # instead of a header walk.
    def chunk_occupied_count(chunk : ChunkHeader*) : UInt64
      occ = ChunkHeader.occ_bitmap(chunk)
      return 0_u64 if occ.null?
      Kernels.popcount_words(occ, chunk.value.bitmap_words.to_i32, @simd_tier)
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
      mask &= blacklist_free_mask(chunk, word, mask) if @blacklist_enabled && mask != 0_u64
      mask
    end

    # Drop blocks sitting on blacklisted pages.
    #
    # The blacklist records pages a false root pointed into; handing one out
    # again re-creates the false retention the blacklist exists to break. The
    # freelist path enforces this with `take_non_blacklisted`, walking past
    # candidates one at a time; on the bitmap path it is a mask, applied once
    # per word rather than once per block.
    #
    # Only consulted when the blacklist is armed *and* the word has free blocks,
    # so the common case pays one predictable branch.
    @[AlwaysInline]
    protected def blacklist_free_mask(chunk : ChunkHeader*, word : Int32, mask : UInt64) : UInt64
      base = ChunkHeader.data_start(chunk).address
      block_bytes = @block_bytes[chunk.value.size_class.to_i32]
      out = mask
      m = mask
      while m != 0_u64
        bit = m.trailing_zeros_count
        m &= m &- 1
        ordinal = (word.to_u64 << 6) &+ bit.to_u64
        if blacklisted_page?(base &+ ordinal &* block_bytes)
          out &= ~(1_u64 << bit)
          # Same counter the freelist path bumps in `take_non_blacklisted`, so
          # `/gc-stats` and the blacklist gate read one number across both
          # representations rather than silently reporting zero on this one.
          @blacklist_skips += 1
        end
      end
      out
    end

    # Allocate one block from the size-class pool. Caller holds the size-class
    # lock. Returns null when the pool could not be refilled.
    #
    # This is the hot path and it is deliberately short: mask test, `tzcnt`,
    # `blsr`, one `occ` store, one address computation.
    protected def bitmap_alloc_locked(index : Int32, payload : UInt32, flags : UInt32) : Void*
      # Kind comes from the request's own flags, so callers are unchanged. The
      # cursor is per (class, kind) because atomic and pointerful blocks live in
      # different chunks now; `@block_bytes` stays class-indexed.
      atomic = (flags & BlockHeader::Flags::ATOMIC) != 0
      slot = atomic ? index + SIZE_CLASS_COUNT : index
      mask = @pool_free_mask[slot]
      if mask == 0_u64
        return Pointer(Void).null unless bitmap_refill_pool(slot, index, payload, atomic)
        mask = @pool_free_mask[slot]
        return Pointer(Void).null if mask == 0_u64
      end

      bit = mask.trailing_zeros_count
      # `blsr`: clear the lowest set bit. The cached mask is thread-private
      # under the size-class lock, so this needs no atomic — unlike the `occ`
      # store below, which shares a word with 63 other blocks.
      @pool_free_mask[slot] = mask & (mask &- 1)

      chunk = @pool_chunk[slot]
      occ = ChunkHeader.occ_bitmap(chunk)
      word = @pool_word[slot]
      bit_mask = 1_u64 << bit

      # Publish the block as a root **before** the `occ` store makes it
      # allocated. Everything from that store until the caller holds the
      # pointer is a window in which the block is occupied, unmarked, and
      # referenced only by a header address the root scan refuses — see
      # `@pool_in_flight`. Two stores of a static-array slot, on the hot path,
      # against handing the same memory to two owners.
      header_addr = @pool_word_base[slot] &+ bit.to_u64 &* @block_bytes[index]
      @pool_in_flight[slot] = Pointer(Void).new(header_addr &+ BlockHeader::SIZE)

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

      header = Pointer(BlockHeader).new(header_addr)

      # Prefetch-for-write ahead of the cursor. Fresh-chunk allocation is bound
      # by the write bandwidth of touching new cache lines, and pulling the line
      # in for write before `set_used` + the caller's zeroing store overlaps
      # that miss. Distance is machine-dependent (`GCRY_ALLOC_PFW`); 0 disables.
      if (pfw = @alloc_pfw) > 0
        Kernels.prefetch_write(Pointer(Void).new(header_addr &+ pfw))
      end

      BlockHeader.set_used(header, payload, flags)

      # Allocate-black, and it is not optional here.
      #
      # `alloc_old_small_locked` ends with this and the bitmap path returns
      # before reaching it, so omitting it silently dropped the mark for every
      # block allocated while `@collecting` — which is the whole post-STW window
      # under lazy sweep. Those blocks then carried `occ=1, mark=0` into
      # `occ &= mark` and were reclaimed **while live**: measured as
      # `after collect #3: root 9 DEAD` in `stw-mt-property-test`, and it went
      # away entirely under `GCRY_DISABLE_LAZY_SWEEP=1`, which is what named it.
      #
      # The cursor's chunk is already in hand, so this is the cheap form — a
      # bit set in a word this thread just touched, no lookup.
      if @incremental_marking || @collecting
        ordinal = (word.to_u64 << 6) &+ bit.to_u64
        chunk_set_mark(chunk, ordinal)
      end

      @bitmap_alloc_fast &+= 1
      BlockHeader.user_from(header)
    end

    # Advance the cursor to the next word with a free block, taking another
    # chunk from the class's pool list when the current one is exhausted.
    protected def bitmap_refill_pool(slot : Int32, index : Int32, payload : UInt32,
                                     atomic : Bool) : Bool
      loop do
        chunk = @pool_chunk[slot]
        if chunk.null?
          chunk = bitmap_take_pool_chunk(index, payload, atomic)
          return false if chunk.null?
          @pool_chunk[slot] = chunk
          @pool_word[slot] = 0
          @bitmap_alloc_chunk_advances &+= 1
        end

        nblocks = chunk_block_count(chunk)
        words = ((nblocks + 63) >> 6).to_i32
        word = @pool_word[slot]
        while word < words
          mask = chunk_free_mask(chunk, word, nblocks)
          if mask != 0_u64
            @pool_word[slot] = word
            @pool_free_mask[slot] = mask
            @pool_word_base[slot] = ChunkHeader.data_start(chunk).address &+
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
        @pool_chunk[slot] = Pointer(ChunkHeader).null
        @pool_free_mask[slot] = 0_u64
      end
    end

    # Next chunk of this class with any free block, or a freshly mapped one.
    protected def bitmap_take_pool_chunk(index : Int32, payload : UInt32,
                                         atomic : Bool) : ChunkHeader*
      # Walk the chunk list in address order looking for capacity. This is the
      # slow path — once per exhausted chunk, not once per allocation — so a
      # walk is affordable where a lookup on the fast path would not be.
      best = Pointer(ChunkHeader).null
      each_chunk do |chunk|
        next if ChunkHeader.large?(chunk)
        next unless chunk.value.size_class == index.to_u32
        # A chunk serves exactly one kind; mixing would put an unscanned block
        # in a scanned chunk and lose its pointers.
        next unless ChunkHeader.atomic?(chunk) == atomic
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

      # Review finding (PR #1): dormant chunks never revived under
      # BITMAP_ALLOC. The walk above skips them (rightly — their data pages
      # are MADV_DONTNEED'd and their bitmaps stale), and the freelist-era
      # `revive_dormant_chunk` rebuilds a freelist through block headers, which
      # is the wrong shape for this allocator and fatal under headerless. So a
      # class that had gone dormant mapped a *new* chunk on every refill while
      # its dormant ones sat in the VMA for good. Revive one here instead:
      # a dormant chunk is fully free, so zeroed bitmaps are exactly right,
      # and page 0 (metadata) was never released.
      if (revived = bitmap_revive_dormant(index, atomic))
        return revived
      end

      map_chunk(@small_chunk_bytes, index.to_u32,
        atomic ? ChunkHeader::Flags::ATOMIC : 0_u32)
    end

    # Bitmap-path counterpart of `revive_dormant_chunk`: no freelist, no header
    # writes. Same flag flip and byte accounting as the header path; free bytes
    # were never subtracted when the chunk went dormant, so none are added back.
    private def bitmap_revive_dormant(index : Int32, atomic : Bool) : ChunkHeader*?
      chunk = @chunks
      while chunk
        if !ChunkHeader.large?(chunk) &&
           ChunkHeader.dormant?(chunk) &&
           !ChunkHeader.nursery?(chunk) &&
           chunk.value.size_class == index.to_u32 &&
           ChunkHeader.atomic?(chunk) == atomic
          # The post-STW flush walks dormant chunks and DONTNEEDs their pages
          # without a lock, so a chunk revived after it read the flag would
          # have the objects allocated into it zeroed silently. The walk flag
          # is set and cleared under the alloc lock; taking it here orders
          # this revive strictly before or after the whole walk. Refused
          # revives fall through to mapping a fresh chunk.
          refused = false
          with_alloc_lock do
            if @live_chunk_walk
              @dormant_revive_during_flush &+= 1
              refused = true
            else
              ChunkHeader.set_dormant(chunk, false)
            end
          end
          return nil if refused
          mapped = chunk.value.mapped_bytes
          @dormant_chunk_bytes -= mapped if @dormant_chunk_bytes >= mapped
          words = chunk.value.bitmap_words.to_i32
          occ = ChunkHeader.occ_bitmap(chunk)
          mark = ChunkHeader.mark_bitmap(chunk)
          i = 0
          while i < words
            occ[i] = 0_u64
            mark[i] = 0_u64
            i += 1
          end
          @bitmap_dormant_revives &+= 1
          return chunk
        end
        chunk = chunk.value.next
      end
      nil
    end

    # Release one block back to `occ`. The bit is shared with 63 others, so the
    # clear is atomic for the same reason the set is.
    # Page-run live mask built from `occ` rather than from block headers.
    #
    # The header walk this replaces asks "is this block FREE?" of every block in
    # the chunk. On a bitmap chunk that question has no answer in the header —
    # the streaming sweep never writes FREE into what it reclaims — so every
    # block reads USED, every page looks live, and **nothing is ever released**.
    # Measured: `page-release-corruption` reporting `released 0 B` against
    # 8.8 MB and 64.5 MB on the default arm, with the harness itself saying a
    # clean result at 0 B proves nothing.
    #
    # Iterating set bits rather than pages, because the loop cost then scales
    # with *live* blocks: a chunk that is mostly garbage — the case where
    # releasing pages is worth anything — walks almost nothing, and a chunk with
    # no free pages to release exits on the first popcount.
    protected def bitmap_page_live_mask(chunk : ChunkHeader*, page : UInt64,
                                        first_page : UInt64) : UInt64
      occ = ChunkHeader.occ_bitmap(chunk)
      return UInt64::MAX if occ.null?
      class_index = chunk.value.size_class.to_i32
      return UInt64::MAX if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      block_bytes = @block_bytes[class_index]
      data_start = ChunkHeader.data_start(chunk).address
      words = chunk.value.bitmap_words.to_i32
      mask = 0_u64
      w = 0
      while w < words
        bits = occ[w]
        while bits != 0_u64
          bit = bits.trailing_zeros_count
          bits &= bits &- 1
          ordinal = (w.to_u64 << 6) &+ bit.to_u64
          b0 = data_start &+ ordinal &* block_bytes
          b1 = b0 &+ block_bytes
          pg = b0 & ~(page - 1)
          while pg < b1
            idx = ((pg &- first_page) // page).to_i32
            mask |= 1_u64 << idx if idx >= 0 && idx < 64
            pg &+= page
          end
        end
        w += 1
      end
      mask
    end

    # Release one block back to `occ` **and** clear its mark.
    #
    # Both, and the mark is the subtle half. An object allocated, marked by the
    # trace, then explicitly freed has `occ=0, mark=1` — and the sweep's
    # `occ = mark` puts it straight back into the allocated set, owned by
    # nothing, while `live_objects` was already decremented by the free.
    # Presented as `live_objects mismatch reported=0 walked=91` in
    # `mt-property-test`, the counter saturating at zero while the bitmap
    # accumulated resurrected blocks.
    #
    # Both clears are atomic for the usual reason: 64 blocks share each word.
    @[AlwaysInline]
    protected def bitmap_free_block(chunk : ChunkHeader*, header : BlockHeader*) : Nil
      occ = ChunkHeader.occ_bitmap(chunk)
      return if occ.null?
      ordinal = chunk_block_ordinal(chunk, header.address)
      word = ordinal >> 6
      clear = ~(1_u64 << (ordinal & 63))
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And, occ + word, clear,
        LLVM::AtomicOrdering::Monotonic, false)
      mark = ChunkHeader.mark_bitmap(chunk)
      return if mark.null?
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And, mark + word, clear,
        LLVM::AtomicOrdering::Monotonic, false)
    end

    # Is a size-class cursor currently on `chunk`?
    #
    # The sweep asks this and, if the chunk is otherwise empty, keeps it mapped
    # for the cycle rather than reclaiming it — a cursor holds a raw
    # `ChunkHeader*` a mutator may be suspended mid-use of.
    #
    # That replaces an earlier design that *dropped* cursors from the sweep, and
    # the reason it had to go is the codebase's oldest recurring bug shape: a
    # mutator can be suspended by STW mid-`bitmap_alloc_locked`, holding the
    # class lock, having read the cached mask but not yet the chunk. The in-STW
    # sweep cannot take that lock (a frozen peer holds it — the 0.21.1
    # `@chunk_list_lock` hang, one lock over), so it nulled the cursor unlocked,
    # and the mutator resumed into `occ_bitmap(null)`: `signal 11 at 0x1c`,
    # `0x1c` being exactly the `bitmap_words` field offset. Proved by
    # instrumentation — every drop that matched a live cursor came from the
    # stopped-world sweep, none from `index_remove`.
    #
    # Pinning closes a second window the drop could not: a mutator frozen
    # *after* its `occ` store but before the block's address exists in any
    # register the root scan can see. That block is `occ=1, mark=0`,
    # unreachable, and `occ &= mark` would free it under the mutator — which
    # then returns a dangling pointer. Under the pin the word is not swept.
    #
    # The header path's answer to the same situation is
    # `uninitialised_small_block?`: a chunk a frozen mutator is mid-writing is
    # called live and the tripwire counts it. This is that rule for cursors.
    #
    # Reading `@pool_chunk` here needs no lock. Under STW the writer is frozen
    # and a single pointer cannot tear; in the after-world sweep this thread
    # already holds the class lock. Cost when it fires: one chunk per class
    # carries its garbage one cycle longer.
    @[AlwaysInline]
    protected def bitmap_cursor_on?(chunk : ChunkHeader*) : Bool
      i = 0
      while i < POOL_SLOTS
        return true if @pool_chunk[i] == chunk
        i += 1
      end
      false
    end
  end
end
