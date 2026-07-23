require "./block"
require "./size_classes"

module Gcry
  # mmap-backed allocator with size classes and conservative mark–sweep.
  #
  # The Heap *object* may live on Crystal's GC during unit tests. Mapped
  # chunks and freelist links live outside the managed heap so this can later
  # become the process GC under `-Dgc_none`.
  class Heap
    SMALL_CHUNK_BYTES = 262144_u64 # 256 KiB — 512 KiB regressed /json vs Boehm
    PAUSE_RING_SIZE   =         64 # recent pause samples for p50/p99
    # Power-of-two buckets for recycled large mappings (avoid munmap during STW).
    LARGE_FREE_BUCKETS = 20
    # Soft cap on cached free large bytes; trim retains at most half by default.
    LARGE_CACHE_LIMIT = 64_u64 * 1024 * 1024
    # Bytes of free large mappings to keep after trim (process default; override via GCRY_LARGE_CACHE).
    DEFAULT_LARGE_CACHE_RETAIN = LARGE_CACHE_LIMIT // 2

    getter heap_size : UInt64 = 0_u64
    getter free_bytes : UInt64 = 0_u64
    getter total_bytes : UInt64 = 0_u64
    getter bytes_since_gc : UInt64 = 0_u64
    getter live_objects : UInt64 = 0_u64
    getter large_free_bytes : UInt64 = 0_u64
    # Sum of large-chunk mapped_bytes (live + free on freelist).
    getter large_mapped_bytes : UInt64 = 0_u64
    # Retain this many free large bytes after trim_large_cache (outside STW).
    property large_cache_retain : UInt64 = DEFAULT_LARGE_CACHE_RETAIN

    @chunks : ChunkHeader* = Pointer(ChunkHeader).null
    @freelists = uninitialized StaticArray(Void*, SIZE_CLASS_COUNT)
    @nursery_freelists = uninitialized StaticArray(Void*, SIZE_CLASS_COUNT)
    # True while freelist blocks are still MAP_ANONYMOUS-zeroed (skip malloc clear).
    @freelist_clean = uninitialized StaticArray(Bool, SIZE_CLASS_COUNT)
    @nursery_freelist_clean = uninitialized StaticArray(Bool, SIZE_CLASS_COUNT)
    @large_freelists = uninitialized StaticArray(Void*, LARGE_FREE_BUCKETS)
    @block_bytes = uninitialized StaticArray(UInt64, SIZE_CLASS_COUNT)
    @destroyed = false
    @nursery_alloc_bytes : UInt64 = 0_u64
    # Lazily rebuilt address-sorted index (mark / static exclusion).
    @chunk_index : ChunkHeader** = Pointer(ChunkHeader*).null
    @chunk_index_count = 0
    @chunk_index_cap = 0
    # When true, index is stale and must be rebuilt from @chunks (fallback).
    # Normal map/unmap maintains the sorted index incrementally.
    @chunk_index_dirty = false
    @pause_ring = uninitialized StaticArray(UInt64, PAUSE_RING_SIZE)
    @pause_ring_len = 0
    @pause_ring_pos = 0

    def initialize
      @freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
      @nursery_freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
      @freelist_clean = StaticArray(Bool, SIZE_CLASS_COUNT).new(false)
      @nursery_freelist_clean = StaticArray(Bool, SIZE_CLASS_COUNT).new(false)
      @large_freelists = StaticArray(Void*, LARGE_FREE_BUCKETS).new(Pointer(Void).null)
      @pause_ring = StaticArray(UInt64, PAUSE_RING_SIZE).new(0_u64)
      @block_bytes = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      SIZE_CLASS_COUNT.times do |i|
        @block_bytes[i] = BlockHeader::SIZE.to_u64 + SizeClasses.payload(i).to_u64
      end
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
      @nursery_freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
      @freelist_clean = StaticArray(Bool, SIZE_CLASS_COUNT).new(false)
      @nursery_freelist_clean = StaticArray(Bool, SIZE_CLASS_COUNT).new(false)
      @large_freelists = StaticArray(Void*, LARGE_FREE_BUCKETS).new(Pointer(Void).null)
      @heap_size = 0_u64
      @free_bytes = 0_u64
      @large_free_bytes = 0_u64
      @large_mapped_bytes = 0_u64
      @live_objects = 0_u64
      @nursery_alloc_bytes = 0_u64
      unless @chunk_index.null?
        LibC.free(@chunk_index.as(Void*))
        @chunk_index = Pointer(ChunkHeader*).null
      end
      @chunk_index_count = 0
      @chunk_index_cap = 0
      @chunk_index_dirty = false
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

      if BlockHeader.large?(header)
        payload = header.value.size.to_u64
        chunk = chunk_for(pointer)
        raise ArgumentError.new("large object chunk missing") unless chunk

        @bytes_since_gc = @bytes_since_gc > payload ? @bytes_since_gc - payload : 0_u64
        note_explicit_free(payload)
        @live_objects -= 1 if @live_objects > 0
        @finalizers.notice_reclaim(pointer)
        cache_large_chunk(chunk, header)
        trim_large_cache
        return
      end

      chunk = chunk_for(pointer)
      raise ArgumentError.new("pointer is not a gcry allocation") unless chunk

      class_index = chunk.value.size_class.to_i32
      raise ArgumentError.new("bad size class on chunk") if class_index < 0 || class_index >= SIZE_CLASS_COUNT
      payload = SizeClasses.payload(class_index)

      @finalizers.notice_reclaim(pointer)

      if BlockHeader.nursery?(header)
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, @nursery_freelists[class_index])
        @nursery_freelists[class_index] = pointer
        @nursery_freelist_clean[class_index] = false
      else
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, @freelists[class_index])
        @freelists[class_index] = pointer
        @freelist_clean[class_index] = false
      end

      @free_bytes += payload.to_u64
      @bytes_since_gc = @bytes_since_gc > payload ? @bytes_since_gc - payload : 0_u64
      note_explicit_free(payload.to_u64)
      @live_objects -= 1 if @live_objects > 0
    end

    def is_heap_ptr(pointer : Void*) : Bool
      return false if pointer.null?
      !chunk_containing(pointer.address).nil?
    end

    def self.round_size(size : UInt64) : UInt64
      SizeClasses.round(size)
    end

    def self.size_class_index(payload : UInt32) : Int32
      SizeClasses.index_of(payload)
    end

    private def allocate(size : UInt64, atomic : Bool, clear : Bool) : Void*
      raise OutOfMemoryError.new("heap destroyed") if @destroyed

      maybe_collect

      rounded, class_index = SizeClasses.fit(size)
      flags = atomic ? BlockHeader::Flags::ATOMIC : 0_u32

      # Skip memset when memory is still MAP_ANONYMOUS-zeroed (fresh chunk /
      # fresh large mmap). Freelist reuse / large-cache hits still clear.
      # Check clean *after* alloc — refill may have just marked the freelist clean.
      user = Pointer(Void).null
      needs_clear = clear
      if class_index < 0
        user, from_cache = alloc_large(rounded, flags)
        needs_clear = clear && from_cache
      elsif @nursery_enabled
        user = alloc_nursery(rounded.to_u32, flags | BlockHeader::Flags::NURSERY, class_index)
        needs_clear = clear && !@nursery_freelist_clean[class_index]
      else
        user = alloc_old_small(rounded.to_u32, flags, class_index)
        needs_clear = clear && !@freelist_clean[class_index]
      end

      user.as(UInt8*).clear(rounded) if needs_clear
      @total_bytes += rounded
      @bytes_since_gc += rounded
      @live_objects += 1
      user
    end

    private def alloc_nursery(payload : UInt32, flags : UInt32, index : Int32) : Void*
      user = @nursery_freelists[index]

      if user.null?
        refill_size_class(index, payload, nursery: true)
        user = @nursery_freelists[index]
        raise OutOfMemoryError.new("failed to refill nursery size class #{payload}") if user.null?
      end

      header = BlockHeader.from_user(user)
      next_free = header.value.next_free
      @nursery_freelists[index] = next_free
      BlockHeader.set_used(header, payload, flags)
      # Allocate black during any in-progress collection (STW or incremental)
      # so mid-collect allocations are not swept.
      if @incremental_marking || @collecting
        BlockHeader.set_mark(header)
      end

      @free_bytes -= payload if @free_bytes >= payload
      @nursery_alloc_bytes += payload.to_u64
      user
    end

    private def alloc_old_small(payload : UInt32, flags : UInt32, index : Int32) : Void*
      user = @freelists[index]

      if user.null?
        refill_size_class(index, payload, nursery: false)
        user = @freelists[index]
        raise OutOfMemoryError.new("failed to refill size class #{payload}") if user.null?
      end

      header = BlockHeader.from_user(user)
      next_free = header.value.next_free
      @freelists[index] = next_free
      BlockHeader.set_used(header, payload, flags)
      BlockHeader.set_mark(header) if @incremental_marking || @collecting

      @free_bytes -= payload if @free_bytes >= payload
      user
    end

    private def refill_size_class(index : Int32, payload : UInt32, nursery : Bool = false) : Nil
      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      chunk_flags = nursery ? ChunkHeader::Flags::NURSERY : 0_u32
      chunk = map_chunk(SMALL_CHUNK_BYTES, index.to_u32, chunk_flags)
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

      if nursery
        @nursery_freelists[index] = free_head
        @nursery_freelist_clean[index] = true
      else
        @freelists[index] = free_head
        @freelist_clean[index] = true
      end
      @free_bytes += added
    end

    # Returns {user, from_cache}. Fresh mmap pages are already zeroed.
    private def alloc_large(payload : UInt64, flags : UInt32) : {Void*, Bool}
      need = ChunkHeader::SIZE.to_u64 + BlockHeader::SIZE.to_u64 + payload
      mapped = align_up(need, 4096_u64)

      if user = take_large_free(mapped)
        header = BlockHeader.from_user(user)
        BlockHeader.set_used(header, payload.to_u32!, flags | BlockHeader::Flags::LARGE)
        BlockHeader.set_mark(header) if @incremental_marking || @collecting
        return {user, true}
      end

      chunk = map_chunk(mapped, UInt32::MAX, 0_u32)
      header = ChunkHeader.data_start(chunk).as(BlockHeader*)
      BlockHeader.set_used(header, payload.to_u32!, flags | BlockHeader::Flags::LARGE)
      BlockHeader.set_mark(header) if @incremental_marking || @collecting
      {BlockHeader.user_from(header), false}
    end

    # Bucket index for a mapped large-object size (powers of two from 8 KiB).
    protected def self.large_bucket(mapped : UInt64) : Int32
      v = mapped >> 13 # 8 KiB units
      v = 1_u64 if v == 0
      i = 0
      while v > 1 && i < LARGE_FREE_BUCKETS - 1
        v >>= 1
        i += 1
      end
      i
    end

    # Recycle a large chunk (stays mapped, stays on @chunks). No munmap.
    protected def cache_large_chunk(chunk : ChunkHeader*, header : BlockHeader*) : Nil
      mapped = chunk.value.mapped_bytes
      payload = header.value.size
      bucket = self.class.large_bucket(mapped)
      user = BlockHeader.user_from(header)
      header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE | BlockHeader::Flags::LARGE, @large_freelists[bucket])
      @large_freelists[bucket] = user
      @free_bytes += mapped
      @large_free_bytes += mapped
    end

    # Exact mapped-size match only — never reuse a fatter VMA for a smaller need
    # (that pinned live RSS for the oversized mapping until the object died).
    private def take_large_free(mapped_need : UInt64) : Void*?
      b = self.class.large_bucket(mapped_need)
      prev = Pointer(Void).null
      user = @large_freelists[b]
      while user
        header = BlockHeader.from_user(user)
        chunk = (header.as(UInt8*) - ChunkHeader::SIZE).as(ChunkHeader*)
        nxt = header.value.next_free
        if chunk.value.mapped_bytes == mapped_need
          if prev.null?
            @large_freelists[b] = nxt
          else
            ph = BlockHeader.from_user(prev)
            pv = ph.value
            pv.next_free = nxt
            ph.value = pv
          end
          mapped = chunk.value.mapped_bytes
          @free_bytes -= mapped if @free_bytes >= mapped
          @large_free_bytes -= mapped if @large_free_bytes >= mapped
          return user
        end
        prev = user
        user = nxt
      end
      nil
    end

    # Munmap cached large objects until @large_free_bytes <= *limit*.
    # Call outside STW — munmap of many VMAs is slow on Linux.
    def trim_large_cache(limit : UInt64 = @large_cache_retain) : Nil
      return if @large_free_bytes <= limit

      b = LARGE_FREE_BUCKETS - 1
      while b >= 0 && @large_free_bytes > limit
        user = @large_freelists[b]
        while user && @large_free_bytes > limit
          header = BlockHeader.from_user(user)
          chunk = (header.as(UInt8*) - ChunkHeader::SIZE).as(ChunkHeader*)
          nxt = header.value.next_free
          @large_freelists[b] = nxt
          mapped = chunk.value.mapped_bytes
          unlink_chunk(chunk)
          @heap_size -= mapped if @heap_size >= mapped
          @free_bytes -= mapped if @free_bytes >= mapped
          @large_free_bytes -= mapped if @large_free_bytes >= mapped
          @large_mapped_bytes -= mapped if @large_mapped_bytes >= mapped
          @unmapped_bytes += mapped
          LibC.munmap(chunk.as(Void*), LibC::SizeT.new(mapped))
          user = nxt
        end
        b -= 1
      end
      update_heap_bounds_after_unmap
    end

    # Size-class mapped bytes (heap_size minus large VMAs).
    def small_mapped_bytes : UInt64
      @heap_size >= @large_mapped_bytes ? @heap_size - @large_mapped_bytes : 0_u64
    end

    # Freelist bytes in size-class chunks (excludes large freelist).
    def small_free_bytes : UInt64
      @free_bytes >= @large_free_bytes ? @free_bytes - @large_free_bytes : 0_u64
    end

    private def map_chunk(bytes : UInt64, size_class : UInt32, flags : UInt32 = 0_u32) : ChunkHeader*
      ptr = mmap_anonymous(bytes)

      # One emergency collect may free large objects (munmap) before failing hard.
      if Gcry.mmap_failed?(ptr) && !@collecting && @enabled
        collect(scan_stack: true)
        ptr = mmap_anonymous(bytes)
      end

      raise OutOfMemoryError.new("mmap failed") if Gcry.mmap_failed?(ptr)

      chunk = ptr.as(ChunkHeader*)
      chunk.value = ChunkHeader.new(@chunks, bytes, size_class, flags)
      @chunks = chunk
      @heap_size += bytes
      @large_mapped_bytes += bytes if size_class == UInt32::MAX
      index_insert(chunk)
      note_mapped(chunk)
      chunk
    end

    private def mmap_anonymous(bytes : UInt64) : Void*
      LibC.mmap(
        Pointer(Void).null,
        LibC::SizeT.new(bytes),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS,
        -1,
        0
      )
    end

    protected def unlink_chunk(target : ChunkHeader*) : Nil
      index_remove(target)
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

    # Binary search over address-sorted chunk index.
    protected def chunk_containing(addr : UInt64) : ChunkHeader*?
      return nil if @heap_max == 0 || addr < @heap_min || addr >= @heap_max
      ensure_chunk_index

      lo = 0
      hi = @chunk_index_count
      while lo < hi
        mid = lo + (hi - lo) // 2
        chunk = (@chunk_index + mid).value
        base = chunk.address
        finish = base + chunk.value.mapped_bytes
        if addr < base
          hi = mid
        elsif addr >= finish
          lo = mid + 1
        else
          return chunk if ChunkHeader.contains?(chunk, addr)
          return nil
        end
      end
      nil
    end

    # Fallback full rebuild when the incremental index is marked dirty.
    protected def ensure_chunk_index : Nil
      return unless @chunk_index_dirty

      count = 0
      each_chunk { count += 1 }

      index_ensure_cap(count)

      i = 0
      each_chunk do |chunk|
        (@chunk_index + i).value = chunk
        i += 1
      end
      @chunk_index_count = count

      i = 1
      while i < @chunk_index_count
        key = (@chunk_index + i).value
        key_addr = key.address
        j = i - 1
        while j >= 0 && (@chunk_index + j).value.address > key_addr
          (@chunk_index + (j + 1)).value = (@chunk_index + j).value
          j -= 1
        end
        (@chunk_index + (j + 1)).value = key
        i += 1
      end

      @chunk_index_dirty = false
    end

    private def index_ensure_cap(need : Int32) : Nil
      return if need <= @chunk_index_cap
      new_cap = @chunk_index_cap == 0 ? 16 : @chunk_index_cap
      while new_cap < need
        new_cap *= 2
      end
      bytes = (sizeof(ChunkHeader*) * new_cap).to_u64
      ptr = LibC.realloc(@chunk_index.as(Void*), LibC::SizeT.new(bytes)).as(ChunkHeader**)
      raise OutOfMemoryError.new("chunk index realloc failed") if ptr.null?
      @chunk_index = ptr
      @chunk_index_cap = new_cap
    end

    # First index i where chunk_index[i].address >= addr (or count).
    private def index_lower_bound(addr : UInt64) : Int32
      lo = 0
      hi = @chunk_index_count
      while lo < hi
        mid = lo + (hi - lo) // 2
        if (@chunk_index + mid).value.address < addr
          lo = mid + 1
        else
          hi = mid
        end
      end
      lo
    end

    private def index_insert(chunk : ChunkHeader*) : Nil
      if @chunk_index_dirty
        return
      end
      index_ensure_cap(@chunk_index_count + 1)
      pos = index_lower_bound(chunk.address)
      i = @chunk_index_count
      while i > pos
        (@chunk_index + i).value = (@chunk_index + (i - 1)).value
        i -= 1
      end
      (@chunk_index + pos).value = chunk
      @chunk_index_count += 1
    end

    private def index_remove(chunk : ChunkHeader*) : Nil
      if @chunk_index_dirty
        return
      end
      pos = index_lower_bound(chunk.address)
      return if pos >= @chunk_index_count
      return if (@chunk_index + pos).value != chunk

      i = pos
      last = @chunk_index_count - 1
      while i < last
        (@chunk_index + i).value = (@chunk_index + (i + 1)).value
        i += 1
      end
      @chunk_index_count -= 1
    end

    private def chunk_for(user : Void*) : ChunkHeader*?
      chunk_containing(user.address)
    end

    private def owns_user_pointer?(user : Void*, header : BlockHeader*) : Bool
      chunk = chunk_for(user)
      return false unless chunk

      if ChunkHeader.large?(chunk)
        expected_header = ChunkHeader.data_start(chunk).as(BlockHeader*)
        return header == expected_header && BlockHeader.user_from(header) == user
      end

      class_index = chunk.value.size_class.to_i32
      return false if class_index < 0 || class_index >= SIZE_CLASS_COUNT

      block_bytes = @block_bytes[class_index]
      data_start = chunk.address + ChunkHeader::SIZE
      return false if header.address < data_start

      offset = header.address - data_start
      return false if (offset % block_bytes) != 0
      return false if header.address + block_bytes > chunk.address + chunk.value.mapped_bytes

      BlockHeader.user_from(header) == user
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
