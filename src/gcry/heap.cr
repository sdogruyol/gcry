require "./block"
require "./size_classes"
require "./mark_bitmap"
require "crystal/spin_lock"

module Gcry
  # mmap-backed allocator with size classes and conservative mark–sweep.
  #
  # The Heap *object* may live on Crystal's GC during unit tests. Mapped
  # chunks and freelist links live outside the managed heap so this can later
  # become the process GC under `-Dgc_none`.
  class Heap
    SMALL_CHUNK_BYTES     = 262144_u64 # 256 KiB — 512 KiB regressed /json vs Boehm
    MIN_SMALL_CHUNK_BYTES =  65536_u64 # 64 KiB floor for GCRY_CHUNK_BYTES
    PAUSE_RING_SIZE       =         64 # recent pause samples for p50/p99
    # HDR pause histogram buckets. Bucket `i` covers [2^i ns, 2^(i+1) ns); the
    # top bucket saturates to capture pauses ≥ ~1 s (e.g. CI debug builds).
    PAUSE_HDR_BUCKETS = 32
    # Power-of-two buckets for recycled large mappings (avoid munmap during STW).
    LARGE_FREE_BUCKETS = 20
    # Soft cap on cached free large bytes.
    LARGE_CACHE_LIMIT = 64_u64 * 1024 * 1024
    # Bytes of free large mappings to keep after trim (process default; override via GCRY_LARGE_CACHE).
    DEFAULT_LARGE_CACHE_RETAIN = 8_u64 * 1024 * 1024
    # Keep up to this many bytes of fully-free size-class chunks as dormant
    # (MADV_DONTNEED) for fast reuse; excess is munmap'd when release is on.
    # 0 means "munmap everything immediately" — that path fragmented VMA
    # space under Kemal-style churn and inflated RSS via mmap/madvise
    # cycling; the process GC bumps this to 64 MiB (see gc_override.cr).
    DEFAULT_EMPTY_CHUNK_RETAIN = 0_u64

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
    # Large-cache hit / miss counters for adaptive retain tuning (reset each major).
    getter large_cache_hits : UInt64 = 0_u64
    getter large_cache_misses : UInt64 = 0_u64
    # Size-class chunk mmap size (process default 256 KiB; override via GCRY_CHUNK_BYTES).
    property small_chunk_bytes : UInt64 = SMALL_CHUNK_BYTES

    @chunks : ChunkHeader* = Pointer(ChunkHeader).null
    # Side mark bitmap: one bit per word-aligned heap address, stored in its
    # own mmap (outside the managed heap). Replaces the in-header MARK bit so
    # marking no longer dirties BlockHeader cache lines, and `clear_all_marks`
    # becomes a single `memset(0)` over the bitmap.
    @mark_bitmap : MarkBitmap? = nil
    # Inline bitmap state (mirrored from @mark_bitmap on relocate/destroy).
    # Kept on the heap struct so `marked?`/`set_mark`/`clear_mark` can answer
    # in O(1) without dereferencing the singleton — the heap's hot fields
    # (`@heap_min`, `@heap_max`) live in the same cache line and the bitmap
    # state is read on every mark candidate.
    @mark_bitmap_base : UInt64 = 0_u64
    @mark_bitmap_base_addr : UInt64 = 0_u64
    @mark_bitmap_cap_bits : UInt64 = 0_u64
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
    # Last-chunk cache: most `chunk_containing` lookups during a mark come
    # from the same chunk (a hot object references its neighbours, and the
    # mark stack drains chunks in LIFO order). One O(1) range check replaces
    # the binary search for the common case.
    @last_chunk_idx : Int32 = -1
    @last_chunk_lo : UInt64 = 0_u64
    @last_chunk_hi : UInt64 = 0_u64
    @pause_ring = uninitialized StaticArray(UInt64, PAUSE_RING_SIZE)
    @pause_ring_len = 0
    @pause_ring_pos = 0
    # TLAB / parallel-mark (see tlab.cr / parallel_mark.cr) — init here for process GC.
    @alloc_lock = Crystal::SpinLock.new
    @tlab_enabled = false
    @tlab_refills = 0_u64
    @tlab_steals = 0_u64
    @tlab_hits = 0_u64
    @tlabs_booted = false
    @parallel_mark_workers = 1
    @parallel_mark_runs = 0_u64
    @parallel_mark_stolen = 0_u64
    @mark_lock = Crystal::SpinLock.new
    @mark_parallel = false
    @mark_worker_threads = [] of Thread
    @mark_pthreads = uninitialized StaticArray(LibC::PthreadT, 15)
    @mark_pthread_count = 0
    @mark_pthread_mode = false
    @mark_epoch = Atomic(UInt64).new(0_u64)
    @mark_shutdown = Atomic(Int32).new(0)
    @mark_workers_busy = Atomic(Int32).new(0)
    # HDR pause histogram (logarithmic, power-of-two buckets, 1ns..~1s).
    # PAUSE_HDR_BUCKETS = 32 → bucket `i` covers [2^i, 2^(i+1)) ns.
    @pause_hdr = uninitialized StaticArray(UInt64, PAUSE_HDR_BUCKETS)

    def initialize
      @mark_bitmap = MarkBitmap.new
      # Save the previous bitmap owner (may be the process GC under -Dgc_none).
      @saved_mark_bitmap = Gcry.current_mark_bitmap
      Gcry.current_mark_bitmap = @mark_bitmap
      @freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
      @nursery_freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
      @freelist_clean = StaticArray(Bool, SIZE_CLASS_COUNT).new(false)
      @nursery_freelist_clean = StaticArray(Bool, SIZE_CLASS_COUNT).new(false)
      @large_freelists = StaticArray(Void*, LARGE_FREE_BUCKETS).new(Pointer(Void).null)
      @pause_ring = StaticArray(UInt64, PAUSE_RING_SIZE).new(0_u64)
      @pause_hdr = StaticArray(UInt64, PAUSE_HDR_BUCKETS).new(0_u64)
      @bitmap_growth_history = StaticArray(UInt64, BITMAP_GROWTH_HISTORY_CAPACITY).new(0_u64)
      @bitmap_growth_count = 0
      @bitmap_growth_pos = 0
      @bitmap_headroom_bytes = (SMALL_CHUNK_BYTES >> 3)
      @block_bytes = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      SIZE_CLASS_COUNT.times do |i|
        @block_bytes[i] = BlockHeader::SIZE.to_u64 + SizeClasses.payload(i).to_u64
      end
      @tlab_enabled = false
      @tlab_refills = 0_u64
      @tlab_steals = 0_u64
      @tlabs_booted = false
      @alloc_lock = Crystal::SpinLock.new
      @parallel_mark_workers = 1
      @parallel_mark_runs = 0_u64
      @parallel_mark_stolen = 0_u64
      @mark_lock = Crystal::SpinLock.new
      @mark_parallel = false
      @mark_worker_threads = [] of Thread
      {% if flag?(:darwin) %}
        @mark_pthreads = StaticArray(LibC::PthreadT, 15).new(Pointer(Void).null.as(LibC::PthreadT))
      {% else %}
        @mark_pthreads = StaticArray(LibC::PthreadT, 15).new(LibC::PthreadT.new(0))
      {% end %}
      @mark_pthread_count = 0
      @mark_pthread_mode = false
      @mark_epoch = Atomic(UInt64).new(0_u64)
      @mark_shutdown = Atomic(Int32).new(0)
      @mark_workers_busy = Atomic(Int32).new(0)
      @clear_stack_enabled = false
      @clear_stack_bytes = 4096_u64
      @clear_stack_every = 1
      @scrub_fibers_enabled = false
      @clear_stack_bytes_total = 0_u64
      @fiber_scrub_bytes_total = 0_u64
      @clear_stack_calls = 0_u64
      @fiber_scrub_runs = 0_u64
      @clear_stack_ops = 0_u64
    end

    def finalize
      destroy
    end

    # Release all mapped memory. Safe to call multiple times.
    def destroy : Nil
      return if @destroyed
      @destroyed = true
      shutdown_mark_workers
      flush_all_tlabs
      # MUST tear down collector state (pending chunk flush, finalizers,
      # mark-stack) BEFORE unmapping the chunk list — destroy_collector walks
      # @chunks for flush_pending_dormant_chunks and
      # flush_pending_page_release_chunks. Reversing the order causes a
      # use-after-unmap SIGSEGV in at_exit handlers.
      destroy_collector

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
      @large_cache_hits = 0_u64
      @large_cache_misses = 0_u64
      unless @chunk_index.null?
        LibC.free(@chunk_index.as(Void*))
        @chunk_index = Pointer(ChunkHeader*).null
      end
      @chunk_index_count = 0
      @chunk_index_cap = 0
      @chunk_index_dirty = false
      if bm = @mark_bitmap
        # Restore the previous bitmap owner (may be the process GC under
        # -Dgc_none) instead of unconditionally clearing the global pointer.
        # The spec suite creates Heap objects alongside the process GC heap;
        # clearing the global pointer leaves the process GC without a bitmap
        # and causes a SIGSEGV in heap_marked?  during at_exit finalization.
        Gcry.current_mark_bitmap = @saved_mark_bitmap
        # Null the hot mirrored fields so a stale heap read doesn't dereference
        # an unmapped mapping.
        @mark_bitmap_base = 0_u64
        @mark_bitmap_base_addr = 0_u64
        @mark_bitmap_cap_bits = 0_u64
        bm.destroy
        @mark_bitmap = nil
      end
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

        with_alloc_lock do
          @bytes_since_gc = @bytes_since_gc > payload ? @bytes_since_gc - payload : 0_u64
          note_explicit_free(payload)
          @live_objects -= 1 if @live_objects > 0
        end
        @finalizers.notice_reclaim(pointer)
        with_alloc_lock { cache_large_chunk(chunk, header) }
        trim_large_cache
        return
      end

      chunk = chunk_for(pointer)
      raise ArgumentError.new("pointer is not a gcry allocation") unless chunk

      class_index = chunk.value.size_class.to_i32
      raise ArgumentError.new("bad size class on chunk") if class_index < 0 || class_index >= SIZE_CLASS_COUNT
      payload = SizeClasses.payload(class_index)

      @finalizers.notice_reclaim(pointer)

      if @tlab_enabled
        tlab_free_small(pointer, class_index, payload, BlockHeader.nursery?(header))
      elsif BlockHeader.nursery?(header)
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, @nursery_freelists[class_index])
        @nursery_freelists[class_index] = pointer
        @nursery_freelist_clean[class_index] = false
        @free_bytes += payload.to_u64
      else
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, @freelists[class_index])
        @freelists[class_index] = pointer
        @freelist_clean[class_index] = false
        @free_bytes += payload.to_u64
      end

      with_alloc_lock do
        @bytes_since_gc = @bytes_since_gc > payload ? @bytes_since_gc - payload : 0_u64
        note_explicit_free(payload.to_u64)
        @live_objects -= 1 if @live_objects > 0
      end
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
      maybe_clear_stack_on_alloc

      rounded, class_index = SizeClasses.fit(size)
      flags = atomic ? BlockHeader::Flags::ATOMIC : 0_u32

      # Skip memset when memory is still MAP_ANONYMOUS-zeroed (fresh chunk /
      # fresh large mmap). Freelist reuse / large-cache hits still clear.
      # Check clean *after* alloc — refill may have just marked the freelist clean.
      user = Pointer(Void).null
      needs_clear = clear
      if class_index < 0
        user, from_cache = with_alloc_lock { alloc_large(rounded, flags) }
        needs_clear = clear && from_cache
      elsif @nursery_enabled
        user = if @tlab_enabled
                 tlab_alloc_small(rounded.to_u32, flags | BlockHeader::Flags::NURSERY, class_index, true)
               else
                 alloc_nursery(rounded.to_u32, flags | BlockHeader::Flags::NURSERY, class_index)
               end
        needs_clear = clear && !@nursery_freelist_clean[class_index]
      else
        user = if @tlab_enabled
                 tlab_alloc_small(rounded.to_u32, flags, class_index, false)
               else
                 alloc_old_small(rounded.to_u32, flags, class_index)
               end
        needs_clear = clear && !@freelist_clean[class_index]
      end

      user.as(UInt8*).clear(rounded) if needs_clear
      with_alloc_lock do
        @total_bytes += rounded
        @bytes_since_gc += rounded
        @live_objects += 1
      end
      user
    end

    private def alloc_nursery(payload : UInt32, flags : UInt32, index : Int32) : Void*
      user = @nursery_freelists[index]

      if user.null?
        refill_size_class(index, payload, nursery: true)
        user = @nursery_freelists[index]
        raise OutOfMemoryError.new("failed to refill nursery size class #{payload}") if user.null?
      end

      if @blacklist_enabled
        taken = take_non_blacklisted(user, index, true)
        if taken.null?
          header = BlockHeader.from_user(user)
          @nursery_freelists[index] = header.value.next_free
        else
          user = taken
        end
      else
        header = BlockHeader.from_user(user)
        @nursery_freelists[index] = header.value.next_free
      end

      header = BlockHeader.from_user(user)
      BlockHeader.set_used(header, payload, flags)
      # Allocate black during any in-progress collection (STW or incremental)
      # so mid-collect allocations are not swept.
      if @incremental_marking || @collecting
        heap_set_mark(header)
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

      if @blacklist_enabled
        taken = take_non_blacklisted(user, index, false)
        if taken.null?
          header = BlockHeader.from_user(user)
          @freelists[index] = header.value.next_free
        else
          user = taken
        end
      else
        header = BlockHeader.from_user(user)
        @freelists[index] = header.value.next_free
      end

      header = BlockHeader.from_user(user)
      BlockHeader.set_used(header, payload, flags)
      heap_set_mark(header) if @incremental_marking || @collecting

      @free_bytes -= payload if @free_bytes >= payload
      user
    end

    private def refill_size_class(index : Int32, payload : UInt32, nursery : Bool = false) : Nil
      if revive_dormant_chunk(index, payload, nursery)
        return
      end

      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      chunk_flags = nursery ? ChunkHeader::Flags::NURSERY : 0_u32
      chunk = map_chunk(@small_chunk_bytes, index.to_u32, chunk_flags)
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

    # Fault a dormant empty chunk back in and install its freelist.
    private def revive_dormant_chunk(index : Int32, payload : UInt32, nursery : Bool) : Bool
      chunk = @chunks
      while chunk
        if !ChunkHeader.large?(chunk) &&
           ChunkHeader.dormant?(chunk) &&
           chunk.value.size_class == index.to_u32 &&
           ChunkHeader.nursery?(chunk) == nursery
          ChunkHeader.set_dormant(chunk, false)
          mapped = chunk.value.mapped_bytes
          @dormant_chunk_bytes -= mapped if @dormant_chunk_bytes >= mapped

          block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
          cursor = ChunkHeader.data_start(chunk).as(UInt8*)
          limit = ChunkHeader.data_end(chunk).as(UInt8*)
          free_head = Pointer(Void).null
          added = 0_u64
          while (cursor + block_bytes) <= limit
            header = cursor.as(BlockHeader*)
            user = (cursor + BlockHeader::SIZE).as(Void*)
            # Touch page (recommit after DONTNEED) and link freelist.
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
          return true
        end
        chunk = chunk.value.next
      end
      false
    end

    # Returns {user, from_cache}. Fresh mmap pages are already zeroed.
    # Mapped size is host-page aligned (16 KiB on Apple Silicon) so Darwin
    # free-page reclaim and munmap stay page-correct.
    private def alloc_large(payload : UInt64, flags : UInt32) : {Void*, Bool}
      need = ChunkHeader::SIZE.to_u64 + BlockHeader::SIZE.to_u64 + payload
      mapped = align_up(need, Platform.host_page_size)

      if user = take_large_free(mapped)
        header = BlockHeader.from_user(user)
        BlockHeader.set_used(header, payload.to_u32!, flags | BlockHeader::Flags::LARGE)
        heap_set_mark(header) if @incremental_marking || @collecting
        return {user, true}
      end

      @large_cache_misses += 1

      chunk = map_chunk(mapped, UInt32::MAX, 0_u32)
      header = ChunkHeader.data_start(chunk).as(BlockHeader*)
      BlockHeader.set_used(header, payload.to_u32!, flags | BlockHeader::Flags::LARGE)
      heap_set_mark(header) if @incremental_marking || @collecting
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
    # Inserts at tail of freelist bucket for LRU eviction: trim_large_cache
    # pops from the head, evicting the least recently re-used entry.
    protected def cache_large_chunk(chunk : ChunkHeader*, header : BlockHeader*) : Nil
      mapped = chunk.value.mapped_bytes
      payload = header.value.size
      bucket = self.class.large_bucket(mapped)
      user = BlockHeader.user_from(header)
      # Find tail of bucket freelist.
      tail = @large_freelists[bucket]
      while tail
        th = BlockHeader.from_user(tail)
        tnxt = th.value.next_free
        break if tnxt.null?
        tail = tnxt
      end
      header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE | BlockHeader::Flags::LARGE, Pointer(Void).null)
      if tail.null?
        @large_freelists[bucket] = user
      else
        th = BlockHeader.from_user(tail)
        tv = th.value
        tv.next_free = user
        th.value = tv
      end
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
          @large_cache_hits += 1
          return user
        end
        prev = user
        user = nxt
      end
      nil
    end

    # Munmap cached large objects until @large_free_bytes <= *limit*.
    # Call outside STW — munmap of many VMAs is slow on Linux.
    # Hard-capped by LARGE_CACHE_LIMIT even if retain is set higher.
    def trim_large_cache(limit : UInt64 = @large_cache_retain) : Nil
      effective = limit > LARGE_CACHE_LIMIT ? LARGE_CACHE_LIMIT : limit
      return if @large_free_bytes <= effective

      b = LARGE_FREE_BUCKETS - 1
      while b >= 0 && @large_free_bytes > effective
        user = @large_freelists[b]
        while user && @large_free_bytes > effective
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

    # Binary search over address-sorted chunk index, with a single-slot
    # last-chunk cache (pointer chasing in mark drains one chunk at a time).
    protected def chunk_containing(addr : UInt64) : ChunkHeader*?
      return nil if @heap_max == 0 || addr < @heap_min || addr >= @heap_max

      # Last-chunk fast path: most lookups during mark hit the same chunk
      # that produced the previous result. Range check first (cheaper than
      # even a L1 index hit) before touching the sorted index.
      if @last_chunk_idx >= 0 && addr >= @last_chunk_lo && addr < @last_chunk_hi
        return (@chunk_index + @last_chunk_idx).value
      end

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
          @last_chunk_idx = mid
          @last_chunk_lo = base
          @last_chunk_hi = finish
          return chunk if ChunkHeader.contains?(chunk, addr)
          return nil
        end
      end
      nil
    end

    private def invalidate_chunk_cache : Nil
      @last_chunk_idx = -1
      @last_chunk_lo = 0_u64
      @last_chunk_hi = 0_u64
    end

    # ----- Bitmap hot path (heap-inlined mirrors of MarkBitmap) -----
    # These read the heap's mirrored fields (same cache line as @heap_min /
    # @heap_max) instead of going through `Gcry.current_mark_bitmap` plus a
    # MarkBitmap#marked? virtual dispatch. On a wrk -c 100 -d 5 /json run,
    # the extra dereference shows up as ~50% throughput loss because every
    # mark candidate — i.e. every word scanned — pays for it.

    @[AlwaysInline]
    private def heap_marked?(header : BlockHeader*) : Bool
      base = @mark_bitmap_base
      return false if base == 0
      user_addr = BlockHeader.user_from(header).address
      bit_index = user_addr - @mark_bitmap_base_addr
      return false if bit_index >= @mark_bitmap_cap_bits
      word_index = (bit_index >> 6).to_i32
      bit = (bit_index & 63).to_i32
      word_ptr = Pointer(UInt64).new(base) + word_index
      ((word_ptr.value >> bit) & 1_u64) != 0
    end

    @[AlwaysInline]
    private def heap_set_mark(header : BlockHeader*) : Nil
      base = @mark_bitmap_base
      return if base == 0
      user_addr = BlockHeader.user_from(header).address
      bit_index = user_addr - @mark_bitmap_base_addr
      return if bit_index >= @mark_bitmap_cap_bits
      word_index = (bit_index >> 6).to_i32
      bit = (bit_index & 63).to_i32
      word_ptr = Pointer(UInt64).new(base) + word_index
      word_ptr.value |= 1_u64 << bit
    end

    @[AlwaysInline]
    private def heap_clear_mark(header : BlockHeader*) : Nil
      base = @mark_bitmap_base
      return if base == 0
      user_addr = BlockHeader.user_from(header).address
      bit_index = user_addr - @mark_bitmap_base_addr
      return if bit_index >= @mark_bitmap_cap_bits
      word_index = (bit_index >> 6).to_i32
      bit = (bit_index & 63).to_i32
      word_ptr = Pointer(UInt64).new(base) + word_index
      word_ptr.value &= ~(1_u64 << bit)
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
      invalidate_chunk_cache
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
      invalidate_chunk_cache
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
require "./tlab"
require "./parallel_mark"
require "./stack_scrub"
