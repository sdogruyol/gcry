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

    # A large object always sits exactly 16 bytes after its header, in **both**
    # builds: with headers in front, that is `BlockHeader::SIZE`; under
    # headerless, the slot reserved in the chunk's metadata region ends where
    # `data_start` begins. Small blocks are the ones whose header disappears, so
    # the generic `from_user`/`user_from` become identity there and must not be
    # used on a large block.
    LARGE_HEADER_BYTES = 16

    def self.large_header_from_user(user : Void*) : BlockHeader*
      (user.as(UInt8*) - LARGE_HEADER_BYTES).as(BlockHeader*)
    end

    def self.large_user_from_header(header : BlockHeader*) : Void*
      (header.as(UInt8*) + LARGE_HEADER_BYTES).as(Void*)
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
      {% if flag?(:gcry_headerless) %}
        # Nothing reads this flag since 7.4 replaced it with the finalizer
        # registry's index, and under headerless a small block has no header —
        # this write would land in the object's own first words.
        return
      {% end %}
      h = header.value
      h.flags |= Flags::FINALIZER
      header.value = h
    end

    def self.set_disappearing(header : BlockHeader*) : Nil
      {% if flag?(:gcry_headerless) %}
        # Nothing reads this flag since 7.4 replaced it with the finalizer
        # registry's index, and under headerless a small block has no header —
        # this write would land in the object's own first words.
        return
      {% end %}
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
      hl_check(header.address, "HL: set_used_large into guarded range\n")
      header.value = new(size, flags & ~Flags::FREE, Pointer(Void).null)
    end

    # Mark accessors for a block that still has a header — i.e. a large block,
    # whose header is reserved in its chunk's metadata region. The unsuffixed
    # `set_mark` / `marked?` are no-ops under headerless because a *small* block
    # has nowhere to keep a mark; routing a large block through them left it
    # permanently unmarked, so every collection swept it while it was live.
    # Debug watchpoint (`-Dgcry_hl_assert`): a range a test declares off-limits.
    # Any large-mark write landing inside it prints a backtrace and exits, which
    # is how a stray writer is identified without a debugger.
    @@hl_guard_lo = 0_u64
    @@hl_guard_hi = 0_u64

    def self.hl_guard(lo : UInt64, hi : UInt64) : Nil
      @@hl_guard_lo = lo
      @@hl_guard_hi = hi
    end

    @[AlwaysInline]
    private def self.hl_check(addr : UInt64, what : String) : Nil
      {% if flag?(:gcry_hl_assert) %}
        if @@hl_guard_hi > 0 && addr >= @@hl_guard_lo && addr < @@hl_guard_hi
          LibC.write(2, what.to_unsafe.as(Void*), LibC::SizeT.new(what.bytesize))
          Exception::CallStack.print_backtrace
          LibC.exit(9)
        end
      {% end %}
    end

    def self.set_mark_large(header : BlockHeader*) : Nil
      hl_check(header.address, "HL: set_mark_large into guarded range\n")
      h = header.value
      h.flags = (h.flags & ~Flags::MARK_GEN_MASK & ~Flags::MARK) |
                (@@mark_gen.to_u32 << Flags::MARK_GEN_SHIFT)
      header.value = h
    end

    def self.marked_large?(header : BlockHeader*) : Bool
      gen = ((header.value.flags & Flags::MARK_GEN_MASK) >> Flags::MARK_GEN_SHIFT).to_u8
      gen == @@mark_gen
    end

    # FREE for a block that still has a header — large blocks, whose header is
    # reserved in the chunk's metadata region and whose FREE flag
    # `cache_large_chunk` writes directly.
    #
    # The unsuffixed `free?` answers `false` under headerless because a small
    # block's occupancy lives in `occ` and cannot be read from the block. Using
    # it on a large block disables `cache_large_chunk`'s double-insert guard,
    # which puts one chunk in a bucket chain twice — and, in that function's own
    # words, "take_large_free then hands the same memory to two owners while
    # trim_large_cache is still free to unmap it under both". It accumulates
    # silently and takes tens of thousands of cycles to surface.
    def self.free_large?(header : BlockHeader*) : Bool
      (header.value.flags & Flags::FREE) != 0
    end

    # ATOMIC for a block that still has a header (large). `set_used_large`
    # writes the flag; the unsuffixed `atomic?` answers false under headerless
    # because a small block's kind lives on its chunk.
    def self.atomic_large?(header : BlockHeader*) : Bool
      (header.value.flags & Flags::ATOMIC) != 0
    end

    def self.clear_mark_large(header : BlockHeader*) : Nil
      hl_check(header.address, "HL: clear_mark_large into guarded range\n")
      h = header.value
      h.flags &= ~Flags::MARK_GEN_MASK
      h.flags &= ~Flags::MARK
      header.value = h
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
      # A large chunk's containment starts at its block header, not at
      # `data_start`. With headers in front the two coincide; under headerless
      # the header is reserved *before* `data_start`, and `scan_object` looks
      # its chunk up by that header address. Starting at `data_start` made
      # that lookup return nil for every large object, so `scan_object`
      # silently returned without scanning it and everything a large object
      # referenced was reclaimed — the Heap's own MarkStack, worker-thread
      # Array and finalizer registry among them. Small chunks are unchanged:
      # their blocks begin at `data_start` and a pointer into the metadata
      # region must still not resolve.
      start = if large?(chunk)
                large_header(chunk).address
              else
                data_start(chunk).address
              end
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
