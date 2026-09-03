require "c/sys/mman"

# The Linux name, on the Darwin targets whose bindings lack it.
#
# Not every Darwin target: Crystal's `x86_64-macosx-darwin` bindings already
# define `MAP_ANONYMOUS`, and defining it again is a hard error — `already
# initialized constant LibC::MAP_ANONYMOUS`, which is what `-Dgc_none` did on
# x86_64 macOS for as long as this shim was unconditional. CI runs
# `macos-latest`, which is Apple Silicon, so the platform this repo claims to
# support was never compiled for it. Found by `make darwin-typecheck`.
{% if flag?(:darwin) && !LibC.has_constant?("MAP_ANONYMOUS") %}
  lib LibC
    MAP_ANONYMOUS = MAP_ANON
  end
{% end %}

module Gcry
  # Header placed immediately before every user allocation.
  #
  # Layout (64-bit): size(4) + flags(4) + next_free(8) = 16 bytes.
  # `next_free` is only meaningful while the block is on a freelist.
  struct BlockHeader
    # Phase 7.7. At 0 the per-block header disappears: `from_user` and
    # `user_from` become identity, and every `@block_bytes` derivation
    # (`SIZE + payload`) collapses to the payload alone, so blocks are carved
    # back-to-back with nothing between them. That is the whole 16-bytes-per-
    # object saving, and it falls out of this constant.
    #
    # It also means a `BlockHeader*` now points at **user data**. Any read of a
    # field through it returns whatever the program stored; any write corrupts
    # the object — its `type_id` lives in the first word. Every accessor below
    # is therefore conditioned on the flag, and the ones that cannot be answered
    # without a chunk are removed rather than left to return garbage.
    {% if flag?(:gcry_headerless) %}
      SIZE = 0
    {% else %}
      SIZE = 16
    {% end %}

    property size : UInt32
    property flags : UInt32
    property next_free : Void*

    def initialize(@size : UInt32, @flags : UInt32, @next_free : Void* = Pointer(Void).null)
    end

    module Flags
      FREE   = 1_u32
      ATOMIC = 2_u32
      # Legacy single-bit MARK (pre mark-gen). Cleared on set/clear; unused for
      # marked? after mark-gen.
      MARK         =  4_u32
      LARGE        =  8_u32
      NURSERY      = 16_u32 # young generation (Phase 6)
      FINALIZER    = 32_u32 # has at least one finalizer entry
      DISAPPEARING = 64_u32 # has at least one disappearing link (WeakRef)
      # Diagnostic, set alongside FREE by the sweep's freelist link and left
      # clear by an explicit `Heap#free`. A use-after-free report can then say
      # *which* path gave the block back — "the collector decided it was
      # garbage" and "the program asked" are different defects with different
      # owners, and the 2026-08-16 hunt spent a round unable to tell them apart.
      # Costs one OR at free time; the bit is otherwise unused (8–15 are the
      # mark generation).
      SWEPT = 128_u32
      # Bits 8–15: mark generation (in-header path). Matches Heap#header_mark_gen /
      # BlockHeader.mark_gen. clear_all_marks bumps gen (O(1)) instead of walking.
      MARK_GEN_SHIFT =          8
      MARK_GEN_MASK  = 0xFF00_u32
    end

    # Process-wide current mark generation for in-header MARK (mirrors active Heap).
    @@mark_gen = 1_u8

    def self.mark_gen : UInt8
      @@mark_gen
    end

    def self.mark_gen=(value : UInt8) : UInt8
      @@mark_gen = value
    end

    def self.from_user(user : Void*) : BlockHeader*
      (user.as(UInt8*) - SIZE).as(BlockHeader*)
    end

    def self.user_from(header : BlockHeader*) : Void*
      (header.as(UInt8*) + SIZE).as(Void*)
    end

    # Occupancy lives in `occ`, not here. A headerless block has no flags word,
    # so this can only be answered with a chunk in hand — `Heap#block_allocated?`
    # is the authority and every live path already prefers it. Answering
    # "not free" is the safe direction for a marker (it never skips a live
    # object); sweep does not consult this at all on a bitmap chunk.
    def self.free?(header : BlockHeader*) : Bool
      {% if flag?(:gcry_headerless) %}
        false
      {% else %}
        (header.value.flags & Flags::FREE) != 0
      {% end %}
    end

    # Moved to the chunk in 7.2 (`ChunkHeader.atomic?`). Callers that still ask
    # the block get `false` under headerless — the conservative answer, since it
    # means "scan it", which is safe if wasteful. Live scan paths take the chunk.
    def self.atomic?(header : BlockHeader*) : Bool
      {% if flag?(:gcry_headerless) %}
        false
      {% else %}
        (header.value.flags & Flags::ATOMIC) != 0
      {% end %}
    end

    # LARGE is a property of the chunk (`ChunkHeader.large?`), and under
    # headerless that is the only place it can be read. Answering from a
    # headerless block would read user data, and a false positive here routes a
    # small object into the large-object free path — `cache_large_chunk` on a
    # size-class chunk, which corrupts the heap.
    def self.large?(header : BlockHeader*) : Bool
      {% if flag?(:gcry_headerless) %}
        false
      {% else %}
        (header.value.flags & Flags::LARGE) != 0
      {% end %}
    end

    def self.nursery?(header : BlockHeader*) : Bool
      {% if flag?(:gcry_headerless) %}
        # Nursery chunks are excluded from bitmap chunks, and headerless
        # requires bitmap_alloc, so no headerless block is ever nursery.
        false
      {% else %}
        (header.value.flags & Flags::NURSERY) != 0
      {% end %}
    end

    def self.marked?(header : BlockHeader*) : Bool
      {% if flag?(:gcry_headerless) %}
        # Unanswerable without a chunk; `Heap#heap_marked?` reads the bitmap.
        # False means "not yet marked", which at worst re-marks — never skips.
        false
      {% else %}
        gen = ((header.value.flags & Flags::MARK_GEN_MASK) >> Flags::MARK_GEN_SHIFT).to_u8
        gen == @@mark_gen
      {% end %}
    end

    def self.set_mark(header : BlockHeader*) : Nil
      {% if flag?(:gcry_headerless) %}
        # The mark lives in the chunk's mark bitmap. Writing here would land on
        # the object's own bytes. `Heap#heap_set_mark` / `heap_marked?` are the
        # only correct entry points; R3 in the plan is exactly this hazard, and
        # under headerless it is fatal rather than merely wrong.
        return
      {% end %}
      h = header.value
      h.flags = (h.flags & ~Flags::MARK_GEN_MASK & ~Flags::MARK) |
                (@@mark_gen.to_u32 << Flags::MARK_GEN_SHIFT)
      header.value = h
    end

    def self.clear_mark(header : BlockHeader*) : Nil
      {% if flag?(:gcry_headerless) %}
        # The mark lives in the chunk's mark bitmap. Writing here would land on
        # the object's own bytes. `Heap#heap_set_mark` / `heap_marked?` are the
        # only correct entry points; R3 in the plan is exactly this hazard, and
        # under headerless it is fatal rather than merely wrong.
        return
      {% end %}
      h = header.value
      h.flags &= ~Flags::MARK_GEN_MASK
      h.flags &= ~Flags::MARK
      header.value = h
    end

    def self.marked_user?(user : Void*) : Bool
      marked?(from_user(user))
    end

    def self.set_mark_user(user : Void*) : Nil
      set_mark(from_user(user))
    end

    def self.clear_mark_user(user : Void*) : Nil
      clear_mark(from_user(user))
    end

    def self.finalizer?(header : BlockHeader*) : Bool
      (header.value.flags & Flags::FINALIZER) != 0
    end

    def self.disappearing?(header : BlockHeader*) : Bool
      (header.value.flags & Flags::DISAPPEARING) != 0
    end

    def self.set_finalizer(header : BlockHeader*) : Nil
      h = header.value
      h.flags |= Flags::FINALIZER
      header.value = h
    end

    def self.set_disappearing(header : BlockHeader*) : Nil
      h = header.value
      h.flags |= Flags::DISAPPEARING
      header.value = h
    end

    def self.promote(header : BlockHeader*) : Nil
      h = header.value
      h.flags &= ~Flags::NURSERY
      header.value = h
    end

    def self.set_free(header : BlockHeader*, next_free : Void*) : Nil
      {% if flag?(:gcry_headerless) %}
        # Freelist-shaped, and the freelist is gone under bitmap_alloc (which
        # headerless requires). Reaching here would corrupt an object.
        return
      {% end %}
      Gcry::ThreadListWatch.check(header.address, SIZE.to_u64 &+ header.value.size, Gcry::ThreadListWatch::SITE_SET_FREE, header.value.flags)
      h = header.value
      h.flags |= Flags::FREE
      h.next_free = next_free
      header.value = h
    end

    # Large blocks keep their header (reserved in the chunk's metadata region),
    # so this always writes. `set_used` is a no-op under headerless because a
    # *small* block has nowhere to write; using it for a large block silently
    # dropped its size and LARGE flag.
    def self.set_used_large(header : BlockHeader*, size : UInt32, flags : UInt32) : Nil
      header.value = new(size, flags & ~Flags::FREE, Pointer(Void).null)
    end

    def self.set_used(header : BlockHeader*, size : UInt32, flags : UInt32) : Nil
      {% if flag?(:gcry_headerless) %}
        # Nothing to write. Occupancy is `occ`, size is the chunk's size class,
        # ATOMIC is the chunk kind (7.2), and the mark bit is the mark bitmap.
        # Writing here would land on the object's own first 16 bytes.
        return
      {% end %}
      if Gcry::ThreadListWatch.check(header.address, SIZE.to_u64 &+ size, Gcry::ThreadListWatch::SITE_SET_USED, header.value.flags)
        # The one caller identity that matters, taken at the corrupting
        # hand-out itself rather than at the crash that follows it. The crash
        # handler's own printer: no allocation, so no reentry into the
        # allocator this runs inside of.
        Exception::CallStack.print_backtrace
      end
      header.value = new(size, flags & ~Flags::FREE, Pointer(Void).null)
    end
  end

  # Header at the start of every mmap'd region (small chunk or large object).
  struct ChunkHeader
    # 24 -> 32 for `data_offset` and `bitmap_words`.
    #
    # Every site that recovers a large chunk from its block does
    # `header - ChunkHeader::SIZE` (heap.cr:1299 and five siblings,
    # collect.cr:1017, collect_sweep.cr:478, :843), and every site that sizes a
    # large mapping does `ChunkHeader::SIZE + BlockHeader::SIZE + payload`
    # (heap.cr:1216). Those stay correct *by construction* because large chunks
    # keep `data_offset == SIZE`: they hold one object and need no bitmap, so
    # their single mark bit lives in `flags`. Only size-class chunks move their
    # data start, and they are never reached by pointer arithmetic on this
    # constant.
    SIZE = 32

    property next : ChunkHeader*   # 0
    property mapped_bytes : UInt64 # 8
    property size_class : UInt32   # 16 — index into SIZE_CLASSES, or UInt32::MAX for large
    property flags : UInt32        # 20
    # Bytes from the chunk base to the first block. `SIZE` for large chunks and
    # for every chunk when the bitmap representation is off; otherwise it also
    # covers the two bitmaps that sit between this header and the first block.
    property data_offset : UInt32 # 24
    # Words in EACH of the `occ` and `mark` bitmaps. Zero when there are none.
    property bitmap_words : UInt32 # 28

    module Flags
      NURSERY = 1_u32
      # Fully free; pages DONTNEED'd; not on freelist until revived.
      DORMANT = 2_u32
      # Some free pages were MADV_DONTNEED'd; freelist must skip those holes.
      HOLED = 4_u32
      # Mostly-empty: queued for post-STW free-page release without HOLED rebuild.
      # Default advice is MADV_FREE (content preserved; freelist stays valid).
      SPARSE = 8_u32
      # Chunk kind: every block in this chunk is atomic (unscanned). Phase 7
      # moves `BlockHeader::Flags::ATOMIC` here, because the header is going
      # away and a *per-block* atomic bitmap would need a store on every
      # allocation to clear the bit a previous occupant set — exactly the
      # "accounting that enables skip is not free on the HTTP alloc path"
      # failure that rejected 2026-08-01-ec4-alloc-bits. A chunk kind is fixed
      # at map time and costs the mutator nothing.
      ATOMIC = 16_u32
    end

    def initialize(@next : ChunkHeader*, @mapped_bytes : UInt64, @size_class : UInt32,
                   @flags : UInt32 = 0_u32, @data_offset : UInt32 = SIZE.to_u32,
                   @bitmap_words : UInt32 = 0_u32)
    end

    def self.base(chunk : ChunkHeader*) : Void*
      chunk.as(Void*)
    end

    def self.data_start(chunk : ChunkHeader*) : Void*
      (chunk.as(UInt8*) + chunk.value.data_offset).as(Void*)
    end

    # `occ` — allocated blocks. Null until Phase 3 gives it a consumer.
    def self.occ_bitmap(chunk : ChunkHeader*) : UInt64*
      return Pointer(UInt64).null if chunk.value.bitmap_words == 0
      (chunk.as(UInt8*) + SIZE).as(UInt64*)
    end

    # `mark` — reachable blocks, authoritative when the bitmap representation
    # is on. Sits immediately after `occ`, so one chunk's metadata is one
    # contiguous run and the sweep streams both together.
    def self.mark_bitmap(chunk : ChunkHeader*) : UInt64*
      words = chunk.value.bitmap_words
      return Pointer(UInt64).null if words == 0
      (chunk.as(UInt8*) + SIZE).as(UInt64*) + words
    end

    def self.data_end(chunk : ChunkHeader*) : Void*
      (chunk.as(UInt8*) + chunk.value.mapped_bytes).as(Void*)
    end

    def self.contains?(chunk : ChunkHeader*, addr : UInt64) : Bool
      start = data_start(chunk).address
      finish = chunk.address + chunk.value.mapped_bytes
      addr >= start && addr < finish
    end

    def self.large?(chunk : ChunkHeader*) : Bool
      chunk.value.size_class == UInt32::MAX
    end

    # Chunk kind (Phase 7): every block here is atomic/unscanned.
    def self.atomic?(chunk : ChunkHeader*) : Bool
      (chunk.value.flags & Flags::ATOMIC) != 0
    end

    # The single block header of a large chunk.
    #
    # With headers in front of the object this is just `data_start`. Under
    # headerless the object starts at `data_start` and its header is reserved
    # before it, inside the metadata region — so the two differ and every large
    # path must ask for it by name rather than assume `data_start` is a header.
    # Bytes from a large chunk's base to its object. Single definition so
    # sizing, carving and the header slot cannot drift apart.
    def self.large_data_offset : Int32
      {% if flag?(:gcry_headerless) %}
        ChunkHeader::SIZE + 16
      {% else %}
        ChunkHeader::SIZE + BlockHeader::SIZE
      {% end %}
    end

    def self.large_header(chunk : ChunkHeader*) : BlockHeader*
      {% if flag?(:gcry_headerless) %}
        (chunk.as(UInt8*) + ChunkHeader::SIZE).as(BlockHeader*)
      {% else %}
        data_start(chunk).as(BlockHeader*)
      {% end %}
    end

    # The user pointer of a large chunk's single object.
    def self.large_user(chunk : ChunkHeader*) : Void*
      {% if flag?(:gcry_headerless) %}
        data_start(chunk)
      {% else %}
        (data_start(chunk).as(UInt8*) + BlockHeader::SIZE).as(Void*)
      {% end %}
    end

    def self.nursery?(chunk : ChunkHeader*) : Bool
      (chunk.value.flags & Flags::NURSERY) != 0
    end

    def self.dormant?(chunk : ChunkHeader*) : Bool
      (chunk.value.flags & Flags::DORMANT) != 0
    end

    def self.set_dormant(chunk : ChunkHeader*, value : Bool) : Nil
      h = chunk.value
      if value
        h.flags |= Flags::DORMANT
      else
        h.flags &= ~Flags::DORMANT
      end
      chunk.value = h
    end

    def self.holed?(chunk : ChunkHeader*) : Bool
      (chunk.value.flags & Flags::HOLED) != 0
    end

    def self.set_holed(chunk : ChunkHeader*, value : Bool) : Nil
      h = chunk.value
      if value
        h.flags |= Flags::HOLED
      else
        h.flags &= ~Flags::HOLED
      end
      chunk.value = h
    end

    def self.sparse?(chunk : ChunkHeader*) : Bool
      (chunk.value.flags & Flags::SPARSE) != 0
    end

    def self.set_sparse(chunk : ChunkHeader*, value : Bool) : Nil
      h = chunk.value
      if value
        h.flags |= Flags::SPARSE
      else
        h.flags &= ~Flags::SPARSE
      end
      chunk.value = h
    end
  end

  class OutOfMemoryError < Exception
  end

  # Avoid `LibC::MAP_FAILED`: its Crystal const initializer uses `once`, which
  # needs Fiber, but `GC.init` (and thus our first mmap) runs before Fiber.init.
  def self.mmap_failed?(ptr : Void*) : Bool
    ptr.null? || ptr.address == UInt64::MAX
  end
end
