require "./block"

module Gcry
  # Payload sizes (bytes). Requests are rounded up to the next class.
  SIZE_CLASSES = [
    16_u32, 32_u32, 48_u32, 64_u32, 80_u32, 96_u32, 112_u32, 128_u32,
    160_u32, 192_u32, 224_u32, 256_u32, 320_u32, 384_u32, 448_u32, 512_u32,
    640_u32, 768_u32, 896_u32, 1024_u32, 1280_u32, 1536_u32, 1792_u32, 2048_u32,
    2560_u32, 3072_u32, 3584_u32, 4096_u32, 5120_u32, 6144_u32, 7168_u32, 8192_u32,
  ]

  SIZE_CLASS_COUNT = 32
  LARGE_THRESHOLD  = 8192_u32

  # mmap-backed allocator with size classes and conservative mark–sweep.
  #
  # The Heap *object* may live on Crystal's GC during unit tests. Mapped
  # chunks and freelist links live outside the managed heap so this can later
  # become the process GC under `-Dgc_none`.
  class Heap
    SMALL_CHUNK_BYTES = 256_u64 * 1024_u64
    WORD_SIZE         = sizeof(Void*).to_u32

    getter heap_size : UInt64 = 0_u64
    getter free_bytes : UInt64 = 0_u64
    getter total_bytes : UInt64 = 0_u64
    getter bytes_since_gc : UInt64 = 0_u64
    getter live_objects : UInt64 = 0_u64

    @chunks : ChunkHeader* = Pointer(ChunkHeader).null
    @freelists = uninitialized StaticArray(Void*, SIZE_CLASS_COUNT)
    @destroyed = false

    def initialize
      @freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
    end

    def finalize
      destroy
    end

    # Release all mapped memory. Safe to call multiple times.
    def destroy : Nil
      return if @destroyed
      @destroyed = true

      chunk = @chunks
      while chunk
        nxt = chunk.value.next
        LibC.munmap(chunk.as(Void*), LibC::SizeT.new(chunk.value.mapped_bytes))
        chunk = nxt
      end

      @chunks = Pointer(ChunkHeader).null
      @freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
      @heap_size = 0_u64
      @free_bytes = 0_u64
      @live_objects = 0_u64
      destroy_collector
    end

    def malloc(size : Int) : Void*
      allocate(size.to_u64, atomic: false, clear: true)
    end

    def malloc_atomic(size : Int) : Void*
      allocate(size.to_u64, atomic: true, clear: false)
    end

    def realloc(pointer : Void*, size : Int) : Void*
      new_size = size.to_u64
      return malloc(new_size) if pointer.null?

      header = BlockHeader.from_user(pointer)
      raise ArgumentError.new("pointer is not a gcry allocation") unless owns_user_pointer?(pointer, header)

      old_size = header.value.size.to_u64
      atomic = BlockHeader.atomic?(header)

      if new_size == 0
        free(pointer)
        return malloc(0)
      end

      return pointer if new_size <= old_size

      fresh = allocate(new_size, atomic: atomic, clear: !atomic)
      fresh.as(UInt8*).copy_from(pointer.as(UInt8*), old_size)
      free(pointer)
      fresh
    end

    def free(pointer : Void*) : Nil
      return if pointer.null?

      header = BlockHeader.from_user(pointer)
      raise ArgumentError.new("pointer is not a gcry allocation") unless owns_user_pointer?(pointer, header)
      raise ArgumentError.new("double free") if BlockHeader.free?(header)

      payload = header.value.size.to_u64

      if BlockHeader.large?(header)
        chunk = chunk_for(pointer)
        raise ArgumentError.new("large object chunk missing") unless chunk

        unlink_chunk(chunk)
        @heap_size -= chunk.value.mapped_bytes
        update_heap_bounds_after_unmap
        @bytes_since_gc = @bytes_since_gc > payload ? @bytes_since_gc - payload : 0_u64
        @live_objects -= 1 if @live_objects > 0
        LibC.munmap(chunk.as(Void*), LibC::SizeT.new(chunk.value.mapped_bytes))
        return
      end

      class_index = size_class_index(header.value.size)
      header.value = BlockHeader.new(header.value.size, BlockHeader::Flags::FREE, @freelists[class_index])
      @freelists[class_index] = pointer

      @free_bytes += payload
      @bytes_since_gc = @bytes_since_gc > payload ? @bytes_since_gc - payload : 0_u64
      @live_objects -= 1 if @live_objects > 0
    end

    def is_heap_ptr(pointer : Void*) : Bool
      return false if pointer.null?
      addr = pointer.address
      each_chunk do |chunk|
        return true if ChunkHeader.contains?(chunk, addr)
      end
      false
    end

    def self.round_size(size : UInt64) : UInt64
      return SIZE_CLASSES[0].to_u64 if size == 0
      aligned = align_up(size, WORD_SIZE.to_u64)
      return aligned if aligned > LARGE_THRESHOLD

      SIZE_CLASSES.each do |klass|
        return klass.to_u64 if aligned <= klass
      end
      aligned
    end

    def self.size_class_index(payload : UInt32) : Int32
      SIZE_CLASSES.each_with_index do |klass, index|
        return index if payload == klass
      end
      raise ArgumentError.new("not a size-class payload: #{payload}")
    end

    private def allocate(size : UInt64, atomic : Bool, clear : Bool) : Void*
      raise OutOfMemoryError.new("heap destroyed") if @destroyed

      maybe_collect

      rounded = self.class.round_size(size)
      flags = atomic ? BlockHeader::Flags::ATOMIC : 0_u32

      user = if rounded > LARGE_THRESHOLD
               alloc_large(rounded, flags)
             else
               alloc_small(rounded.to_u32, flags)
             end

      user.as(UInt8*).clear(rounded) if clear
      @total_bytes += rounded
      @bytes_since_gc += rounded
      @live_objects += 1
      user
    end

    private def alloc_small(payload : UInt32, flags : UInt32) : Void*
      index = size_class_index(payload)
      user = @freelists[index]

      if user.null?
        refill_size_class(index, payload)
        user = @freelists[index]
        raise OutOfMemoryError.new("failed to refill size class #{payload}") if user.null?
      end

      header = BlockHeader.from_user(user)
      next_free = header.value.next_free
      @freelists[index] = next_free
      BlockHeader.set_used(header, payload, flags)

      @free_bytes -= payload if @free_bytes >= payload
      user
    end

    private def refill_size_class(index : Int32, payload : UInt32) : Nil
      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      chunk = map_chunk(SMALL_CHUNK_BYTES, index.to_u32)
      cursor = ChunkHeader.data_start(chunk).as(UInt8*)
      limit = ChunkHeader.data_end(chunk).as(UInt8*)

      free_head = Pointer(Void).null
      added = 0_u64

      while (cursor + block_bytes) <= limit
        header = cursor.as(BlockHeader*)
        user = (cursor + BlockHeader::SIZE).as(Void*)
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, free_head)
        free_head = user
        cursor += block_bytes
        added += payload
      end

      @freelists[index] = free_head
      @free_bytes += added
    end

    private def alloc_large(payload : UInt64, flags : UInt32) : Void*
      need = ChunkHeader::SIZE.to_u64 + BlockHeader::SIZE.to_u64 + payload
      mapped = align_up(need, 4096_u64)
      chunk = map_chunk(mapped, UInt32::MAX)

      header = ChunkHeader.data_start(chunk).as(BlockHeader*)
      BlockHeader.set_used(header, payload.to_u32!, flags | BlockHeader::Flags::LARGE)
      BlockHeader.user_from(header)
    end

    private def map_chunk(bytes : UInt64, size_class : UInt32) : ChunkHeader*
      ptr = LibC.mmap(
        Pointer(Void).null,
        LibC::SizeT.new(bytes),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS,
        -1,
        0
      )
      raise OutOfMemoryError.new("mmap failed") if ptr == LibC::MAP_FAILED || ptr.null?

      chunk = ptr.as(ChunkHeader*)
      chunk.value = ChunkHeader.new(@chunks, bytes, size_class)
      @chunks = chunk
      @heap_size += bytes
      note_mapped(chunk)
      chunk
    end

    protected def unlink_chunk(target : ChunkHeader*) : Nil
      if @chunks == target
        @chunks = target.value.next
        return
      end

      prev = @chunks
      while prev
        if prev.value.next == target
          node = prev.value
          node.next = target.value.next
          prev.value = node
          return
        end
        prev = prev.value.next
      end
    end

    protected def each_chunk(& : ChunkHeader* ->) : Nil
      chunk = @chunks
      while chunk
        yield chunk
        chunk = chunk.value.next
      end
    end

    private def chunk_for(user : Void*) : ChunkHeader*?
      addr = user.address
      each_chunk do |chunk|
        return chunk if ChunkHeader.contains?(chunk, addr)
      end
      nil
    end

    private def owns_user_pointer?(user : Void*, header : BlockHeader*) : Bool
      return false unless is_heap_ptr(user)
      chunk = chunk_for(user)
      return false unless chunk
      header.address >= ChunkHeader.data_start(chunk).address &&
        header.address < ChunkHeader.data_end(chunk).address
    end

    private def size_class_index(payload : UInt32) : Int32
      self.class.size_class_index(payload)
    end

    def self.align_up(value : UInt64, align : UInt64) : UInt64
      (value + align - 1) & ~(align - 1)
    end

    private def align_up(value : UInt64, align : UInt64) : UInt64
      self.class.align_up(value, align)
    end
  end
end

require "./collect"
