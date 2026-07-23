require "c/sys/mman"

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
      FREE    = 1_u32
      ATOMIC  = 2_u32
      MARK    = 4_u32
      LARGE   = 8_u32
      NURSERY = 16_u32 # young generation (Phase 6)
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

    def self.marked?(header : BlockHeader*) : Bool
      (header.value.flags & Flags::MARK) != 0
    end

    def self.set_mark(header : BlockHeader*) : Nil
      h = header.value
      h.flags |= Flags::MARK
      header.value = h
    end

    def self.clear_mark(header : BlockHeader*) : Nil
      h = header.value
      h.flags &= ~Flags::MARK
      header.value = h
    end

    def self.promote(header : BlockHeader*) : Nil
      h = header.value
      h.flags &= ~Flags::NURSERY
      header.value = h
    end

    def self.set_free(header : BlockHeader*, next_free : Void*) : Nil
      h = header.value
      h.flags |= Flags::FREE
      h.next_free = next_free
      header.value = h
    end

    def self.set_used(header : BlockHeader*, size : UInt32, flags : UInt32) : Nil
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
  end

  class OutOfMemoryError < Exception
  end

  # Avoid `LibC::MAP_FAILED`: its Crystal const initializer uses `once`, which
  # needs Fiber, but `GC.init` (and thus our first mmap) runs before Fiber.init.
  def self.mmap_failed?(ptr : Void*) : Bool
    ptr.null? || ptr.address == UInt64::MAX
  end
end
