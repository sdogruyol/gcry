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
    SIZE = 16

    property size : UInt32
    property flags : UInt32
    property next_free : Void*

    def initialize(@size : UInt32, @flags : UInt32, @next_free : Void* = Pointer(Void).null)
    end

    module Flags
      FREE   = 1_u32
      ATOMIC = 2_u32
      # Legacy single-bit MARK (pre mark-gen). Cleared on set/clear; unused for
      # marked? after mark-gen. Side bitmap path (`-Dgcry_side_bitmap`) ignores
      # header mark bits entirely.
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

    def self.free?(header : BlockHeader*) : Bool
      (header.value.flags & Flags::FREE) != 0
    end

    def self.atomic?(header : BlockHeader*) : Bool
      (header.value.flags & Flags::ATOMIC) != 0
    end

    def self.large?(header : BlockHeader*) : Bool
      (header.value.flags & Flags::LARGE) != 0
    end

    def self.nursery?(header : BlockHeader*) : Bool
      (header.value.flags & Flags::NURSERY) != 0
    end

    {% unless flag?(:gcry_side_bitmap) %}
      def self.marked?(header : BlockHeader*) : Bool
        gen = ((header.value.flags & Flags::MARK_GEN_MASK) >> Flags::MARK_GEN_SHIFT).to_u8
        gen == @@mark_gen
      end

      def self.set_mark(header : BlockHeader*) : Nil
        h = header.value
        h.flags = (h.flags & ~Flags::MARK_GEN_MASK & ~Flags::MARK) |
                  (@@mark_gen.to_u32 << Flags::MARK_GEN_SHIFT)
        header.value = h
      end

      def self.clear_mark(header : BlockHeader*) : Nil
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
    {% else %}
      # Side MarkBitmap is authoritative (`-Dgcry_side_bitmap`; see mark_bitmap.cr).
      def self.marked?(header : BlockHeader*) : Bool
        bm = Gcry.current_mark_bitmap
        return false unless bm
        bm.marked?(user_from(header).address)
      end

      def self.set_mark(header : BlockHeader*) : Nil
        bm = Gcry.current_mark_bitmap
        return unless bm
        bm.set(user_from(header).address)
      end

      def self.clear_mark(header : BlockHeader*) : Nil
        bm = Gcry.current_mark_bitmap
        return unless bm
        bm.clear(user_from(header).address)
      end

      def self.marked_user?(user : Void*) : Bool
        bm = Gcry.current_mark_bitmap
        return false unless bm
        bm.marked?(user.address)
      end

      def self.set_mark_user(user : Void*) : Nil
        bm = Gcry.current_mark_bitmap
        return unless bm
        bm.set(user.address)
      end

      def self.clear_mark_user(user : Void*) : Nil
        bm = Gcry.current_mark_bitmap
        return unless bm
        bm.clear(user.address)
      end
    {% end %}

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
      Gcry::ThreadListWatch.check(header.address, SIZE.to_u64 &+ header.value.size, Gcry::ThreadListWatch::SITE_SET_FREE, header.value.flags)
      h = header.value
      h.flags |= Flags::FREE
      h.next_free = next_free
      header.value = h
    end

    def self.set_used(header : BlockHeader*, size : UInt32, flags : UInt32) : Nil
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
    SIZE = 24

    property next : ChunkHeader*
    property mapped_bytes : UInt64
    property size_class : UInt32 # index into SIZE_CLASSES, or UInt32::MAX for large
    property flags : UInt32

    module Flags
      NURSERY = 1_u32
      # Fully free; pages DONTNEED'd; not on freelist until revived.
      DORMANT = 2_u32
      # Some free pages were MADV_DONTNEED'd; freelist must skip those holes.
      HOLED = 4_u32
      # Mostly-empty: queued for post-STW free-page release without HOLED rebuild.
      # Default advice is MADV_FREE (content preserved; freelist stays valid).
      SPARSE = 8_u32
    end

    def initialize(@next : ChunkHeader*, @mapped_bytes : UInt64, @size_class : UInt32, @flags : UInt32 = 0_u32)
    end

    def self.base(chunk : ChunkHeader*) : Void*
      chunk.as(Void*)
    end

    def self.data_start(chunk : ChunkHeader*) : Void*
      (chunk.as(UInt8*) + SIZE).as(Void*)
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

  # The currently active side MarkBitmap. There is at most one bitmap per
  # process; library heaps that pre-date `@@mark_bitmap` initialization will
  # see `nil` here and the mark helpers degrade to no-ops (the legacy in-header
  # MARK flag path is gone; the bitmap is the sole authority).
  #
  # Note: not Atomic. Crystal reference types are always read through a GC-managed
  # pointer; without one (we are not on the GC heap here), tearing isn't the
  # issue — the issue is concurrent destroy. The MarkBitmap#destroy path now
  # nulls `@base` BEFORE the unmap, so any reader that already observed a
  # non-nil base continues to dereference a still-mapped page (until the unmap
  # completes). Together with the `current_mark_bitmap = nil` clear in
  # Heap#destroy, this closes the use-after-free window for library heaps.
  @@mark_bitmap : MarkBitmap? = nil

  def self.current_mark_bitmap : MarkBitmap?
    @@mark_bitmap
  end

  def self.current_mark_bitmap=(bitmap : MarkBitmap?) : MarkBitmap?
    @@mark_bitmap = bitmap
  end
end
