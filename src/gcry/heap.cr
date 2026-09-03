require "./block"
require "./size_classes"
require "./chunk_layout"
require "./chunk_radix"
require "./bitmap_alloc"
require "crystal/spin_lock"
require "c/pthread"

module Gcry
  # mmap-backed allocator with size classes and conservative mark–sweep.
  #
  # The Heap *object* may live on Crystal's GC during unit tests. Mapped
  # chunks and freelist links live outside the managed heap so this can later
  # become the process GC under `-Dgc_none`.
  class Heap
    SMALL_CHUNK_BYTES     = 131072_u64 # 128 KiB — library default; macOS process GC bumps to 256 KiB (gc_override.cr)
    MIN_SMALL_CHUNK_BYTES =  65536_u64 # 64 KiB floor for GCRY_CHUNK_BYTES
    PAUSE_RING_SIZE       =         64 # recent pause samples for p50/p99
    # HDR pause histogram buckets. Bucket `i` covers [2^i ns, 2^(i+1) ns); the
    # top bucket saturates to capture pauses ≥ ~1 s (e.g. CI debug builds).
    PAUSE_HDR_BUCKETS = 32
    # Power-of-two buckets for recycled large mappings (avoid munmap during STW).
    LARGE_FREE_BUCKETS = 20
    # Soft cap on cached free large bytes.
    LARGE_CACHE_LIMIT = 32_u64 * 1024 * 1024
    # Bytes of free large mappings to keep after trim (library default 4 MiB;
    # Darwin process GC starts at 1 MiB — see gc_override. Override via GCRY_LARGE_CACHE).
    DEFAULT_LARGE_CACHE_RETAIN = 4_u64 * 1024 * 1024
    # Keep up to this many bytes of fully-free size-class chunks as dormant
    # (MADV_DONTNEED) for fast reuse; excess is munmap'd when release is on.
    # 0 means "munmap everything immediately" — that path fragmented VMA
    # space under Kemal-style churn and inflated RSS via mmap/madvise
    # cycling; the process GC bumps this to 64 MiB (see gc_override.cr).
    DEFAULT_EMPTY_CHUNK_RETAIN = 0_u64

    getter chunk_index_count : Int32 = 0

    getter heap_size : UInt64 = 0_u64
    # Alloc accounting is Atomic so TLAB hits / Parallel mutators need not take
    # @alloc_lock just to bump counters (see note_alloc_bytes). Freelist heads
    # still serialise on SpinLock.
    @free_bytes = Atomic(UInt64).new(0_u64)
    @total_bytes = Atomic(UInt64).new(0_u64)
    @bytes_since_gc = Atomic(UInt64).new(0_u64)
    @live_objects = Atomic(UInt64).new(0_u64)
    getter large_free_bytes : UInt64 = 0_u64

    def free_bytes : UInt64
      @free_bytes.get
    end

    def total_bytes : UInt64
      @total_bytes.get
    end

    def bytes_since_gc : UInt64
      @bytes_since_gc.get
    end

    def live_objects : UInt64
      @live_objects.get
    end

    # Move the counter without touching a block, so a test can show that
    # `Invariant.check_live_objects` catches a drift rather than only that it
    # passes. There is no other way to produce one on purpose: every real path
    # keeps the counter and the headers together, which is the point.
    def debug_drift_live_objects(delta : Int64) : Nil
      current = @live_objects.get
      @live_objects.set(delta < 0 ? current &- (-delta).to_u64 : current &+ delta.to_u64)
    end

    # Sum of large-chunk mapped_bytes (live + free on freelist).
    getter large_mapped_bytes : UInt64 = 0_u64
    # Retain this many free large bytes after trim_large_cache (outside STW).
    property large_cache_retain : UInt64 = DEFAULT_LARGE_CACHE_RETAIN
    # Large-cache hit / miss counters for adaptive retain tuning (reset each major).
    getter large_cache_hits : UInt64 = 0_u64
    getter large_cache_misses : UInt64 = 0_u64
    # Size-class chunk mmap size (process default 128 KiB; macOS bumps to 256 KiB;
    # override via GCRY_CHUNK_BYTES).
    property small_chunk_bytes : UInt64 = SMALL_CHUNK_BYTES

    @chunks : ChunkHeader* = Pointer(ChunkHeader).null
    # Per-chunk mark bitmaps instead of the header mark-generation byte
    # (`GCRY_BITMAP=1`). Decided once at `initialize` and never changed while
    # chunks exist: it determines each chunk's `data_offset`, so flipping it
    # under a live heap would make already-carved chunks unreadable.
    #
    # Off by default. The header path stays the shipping representation until a
    # Kemal + acikturkiye cut says the bitmap wins, and it is also the fallback
    # on a CPU without the SIMD baseline.
    getter? bitmap_marks : Bool = false
    # `GCRY_BITMAP_ALLOC=1` (Phase 3): `occ` bitmaps, bitmap sweep, and pool
    # allocation. Implies `bitmap_marks`, and goes strictly further — it retires
    # the Phase 1 union, because a bitmap-only sweep cannot see a mark that only
    # exists in a header generation.
    #
    # A separate knob rather than an extension of `GCRY_BITMAP` so that the
    # mark-only representation, which is gated and measured, stays exactly as it
    # shipped while this is still being built out. Nursery chunks are excluded
    # under both: their allocation is still `alloc_nursery`'s freelist, so `occ`
    # is not maintained for them (Phase 8).
    # Instruction-set tier for the bitmap kernels; see `Gcry::Cpu`.
    getter simd_tier : UInt8 = Kernels::TIER_SCALAR
    # Mark-loop prefetch pipeline (`GCRY_PREFETCH`, default on). See
    # `serial_mark_drain`.
    property mark_prefetch : Bool = true
    # Bytes ahead of the allocation cursor to prefetch-for-write
    # (`GCRY_ALLOC_PFW`, default 2 KiB, 0 = off). simdgc measured 7.1 -> 4.2 ns
    # on fresh memory; the sweet spot is machine-dependent, so it is a knob.
    property alloc_pfw : UInt64 = 2048_u64
    @freelists = uninitialized StaticArray(Void*, SIZE_CLASS_COUNT)
    @nursery_freelists = uninitialized StaticArray(Void*, SIZE_CLASS_COUNT)
    # Tight-grow: freelist nodes that live in the current grow chunk (newest
    # mmap for the class). Alloc prefers these so older chunks are not
    # refilled and can become fully empty for munmap.
    @prefer_freelists = uninitialized StaticArray(Void*, SIZE_CLASS_COUNT)
    @grow_lo = uninitialized StaticArray(UInt64, SIZE_CLASS_COUNT)
    @grow_hi = uninitialized StaticArray(UInt64, SIZE_CLASS_COUNT)
    # True while freelist blocks are still MAP_ANONYMOUS-zeroed (skip malloc clear).
    @freelist_clean = uninitialized StaticArray(Bool, SIZE_CLASS_COUNT)
    @nursery_freelist_clean = uninitialized StaticArray(Bool, SIZE_CLASS_COUNT)
    @large_freelists = uninitialized StaticArray(Void*, LARGE_FREE_BUCKETS)
    @block_bytes = uninitialized StaticArray(UInt64, SIZE_CLASS_COUNT)
    # Magic reciprocals for `offset / block_bytes` — see `Heap.block_magic`.
    @block_magic = uninitialized StaticArray(UInt64, SIZE_CLASS_COUNT)
    @destroyed = false
    @nursery_alloc_bytes = Atomic(UInt64).new(0_u64)
    # Lazily rebuilt address-sorted index (mark / static exclusion).
    @chunk_index : ChunkHeader** = Pointer(ChunkHeader*).null
    @chunk_index_count = 0
    @chunk_index_cap = 0
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
    # Must stay SpinLock (not pthread_mutex): STW can suspend a mutator that
    # holds a freelist lock; a sleeping mutex then deadlocks the collector /
    # peers (seen: collections=0, heap growth unbounded, thr ~12k).
    # @alloc_lock: large objects + TLAB table boot. Per-size-class freelist
    # heads use @freelist_locks / @nursery_freelist_locks so Parallel workers
    # allocating different sizes do not serialise on one lock.
    # STW sweep must not take freelist locks (suspended mutator may hold them).
    @alloc_lock = Crystal::SpinLock.new
    @freelist_locks = uninitialized StaticArray(Crystal::SpinLock, SIZE_CLASS_COUNT)
    @nursery_freelist_locks = uninitialized StaticArray(Crystal::SpinLock, SIZE_CLASS_COUNT)
    # Atomic RMW on every alloc/free counter update. Off until a **second
    # thread is created**, which `GC.pthread_create` flips (gc_override), and
    # `EC_PARALLELISM>1` still sets up front.
    #
    # It used to say that single mutator plus a rare SYSMON was "fine with plain
    # get/set". It is not: `set(get + 1)` loses increments outright once two
    # threads run it, measured as the process heap's counter permanently behind
    # in 3 runs of 40 (src/gcry/invariant.cr). And the cost that bought is not
    # what the comment claimed either — on x86_64 `set` compiles to `xchg`,
    # which is locked whether you ask or not, so the plain path was already
    # paying for a locked instruction per counter and losing updates for it.
    # `GCRY_HEAP_COUNTERS_ATOMIC=0/1` runs the arms side by side.
    property heap_counters_atomic : Bool = false

    # Set when `GCRY_HEAP_COUNTERS_ATOMIC` names a value: an explicit arm must
    # survive the flip that `GC.pthread_create` would otherwise do, or the two
    # arms cannot be run side by side and the "plain path loses updates" half of
    # the gate can never be shown.
    property heap_counters_atomic_pinned : Bool = false
    @index_lock = Crystal::SpinLock.new
    # `@chunks` surgery only. Separate from `@index_lock` on purpose: the
    # unlink walks the list to find a predecessor, and holding the index
    # lock across that O(n) walk starves every `chunk_containing` — a
    # 2-core Darwin runner went from a 1m50s job to a 20-minute timeout in
    # the STW × TLAB property test. This one is contended only by other
    # list mutations. Order is list → index; nothing goes the other way.
    @chunk_list_lock = Crystal::SpinLock.new
    @post_stw_mutex = uninitialized LibC::PthreadMutexT
    @tlab_enabled = false
    @tlab_refills = 0_u64
    @tlab_steals = 0_u64
    @tlab_hits = Atomic(UInt64).new(0_u64)
    @tlabs_booted = false
    @tlab_epoch = Atomic(UInt64).new(0_u64)
    # TLAB-off batch: claim N under freelist lock as USED, consume from
    # thread stash without that lock (safe with lazy sweep). 0 = off.
    property alloc_batch : Int32 = 0
    @alloc_batches_booted = false
    @alloc_batch_epoch = Atomic(UInt64).new(0_u64)
    @alloc_batch_hits = Atomic(UInt64).new(0_u64)
    @alloc_batch_refills = 0_u64
    @parallel_mark_workers = 1
    @parallel_mark_runs = 0_u64
    @parallel_mark_stolen = 0_u64
    @mark_lock = Crystal::SpinLock.new
    @mark_parallel = false
    @mark_worker_threads = [] of Thread
    @mark_pthreads = uninitialized StaticArray(LibC::PthreadT, 15)
    @mark_pthread_count = 0
    @mark_pthread_mode = false
    # Per-worker mark-stack shards. `@mark_pushbuf[slot]` is a raw mmap'd buffer
    # of up to `MARK_PUSHBUF_CAP` `Void*`; `@mark_pushbuf_n[slot]` its count.
    # 16 slots: slot 0 the collecting (master) thread, 1..15 the pthread helpers.
    # Raw mmap, not a MarkStack per slot, because these are created lazily during
    # a collection and a managed allocation there is forbidden under -Dgc_none.
    @mark_pushbuf = uninitialized StaticArray(UInt64, 16)
    @mark_pushbuf_n = uninitialized StaticArray(Int32, 16)
    # Workers claim a slot once (thread-local `@@mark_worker` survives across
    # collections, so the same pthread keeps its slot).
    @mark_slot_claim = Atomic(Int32).new(1)
    @mark_epoch = Atomic(UInt64).new(0_u64)
    @mark_shutdown = Atomic(Int32).new(0)
    @mark_workers_busy = Atomic(Int32).new(0)
    # In-header mark generation (bits 8–15). clear_all_marks bumps this (O(1))
    # instead of walking the heap; wraps at 255 with a full clear. Synced to
    # BlockHeader.mark_gen for barrier / BlockHeader.marked? callers.
    @header_mark_gen = 1_u8
    @header_mark_gen_full_clears = 0_u64
    getter header_mark_gen : UInt8
    getter header_mark_gen_full_clears : UInt64
    # HDR pause histogram (logarithmic, power-of-two buckets, 1ns..~1s).
    # PAUSE_HDR_BUCKETS = 32 → bucket `i` covers [2^i, 2^(i+1)) ns.
    @pause_hdr = uninitialized StaticArray(UInt64, PAUSE_HDR_BUCKETS)
    # Nesting depth: realloc (and similar) suppress auto-collect while a block
    # is only kept alive via add_root / in-flight copy. Must be Atomic —
    # Parallel EC races on plain Int left suppress stuck high → no auto-GC
    # (seen: suppress≈4607, collections=0 after atomic alloc-counter unlock).
    @suppress_collect = Atomic(Int32).new(0)

    def initialize
      # Both read through LibC.getenv rather than ENV[]: under -Dgc_none this
      # runs inside GC.init, before Fiber exists, where ENV[] allocates and can
      # SEGV (gc_override.cr:520).
      @simd_tier = Cpu.tier_from_env
      @bitmap_alloc = Heap.bitmap_alloc_from_env
      @bitmap_marks = @bitmap_alloc || Heap.bitmap_marks_from_env
      radix_init if Heap.chunk_radix_from_env
      bitmap_alloc_init
      @freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
      @nursery_freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
      @prefer_freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
      @grow_lo = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      @grow_hi = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      @freelist_clean = StaticArray(Bool, SIZE_CLASS_COUNT).new(false)
      @nursery_freelist_clean = StaticArray(Bool, SIZE_CLASS_COUNT).new(false)
      @large_freelists = StaticArray(Void*, LARGE_FREE_BUCKETS).new(Pointer(Void).null)
      @pause_ring = StaticArray(UInt64, PAUSE_RING_SIZE).new(0_u64)
      @pause_hdr = StaticArray(UInt64, PAUSE_HDR_BUCKETS).new(0_u64)
      @block_bytes = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      @block_magic = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      SIZE_CLASS_COUNT.times do |i|
        @block_bytes[i] = BlockHeader::SIZE.to_u64 + SizeClasses.payload(i).to_u64
        @block_magic[i] = Heap.block_magic(@block_bytes[i])
      end
      @tlab_enabled = false
      @tlab_refills = 0_u64
      @tlab_steals = 0_u64
      @tlabs_booted = false
      @tlab_epoch = Atomic(UInt64).new(0_u64)
      @alloc_batch = 0
      @alloc_batches_booted = false
      @alloc_batch_epoch = Atomic(UInt64).new(0_u64)
      @alloc_batch_hits = Atomic(UInt64).new(0_u64)
      @alloc_batch_refills = 0_u64
      @suppress_collect = Atomic(Int32).new(0)
      @alloc_lock = Crystal::SpinLock.new
      init_freelist_locks
      @index_lock = Crystal::SpinLock.new
      @chunk_list_lock = Crystal::SpinLock.new
      init_post_stw_mutex
      @parallel_mark_workers = 1
      @parallel_mark_runs = 0_u64
      @parallel_mark_stolen = 0_u64
      @mark_lock = Crystal::SpinLock.new
      @mark_parallel = false
      @mark_worker_threads = [] of Thread
      # PthreadT is Void* on musl/darwin/BSD (no .new) and an integer alias on glibc.
      zero_tid = uninitialized LibC::PthreadT
      pointerof(zero_tid).clear
      @mark_pthreads = StaticArray(LibC::PthreadT, 15).new(zero_tid)
      @mark_pthread_count = 0
      @mark_pthread_mode = false
      @mark_pushbuf = StaticArray(UInt64, 16).new(0_u64)
      @mark_pushbuf_n = StaticArray(Int32, 16).new(0)
      @mark_slot_claim = Atomic(Int32).new(1)
      @mark_epoch = Atomic(UInt64).new(0_u64)
      @header_mark_gen = 1_u8
      @header_mark_gen_full_clears = 0_u64
      # Large chunks use the header generation under both representations.
      BlockHeader.mark_gen = @header_mark_gen
      @mark_shutdown = Atomic(Int32).new(0)
      @mark_workers_busy = Atomic(Int32).new(0)
      @clear_stack_enabled = false
      @clear_stack_bytes = 4096_u64
      @clear_stack_every = 1
      @scrub_fibers_enabled = false
      @fiber_scrub_bytes = FIBER_CLEAR_STACK_CAP
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
      flush_all_alloc_batches
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
      @prefer_freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
      @grow_lo = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      @grow_hi = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      @freelist_clean = StaticArray(Bool, SIZE_CLASS_COUNT).new(false)
      @nursery_freelist_clean = StaticArray(Bool, SIZE_CLASS_COUNT).new(false)
      @large_freelists = StaticArray(Void*, LARGE_FREE_BUCKETS).new(Pointer(Void).null)
      @heap_size = 0_u64
      @free_bytes.set(0_u64)
      @total_bytes.set(0_u64)
      @bytes_since_gc.set(0_u64)
      @large_free_bytes = 0_u64
      @large_mapped_bytes = 0_u64
      @live_objects.set(0_u64)
      @nursery_alloc_bytes.set(0_u64)
      @tlab_hits.set(0_u64)
      @large_cache_hits = 0_u64
      @large_cache_misses = 0_u64
      unless @chunk_index.null?
        LibC.free(@chunk_index.as(Void*))
        @chunk_index = Pointer(ChunkHeader*).null
      end
      @chunk_index_count = 0
      @chunk_index_cap = 0
      # No bitmap teardown: the mark bitmaps live inside the chunks and are
      # unmapped with them. That is the whole point of putting them there.
      radix_destroy
    end

    # `GCRY_BITMAP=1`. Read with LibC.getenv, not ENV[] — see `initialize`.
    def self.bitmap_marks_from_env : Bool
      env_is_one?("GCRY_BITMAP")
    end

    # `GCRY_BITMAP_ALLOC=1`. Implies `GCRY_BITMAP`.
    def self.bitmap_alloc_from_env : Bool
      env_is_one?("GCRY_BITMAP_ALLOC")
    end

    # `GCRY_CHUNK_RADIX=1`.
    def self.chunk_radix_from_env : Bool
      env_is_one?("GCRY_CHUNK_RADIX")
    end

    # `GCRY_RADIX_THP=1`. Research/A-B only; see `chunk_radix.cr`.
    def self.radix_thp_from_env : Bool
      env_is_one?("GCRY_RADIX_THP")
    end

    private def self.env_is_one?(name : String) : Bool
      raw = LibC.getenv(name)
      return false if raw.null?
      raw.value == '1'.ord.to_u8 && (raw + 1).value == 0
    end

    # Specs and `gc_override` may switch representation, but only before any
    # chunk has been carved: `data_offset` is baked into every chunk at
    # `map_chunk`, so flipping this under a live heap would leave chunks whose
    # blocks start somewhere the heap no longer believes they do.
    def bitmap_marks=(value : Bool) : Bool
      if value != @bitmap_marks && !@chunks.null?
        raise ArgumentError.new("bitmap_marks cannot change once chunks are mapped")
      end
      @bitmap_alloc = false unless value
      @bitmap_marks = value
    end

    getter? bitmap_alloc : Bool = false

    # TLAB is a freelist mechanism — per-thread freelist heads — and the pool
    # cursor replaces it outright. Enabling both would have two allocators
    # handing out the same blocks.
    def bitmap_alloc=(value : Bool) : Bool
      if value != @bitmap_alloc && !@chunks.null?
        raise ArgumentError.new("bitmap_alloc cannot change once chunks are mapped")
      end
      if value
        @bitmap_marks = true
        @tlab_enabled = false
        # The streaming sweep settles a whole chunk's reclaim with one
        # `live_objects_sub(freed)`, where `freed` is a popcount over a bitmap
        # other threads are allocating into. The default counter path is a
        # non-atomic get/set — chosen deliberately to keep a LOCK off the EC1
        # alloc hot path — and a lost update there costs *one* object when the
        # header arm decrements per block, but the whole batch here. Measured as
        # `reported=0 walked=117`, the counter saturating at zero.
        @heap_counters_atomic = true
      end
      @bitmap_alloc = value
    end

    def malloc(size : Int) : Void*
      ptr = allocate(size.to_u64, atomic: false, clear: true)
      Invariant.after_malloc(self, ptr, size.to_u64)
      Trace.after_malloc(ptr, size.to_u64, atomic: false)
      ptr
    end

    def malloc_atomic(size : Int) : Void*
      ptr = allocate(size.to_u64, atomic: true, clear: false)
      Invariant.after_malloc(self, ptr, size.to_u64)
      Trace.after_malloc(ptr, size.to_u64, atomic: true)
      ptr
    end

    def realloc(pointer : Void*, size : Int) : Void*
      new_size = size.to_u64
      return malloc(new_size) if pointer.null?

      header = BlockHeader.from_user(pointer)
      raise ArgumentError.new("pointer is not a gcry allocation") unless owns_user_pointer?(pointer, header)

      old_size = header.value.size.to_u64
      atomic = BlockHeader.atomic?(header)

      if new_size == 0
        # Do **not** free `pointer` here, for the same reason the grow path
        # below spells out: Crystal stores the result after `realloc` returns,
        # so until that store the caller's ivar still holds `pointer`. Freeing
        # it immediately lets a peer Parallel collect reuse the block while an
        # owner still points at it — the defect that comment was written for,
        # reachable through a second door.
        #
        # Measured before changing it: this path fires **zero** times in a
        # fiber-spawning workload, and Crystal's stdlib has no caller that
        # reaches it (`GC.free` appears only in the zlib and GMP allocator
        # hooks). So this is a trap being closed, not a live defect being
        # fixed — and closing it costs nothing but the old block's retention
        # until the next sweep, which is exactly what the grow path already
        # accepts.
        return malloc(0)
      end

      return pointer if new_size <= old_size

      # Pin across allocate. The reason first written here — that the type_id
      # gate rejects raw Pointer buffers as ambient stack roots — **no longer
      # holds**: `GC.init` sets `type_id_gate_stacks = false` precisely because
      # gating stacks dropped Channel/Deque buffers and crashed
      # `Log::AsyncDispatcher`. Stack roots are ungated, so a raw buffer in a
      # register or stack slot is already a root.
      #
      # What still holds is the second reason, spelled out below: a minor may
      # not re-scan an old-gen owner, and Crystal stores the result only after
      # `realloc` returns. Rooting `fresh` on the same (stale) argument was
      # tried and measured — 3 of 40 against 1 of 40, and
      # `realloc_collect_overlaps` is 0 — so it is not done.
      #
      # Also suppress auto-collect for the fresh allocate: under Parallel EC a
      # mark miss on the pin still let sweep free `pointer`, then allocate
      # handed the same block back as `fresh` → copy of freed memory
      # (String::Builder#resize on /json).
      #
      # Do NOT free `pointer` here. Crystal updates owners after realloc
      # returns (`@indices = @indices.realloc(n)`): until that store, the ivar
      # still holds `pointer`. Freeing immediately lets a peer Parallel collect
      # reuse the block (e.g. as a String) while Hash.@indices still points at
      # it → Headers#[]? / keep_alive? SEGV with ASCII garbage @indices (GDB
      # EC4). Leave the old block for the next sweep once the caller drops it.
      add_root(pointer)
      begin
        @suppress_collect.add(1)
        begin
          fresh = allocate(new_size, atomic: atomic, clear: !atomic)
        ensure
          @suppress_collect.sub(1)
        end
        # The counter stays even though the window came back empty: it answers
        # "did a collection begin while a raw buffer was being copied into"
        # directly, which a crash-rate A/B cannot do at these rates.
        realloc_copy_enter
        begin
          fresh.as(UInt8*).copy_from(pointer.as(UInt8*), old_size)
        ensure
          realloc_copy_leave
        end
        fresh
      ensure
        delete_root(pointer)
      end
    end

    def free(pointer : Void*) : Nil
      return if pointer.null?

      header = BlockHeader.from_user(pointer)
      raise ArgumentError.new("pointer is not a gcry allocation") unless owns_user_pointer?(pointer, header)

      # The double-free check asks the same authority everything else does.
      #
      # `BlockHeader.free?` is stale on a bitmap chunk for every block the
      # streaming sweep reclaimed, so freeing one of those passed this check,
      # `bitmap_free_block` was a no-op on an already-clear bit, and
      # `live_objects_dec` still ran. That over-decrement is the exact shape of
      # `mt-property-test`'s `live_objects mismatch reported=98 walked=233`.
      double_free = if (chunk = chunk_for(pointer))
                      !block_allocated?(chunk, header)
                    else
                      BlockHeader.free?(header)
                    end
      raise ArgumentError.new("double free") if double_free

      if BlockHeader.large?(header)
        payload = header.value.size.to_u64
        chunk = chunk_for(pointer)
        raise ArgumentError.new("large object chunk missing") unless chunk

        bytes_since_gc_sub(payload)
        note_explicit_free(payload)
        live_objects_dec
        @finalizers.notice_reclaim(pointer)
        @large_cached_by_free &+= 1
        with_alloc_lock { cache_large_chunk(chunk, header) }
        trim_large_cache
        Invariant.after_free(self, pointer)
        Trace.after_free(pointer)
        return
      end

      chunk = chunk_for(pointer)
      raise ArgumentError.new("pointer is not a gcry allocation") unless chunk

      class_index = chunk.value.size_class.to_i32
      raise ArgumentError.new("bad size class on chunk") if class_index < 0 || class_index >= SIZE_CLASS_COUNT
      payload = SizeClasses.payload(class_index)

      @finalizers.notice_reclaim(pointer)

      if @bitmap_alloc
        # Clear the `occ` bit and mark the header FREE. No freelist link: the
        # block becomes available the moment its bit is clear, and the pool
        # cursor finds it from `~occ` without a chase through free memory.
        nursery = BlockHeader.nursery?(header)
        with_freelist_lock(class_index, nursery) do
          # `push_size_class_free` poisons on the freelist path and this path
          # does not go through it, so the knob would be armed and inert.
          poison_payload(pointer, payload) if @poison_freed
          BlockHeader.set_free(header, Pointer(Void).null)
          bitmap_free_block(chunk, header)
        end
        free_bytes_add(payload.to_u64)
        bytes_since_gc_sub(payload.to_u64)
        note_explicit_free(payload.to_u64)
        live_objects_dec
        Invariant.after_free(self, pointer)
        Trace.after_free(pointer)
        return
      end

      if @tlab_enabled
        # TLAB free is per-thread; counters are Atomic (no @alloc_lock).
        tlab_free_small(pointer, class_index, payload, BlockHeader.nursery?(header))
        bytes_since_gc_sub(payload.to_u64)
        note_explicit_free(payload.to_u64)
        live_objects_dec
      else
        # Non-TLAB: per-size-class freelist lock; counters are Atomic.
        nursery = BlockHeader.nursery?(header)
        with_freelist_lock(class_index, nursery) do
          push_size_class_free(class_index, nursery, header, pointer, payload)
        end
        free_bytes_add(payload.to_u64)
        bytes_since_gc_sub(payload.to_u64)
        note_explicit_free(payload.to_u64)
        live_objects_dec
      end
      Invariant.after_free(self, pointer)
      Trace.after_free(pointer)
    end

    def is_heap_ptr(pointer : Void*) : Bool
      return false if pointer.null?
      !chunk_containing(pointer.address).nil?
    end

    # Address in the historic mmap span even if the chunk was already
    # index-removed / munmapped and @heap_min/@heap_max were tightened.
    # Used to refuse LibC.realloc/free fallback (glibc "invalid pointer").
    def in_heap_span?(pointer : Void*) : Bool
      return false if pointer.null? || @heap_span_hi == 0 || @heap_span_lo == UInt64::MAX
      addr = pointer.address
      addr >= @heap_span_lo && addr < @heap_span_hi
    end

    def self.round_size(size : UInt64) : UInt64
      SizeClasses.round(size)
    end

    def self.size_class_index(payload : UInt32) : Int32
      SizeClasses.index_of(payload)
    end

    # One emergency collection, run with **no allocator lock held**.
    #
    # `map_chunk` returns null when `mmap` refuses, and a collection may well
    # free the mappings that would let a retry succeed — but it can only run
    # from a caller that has already released its freelist / alloc lock, which
    # is why this is a step at the entry points and not a branch inside
    # `map_chunk`. Returns whether a retry is worth making at all.
    #
    # **Not reentrant, and the guard is its own flag rather than `@collecting`.**
    # A collection allocates — `ensure_static_root_cache` parses
    # `/proc/self/maps` — and at the edge of the address space those
    # allocations fail too. Guarded only by `@collecting`, which is not set for
    # the whole of `collect`, the second failure asks for a third collection
    # and the process dies of stack overflow inside `run_collection` (measured,
    # 3 of 3). One emergency collection at a time, process-wide: a thread that
    # finds the flag taken raises instead, which is the honest answer when
    # another thread is already reclaiming everything there is to reclaim.
    private def retry_after_emergency_collect? : Bool
      return false if @destroyed || @collecting || !@enabled || @tlab_enabled
      return false unless @emergency_collecting.compare_and_set(0, 1)[1]
      begin
        @emergency_collects &+= 1
        collect(scan_stack: true)
      ensure
        @emergency_collecting.set(0)
      end
      true
    end

    @emergency_collecting = Atomic(Int32).new(0)

    # **Raising out of the allocator allocates**, and that is a loop.
    #
    # `raise ex` fills in `ex.callstack ||= Exception::CallStack.new`, a
    # `CallStack` is an `Array`, and an `Array` is an allocation — asked for at
    # the one moment allocation is failing. It recurses: measured **174** frames
    # of `raise → CallStack#unwind → Array → allocate → alloc_old_small → raise`
    # before the stack overflowed, three runs of three, which is how an
    # out-of-memory process died instead of reporting that it was out of memory.
    #
    # So the first raise is the normal one, with a true backtrace, and any raise
    # nested inside it uses this instance — built at boot with its callstack
    # already set, so `raise` finds nothing left to allocate. Its backtrace is
    # the boot stack and says so.
    @oom_error : OutOfMemoryError = begin
      e = OutOfMemoryError.new(
        "out of memory (nested raise; this backtrace is gcry's boot stack, not the allocation site)")
      e.callstack = Exception::CallStack.new
      e
    end
    @oom_raising = Atomic(Int32).new(0)

    private def oom!(message : String) : NoReturn
      if @oom_raising.compare_and_set(0, 1)[1]
        begin
          # Evaluating the argument is what allocates; a failure in there lands
          # back here with the flag set and takes the branch below.
          raise OutOfMemoryError.new(message)
        ensure
          @oom_raising.set(0)
        end
      end
      raise @oom_error
    end

    # How many times an allocation failure asked for a collection and retried.
    # Non-zero means the process has been to the edge of its address space,
    # which is worth knowing before reading anything else in `/gc-stats`.
    getter emergency_collects : UInt64 = 0_u64

    # `alloc_large` plus its byte accounting, under `@alloc_lock`. A separate
    # method only so the entry point can call it twice — once, then again after
    # an emergency collection — without repeating the block.
    private def alloc_large_counted(rounded : UInt64, flags : UInt32) : {Void*, Bool}
      with_alloc_lock do
        u, fc = alloc_large(rounded, flags)
        note_alloc_bytes(rounded) unless u.null?
        {u, fc}
      end
    end

    private def allocate(size : UInt64, atomic : Bool, clear : Bool) : Void*
      raise OutOfMemoryError.new("heap destroyed") if @destroyed

      # Cooperative STW for signal-exempt threads (SYSMON): do not mutate the
      # heap while the collector holds the world stopped.
      wait_if_world_stopped_other_thread

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
        user, from_cache = alloc_large_counted(rounded, flags)
        if user.null?
          # `map_chunk` returned null rather than raising under `@alloc_lock`;
          # the lock is gone by now, so the collection and the error both
          # belong here.
          oom!("mmap failed") unless retry_after_emergency_collect?
          user, from_cache = alloc_large_counted(rounded, flags)
          oom!("mmap failed") if user.null?
        end
        needs_clear = clear && from_cache
      elsif @nursery_enabled
        user = if @tlab_enabled
                 # Counters Atomic inside tlab_alloc_small (no @alloc_lock on hit).
                 tlab_alloc_small(rounded.to_u32, flags | BlockHeader::Flags::NURSERY, class_index, true, rounded)
               else
                 alloc_nursery(rounded.to_u32, flags | BlockHeader::Flags::NURSERY, class_index, rounded)
               end
        needs_clear = clear && !@nursery_freelist_clean[class_index]
      else
        # `&& !@bitmap_alloc`: TLAB is a freelist mechanism and the pool cursor
        # replaces it. Dispatching to it here would bypass the bitmap allocator
        # entirely, so `occ` would never be set and the streaming sweep — which
        # trusts `occ` completely — would reclaim every live object.
        user = if @tlab_enabled && !@bitmap_alloc
                 tlab_alloc_small(rounded.to_u32, flags, class_index, false, rounded)
               else
                 alloc_old_small(rounded.to_u32, flags, class_index, rounded)
               end
        needs_clear = clear && !@freelist_clean[class_index]
      end

      # `GCRY_ALWAYS_CLEAR=1` — research arm. Every skip above is a claim that
      # the bytes are already zero: `MAP_ANONYMOUS` for a fresh chunk,
      # `@freelist_clean` for a refill that came straight off one. Crystal
      # relies on that: `Reference.allocate` zeroes nothing itself, so an ivar
      # the initializer does not assign reads whatever the previous occupant
      # left. A stale pointer arriving that way is the one story that fits the
      # acikturkiye crash — nothing referenced the block when it died, and the
      # mutator writes into it afterwards through a field it never set.
      needs_clear = true if @always_clear && !user.null?
      user.as(UInt8*).clear(rounded) if needs_clear
      # EXPERIMENT (GCRY_BIRTH_GRACE=1, src/gcry/birth_grace.cr): a block is
      # unreachable to the collector between here and the caller's store.
      note_birth(user) if @birth_grace
      user
    end

    # Atomic counters are *implied* by the bitmap allocator, expressed here as a
    # read rather than as an assignment in `initialize`.
    #
    # Two attempts to set the flag there both failed, and both only under
    # `-Dgc_none`: an ivar write before the declared default makes Crystal infer
    # `Bool | Nil` and breaks `@@default_heap ||= Heap.new`, and the property
    # setter trips "self was used before initializing @freelists". Neither is
    # visible to `crystal spec`, which runs under Boehm and never reaches that
    # line — the same blind spot that hid the radix boot crash.
    #
    # Why it is implied at all: the streaming sweep settles a whole chunk's
    # reclaim with one `live_objects_sub(freed)` over a bitmap other threads are
    # allocating into. The default non-atomic get/set is chosen deliberately to
    # keep a LOCK off the EC1 alloc path, and a lost update there costs one
    # object when the header arm decrements per block — but the entire batch
    # here.
    @[AlwaysInline]
    private def counters_atomic? : Bool
      @heap_counters_atomic || @bitmap_alloc
    end

    # Parallel: Atomic RMW. EC1: plain get/set (no LOCK on the alloc hot path).
    private def note_alloc_bytes(rounded : UInt64) : Nil
      if counters_atomic?
        @total_bytes.add(rounded)
        @bytes_since_gc.add(rounded)
        @live_objects.add(1_u64)
      else
        @total_bytes.set(@total_bytes.get &+ rounded)
        @bytes_since_gc.set(@bytes_since_gc.get &+ rounded)
        @live_objects.set(@live_objects.get &+ 1_u64)
      end
    end

    private def free_bytes_sub(n : UInt64) : Nil
      if counters_atomic?
        loop do
          cur = @free_bytes.get
          nxt = cur >= n ? cur - n : 0_u64
          break if @free_bytes.compare_and_set(cur, nxt)[1]
        end
      else
        cur = @free_bytes.get
        @free_bytes.set(cur >= n ? cur - n : 0_u64)
      end
    end

    private def bytes_since_gc_sub(n : UInt64) : Nil
      if counters_atomic?
        loop do
          cur = @bytes_since_gc.get
          nxt = cur > n ? cur - n : 0_u64
          break if @bytes_since_gc.compare_and_set(cur, nxt)[1]
        end
      else
        cur = @bytes_since_gc.get
        @bytes_since_gc.set(cur > n ? cur - n : 0_u64)
      end
    end

    # Mutator free / Parallel: CAS. STW sweep is single-threaded (world
    # stopped) — plain set matches pre-atomic bebedae and avoids a CAS per
    # dead object (was ~half of phase_sweep on Kemal EC1).
    private def live_objects_dec : Nil
      live_objects_sub(1_u64)
    end

    private def live_objects_sub(n : UInt64) : Nil
      return if n == 0
      if @collecting || !@heap_counters_atomic
        cur = @live_objects.get
        @live_objects.set(cur > n ? cur - n : 0_u64)
        return
      end
      loop do
        cur = @live_objects.get
        nxt = cur > n ? cur - n : 0_u64
        break if @live_objects.compare_and_set(cur, nxt)[1]
      end
    end

    private def free_bytes_add(n : UInt64) : Nil
      if @collecting || !@heap_counters_atomic
        @free_bytes.set(@free_bytes.get &+ n)
      else
        @free_bytes.add(n)
      end
    end

    private def alloc_nursery(payload : UInt32, flags : UInt32, index : Int32, rounded : UInt64) : Void*
      user = alloc_nursery_locked(payload, flags, index)
      if user.null?
        oom!("failed to refill nursery size class #{payload}") unless retry_after_emergency_collect?
        user = alloc_nursery_locked(payload, flags, index)
        oom!("failed to refill nursery size class #{payload}") if user.null?
      end
      free_bytes_sub(payload.to_u64)
      @nursery_alloc_bytes.add(payload.to_u64)
      note_alloc_bytes(rounded)
      user
    end

    private def alloc_nursery_locked(payload : UInt32, flags : UInt32, index : Int32) : Void*
      with_freelist_lock(index, true) do
        u = @nursery_freelists[index]

        if u.null?
          refill_size_class(index, payload, nursery: true)
          u = @nursery_freelists[index]
          return Pointer(Void).null if u.null?
        end

        if @blacklist_enabled
          taken = take_non_blacklisted(u, index, true)
          if taken.null?
            header = BlockHeader.from_user(u)
            @nursery_freelists[index] = header.value.next_free
          else
            u = taken
          end
        else
          header = BlockHeader.from_user(u)
          @nursery_freelists[index] = header.value.next_free
        end

        header = BlockHeader.from_user(u)
        BlockHeader.set_used(header, payload, flags)
        if @incremental_marking || @collecting
          heap_set_mark(header)
        end
        u
      end
    end

    private def alloc_old_small(payload : UInt32, flags : UInt32, index : Int32, rounded : UInt64) : Void*
      # `&& !@bitmap_alloc`: the batched path builds and drains a freelist run,
      # so it would bypass `occ` entirely. The comment below used to claim
      # alloc_batch was "inert by construction" under the bitmap representation;
      # it is not — `bitmap_alloc=` forces `@tlab_enabled = false`, which *opens*
      # this gate rather than closing it.
      if @alloc_batch > 0 && !@tlab_enabled && !@bitmap_alloc
        return alloc_old_small_batched(payload, flags, index, rounded)
      end

      # Tight-grow: never collect under the freelist lock (STW vs lock deadlock).
      # If both prefer+global are empty, GC once outside the lock, then refill.
      if @tight_grow && @tight_grow_gc && !@collecting && @enabled && !@tlab_enabled
        empty = with_freelist_lock(index, false) do
          @prefer_freelists[index].null? && @freelists[index].null?
        end
        # Collect before grow only when the small heap is already sparse —
        # otherwise this becomes a thr-killing STW storm (seen: ~1k majors/30s).
        min_bsg = @gc_threshold >> 2
        min_bsg = 1_048_576_u64 if min_bsg < 1_048_576_u64
        sm = small_mapped_bytes
        sf = small_free_bytes
        sparse = sm > 0 && sf * 100 >= sm * @tight_grow_gc_pct.to_u64
        if empty && sparse && @bytes_since_gc.get >= min_bsg
          @tight_grow_collects &+= 1
          collect(scan_stack: true)
        end
      end

      user = with_freelist_lock(index, false) { alloc_old_small_locked(payload, flags, index) }
      if user.null?
        # The freelist lock is gone by now, so both the collection and the
        # raise are legal here — neither was inside `map_chunk`.
        oom!("failed to refill size class #{payload}") unless retry_after_emergency_collect?
        user = with_freelist_lock(index, false) { alloc_old_small_locked(payload, flags, index) }
        oom!("failed to refill size class #{payload}") if user.null?
      end
      free_bytes_sub(payload.to_u64)
      note_alloc_bytes(rounded)
      user
    end

    # Freelist lock held. Prefer-list first (tight_grow), then global, then map.
    private def alloc_old_small_locked(payload : UInt32, flags : UInt32, index : Int32) : Void*
      # Bitmap representation: the pool cursor replaces the freelist outright.
      # Not *beside* it — an `occ` bitmap maintained alongside a freelist is the
      # 2026-08-01 design that went to 54k->44k on /json. See bitmap_alloc.cr.
      #
      # tight_grow and prefer_freelists are freelist-shaped and unreachable from
      # here; alloc_batch is excluded explicitly at the entry point above,
      # because it is *not* inert by construction.
      # Old generation only. `alloc_nursery` keeps the freelist because nursery
      # chunks keep the header representation — see `sweep_small_blocks`.
      if @bitmap_alloc
        return bitmap_alloc_locked(index, payload, flags)
      end

      u = Pointer(Void).null
      prefer_hit = false
      if @tight_grow
        u = @prefer_freelists[index]
        prefer_hit = !u.null?
      end
      if u.null?
        u = @freelists[index]
        prefer_hit = false
      end

      if u.null?
        refill_size_class(index, payload, nursery: false)
        if @tight_grow
          u = @prefer_freelists[index]
          prefer_hit = !u.null?
        end
        if u.null?
          u = @freelists[index]
          prefer_hit = false
        end
        # Null, not a raise: the freelist lock is held here and `raise`
        # allocates. `alloc_old_small` turns this into an `OutOfMemoryError`
        # after the lock is gone.
        return Pointer(Void).null if u.null?
      end

      if @blacklist_enabled
        if @tight_grow
          fold_prefer_into_global(index)
          prefer_hit = false
          u = @freelists[index]
          if u.null?
            refill_size_class(index, payload, nursery: false)
            fold_prefer_into_global(index) if @tight_grow
            u = @freelists[index]
            return Pointer(Void).null if u.null?
          end
        end
        taken = take_non_blacklisted(u, index, false)
        if taken.null?
          header = BlockHeader.from_user(u)
          @freelists[index] = header.value.next_free
        else
          u = taken
        end
      else
        header = BlockHeader.from_user(u)
        nxt = header.value.next_free
        if prefer_hit
          @prefer_freelists[index] = nxt
          @tight_grow_prefer_allocs &+= 1
        else
          @freelists[index] = nxt
        end
      end

      header = BlockHeader.from_user(u)
      BlockHeader.set_used(header, payload, flags)
      heap_set_mark(header) if @incremental_marking || @collecting
      u
    end

    # Fill a block's payload with a pattern that is neither zero nor a pointer,
    # so that a use-after-free reads something no one can mistake for data and
    # dereferences to an address no one can mistake for a heap address. The
    # 2026-08-10 soak died on `0x7f1700000149` — a value plausible enough that
    # three sessions have argued about what it was. `0xdeadf2ee…` is not.
    #
    # Sound because the freelist link lives in the *header* (`next_free`), not in
    # the payload, so nothing the collector reads afterwards is in this range —
    # and because every path that gets here sets `@freelist_clean` false, so a
    # later `malloc(clear: true)` still zeroes what it hands out. That pairing is
    # the whole safety argument: `bench/poison_freed.cr` gates both halves.
    POISON_WORD = 0xDEADF2EEDEADF2EE_u64

    # Tagged poison (`GCRY_POISON_TAG=1`). Same job as `POISON_WORD` and one more:
    # the low 48 bits carry the address of the block that was freed, so a crash
    # that reads it can say *which* free wrote it instead of only that some free
    # did. `POISON_WORD` answers "use-after-free"; this answers "of what".
    #
    # Still non-canonical — bits 63:48 are `0xDEAD` and bit 47 of a user-space
    # address is 0 — so it faults exactly like the untagged word, with the same
    # `si_addr == 0` from #GP that made the register scan necessary in the first
    # place. And 48 bits is the whole of an x86_64 user address, so nothing about
    # the block is lost. `POISON_WORD >> 48` is `0xDEAD` too, which is why the
    # reader checks the exact word first and only then reads the tag.
    POISON_TAG       = 0xDEAD_u64 << 48
    POISON_TAG_MASK  = 0xFFFF_u64 << 48
    POISON_ADDR_MASK = (1_u64 << 48) - 1

    # Default **on**; `GCRY_STAGED_WAIT=0` opts out. See
    # `wait_for_staged_threads` and
    # `bench/log/linux/2026-08-17-thread-birth-window/FINDINGS.md`.
    property staged_wait : Bool = true

    # Collections that waited for a staged thread, and those that gave up.
    getter stw_staged_waits : UInt64 = 0_u64
    getter stw_staged_wait_timeouts : UInt64 = 0_u64

    # Spin, briefly, while a thread is known to exist and not be published.
    # Called from `stop_world` **before** `Thread.lock` — see the note there.
    STAGED_WAIT_SPINS = 2000

    # What the wait saw, for the collection that is about to run. Read after the
    # fact by the dying-type audit's precondition report
    # (src/gcry/thread_block_audit.cr), and recorded here because it cannot be
    # recovered later: this wait either drains a staged entry or drops it, so
    # `Platform.staged_count` is **zero by construction** by the time anything
    # downstream looks. The first version of that report asked it anyway and got
    # a zero it could not have got anything else from.
    getter staged_seen_at_stop : UInt64 = 0_u64
    getter staged_timed_out_at_stop : Bool = false

    # The ids themselves, not just how many. A dying `Thread` whose
    # `@system_handle` is one of these *is* the thread that was being born —
    # which is the difference between a coincidence in the same collection and
    # an identification. Recorded at wait entry because the timeout path drops
    # every entry before anything downstream could read them.
    STAGED_SNAPSHOT_SLOTS = 8

    @staged_ids_at_stop = uninitialized StaticArray(UInt64, STAGED_SNAPSHOT_SLOTS)
    getter staged_ids_at_stop_count : Int32 = 0

    def staged_id_at_stop?(id : UInt64) : Bool
      i = 0
      while i < @staged_ids_at_stop_count
        return true if @staged_ids_at_stop[i] == id
        i += 1
      end
      false
    end

    private def wait_for_staged_threads : Nil
      @staged_seen_at_stop = Platform.staged_count.to_u64
      @staged_timed_out_at_stop = false
      @staged_ids_at_stop_count = 0
      Platform.each_staged do |id|
        next if @staged_ids_at_stop_count >= STAGED_SNAPSHOT_SLOTS
        @staged_ids_at_stop[@staged_ids_at_stop_count] = id
        @staged_ids_at_stop_count += 1
      end
      return if Platform.staged_count == 0
      @stw_staged_waits &+= 1
      spins = 0
      while Platform.staged_count > 0
        # Release whatever has published itself since the last look. Without
        # this the loop cannot ever succeed: staging entries were only dropped
        # by `stop_world`'s own walk, which runs *after* this wait, so the count
        # could not fall while the wait watched it. Measured before the fix —
        # 68 waits, 68 timeouts, every one — and the census gap closing anyway,
        # which made it look like the wait worked when what worked was the delay.
        drain_published_staged
        break if Platform.staged_count == 0
        if spins >= STAGED_WAIT_SPINS
          @stw_staged_wait_timeouts &+= 1
          @staged_timed_out_at_stop = true
          # Drop what did not answer. A thread that dies before publishing
          # leaves an entry nothing will ever release, and without this every
          # later collection would pay the full spin and time out again — a
          # permanent cost bought by a thread that no longer exists. Dropping
          # loses the record, which is the lesser harm and is counted.
          Platform.each_staged { |id| Platform.unstage_thread(id) }
          return
        end
        spins += 1
        Intrinsics.pause
      end
    end

    # A staged id that now appears in Crystal's list has published itself; the
    # ordinary path covers it from here. `Thread.unsafe_each` without the list
    # mutex on purpose — this runs *before* `Thread.lock`, and taking it here
    # would deadlock against the very push being waited for.
    private def drain_published_staged : Nil
      Platform.each_staged do |id|
        published = false
        Thread.unsafe_each do |thread|
          published = true if thread.to_unsafe.unsafe_as(UInt64) == id
        end
        Platform.unstage_thread(id) if published
      end
    end

    # `GCRY_THREAD_CENSUS=1`. See src/gcry/platform/linux_thread_census.cr.
    property thread_census : Bool = false

    # Collections where the OS reported more threads than Crystal's list
    # yielded, and the largest such difference. A gap is a thread running
    # through the stopped world.
    getter thread_census_checks : UInt64 = 0_u64
    getter thread_census_gaps : UInt64 = 0_u64
    getter thread_census_gap_max : Int32 = 0
    # Collections where /proc could not answer — counted, so "no gaps" can
    # never be the result of never having looked.
    getter thread_census_unanswered : UInt64 = 0_u64
    # Gaps gcry's own staging record accounted for.
    getter thread_census_staged_covered : UInt64 = 0_u64

    private def census_threads(listed : Int32) : Nil
      @thread_census_checks &+= 1
      os = Platform.os_thread_count
      unless os
        @thread_census_unanswered &+= 1
        return
      end
      gap = os - listed
      staged = Platform.staged_count
      @thread_census_staged_covered &+= 1 if gap > 0 && staged >= gap
      return if gap <= 0
      @thread_census_gaps &+= 1
      @thread_census_gap_max = gap if gap > @thread_census_gap_max
      return if @thread_census_gaps > 4

      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: thread census — the OS reports ")
      len = RawOut.append_u64(buf.to_unsafe, len, os.to_u64)
      len = RawOut.append(buf.to_unsafe, len, " thread(s) and Crystal's list yielded ")
      len = RawOut.append_u64(buf.to_unsafe, len, listed.to_u64)
      len = RawOut.append(buf.to_unsafe, len, ", so ")
      len = RawOut.append_u64(buf.to_unsafe, len, gap.to_u64)
      len = RawOut.append(buf.to_unsafe, len,
        " thread(s) are outside Crystal's list; gcry has staged ")
      len = RawOut.append_u64(buf.to_unsafe, len, staged.to_u64)
      len = RawOut.append(buf.to_unsafe, len,
        staged >= gap ? " of them, so it knows they exist. collection " : ", fewer than the gap — at least one is unrecorded. collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # Opt-in on top of `@poison_freed`: it makes every freed block's payload
    # differ, which a future reader might be tempted to rely on for equality.
    property poison_tag_addr : Bool = false

    private def poison_payload(pointer : Void*, payload : UInt32) : Nil
      word = if @poison_tag_addr
               POISON_TAG | (pointer.address & POISON_ADDR_MASK)
             else
               POISON_WORD
             end
      words = pointer.as(UInt64*)
      n = payload // sizeof(UInt64)
      i = 0
      while i < n
        words[i] = word
        i += 1
      end
      @poisoned_blocks &+= 1
    end

    # *swept* records which path gave the block back — the sweep's freelist link
    # or an explicit `Heap#free`. It rides in the header (`Flags::SWEPT`) so a
    # crash report can say it; nothing in the allocator reads it back.
    private def push_size_class_free(class_index : Int32, nursery : Bool, header : BlockHeader*, pointer : Void*, payload : UInt32, swept : Bool = false) : Nil
      poison_payload(pointer, payload) if @poison_freed
      flags = BlockHeader::Flags::FREE
      flags |= BlockHeader::Flags::SWEPT if swept
      if nursery
        header.value = BlockHeader.new(payload, flags, @nursery_freelists[class_index])
        @nursery_freelists[class_index] = pointer
        @nursery_freelist_clean[class_index] = false
        return
      end
      if @tight_grow && tight_addr_in_grow?(class_index, pointer.address)
        header.value = BlockHeader.new(payload, flags, @prefer_freelists[class_index])
        @prefer_freelists[class_index] = pointer
        @freelist_clean[class_index] = false
      else
        header.value = BlockHeader.new(payload, flags, @freelists[class_index])
        @freelists[class_index] = pointer
        @freelist_clean[class_index] = false
      end
    end

    private def tight_addr_in_grow?(index : Int32, addr : UInt64) : Bool
      lo = @grow_lo[index]
      return false if lo == 0
      addr >= lo && addr < @grow_hi[index]
    end

    private def fold_prefer_into_global(index : Int32) : Nil
      splice = @prefer_freelists[index]
      return if splice.null?
      tail = splice
      loop do
        th = BlockHeader.from_user(tail)
        nxt = th.value.next_free
        break if nxt.null?
        tail = nxt
      end
      th = BlockHeader.from_user(tail)
      th.value = BlockHeader.new(th.value.size, BlockHeader::Flags::FREE, @freelists[index])
      @freelists[index] = splice
      @prefer_freelists[index] = Pointer(Void).null
    end

    private def refill_size_class(index : Int32, payload : UInt32, nursery : Bool = false) : Nil
      if revive_dormant_chunk(index, payload, nursery)
        return
      end

      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      chunk_flags = nursery ? ChunkHeader::Flags::NURSERY : 0_u32
      chunk = map_chunk(@small_chunk_bytes, index.to_u32, chunk_flags)
      # Out of address space. The freelist stays empty and the caller sees a
      # null allocation, which is what the entry point retries on.
      return if chunk.null?
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
      elsif @tight_grow
        # Merge prior prefer into global, then install new chunk as prefer.
        splice = @prefer_freelists[index]
        unless splice.null?
          # append global onto end of prefer chain, then move all to global
          tail = splice
          loop do
            th = BlockHeader.from_user(tail)
            nxt = th.value.next_free
            break if nxt.null?
            tail = nxt
          end
          th = BlockHeader.from_user(tail)
          th.value = BlockHeader.new(th.value.size, BlockHeader::Flags::FREE, @freelists[index])
          @freelists[index] = splice
          @prefer_freelists[index] = Pointer(Void).null
        end
        @grow_lo[index] = ChunkHeader.data_start(chunk).address
        @grow_hi[index] = ChunkHeader.data_end(chunk).address
        @prefer_freelists[index] = free_head
        @freelist_clean[index] = true
        @tight_grow_maps &+= 1
      else
        @freelists[index] = free_head
        @freelist_clean[index] = true
      end
      @free_bytes.add(added)
    end

    # Fault a dormant empty chunk back in and install its freelist.
    private def revive_dormant_chunk(index : Int32, payload : UInt32, nursery : Bool) : Bool
      chunk = @chunks
      while chunk
        if !ChunkHeader.large?(chunk) &&
           ChunkHeader.dormant?(chunk) &&
           chunk.value.size_class == index.to_u32 &&
           ChunkHeader.nursery?(chunk) == nursery
          # A revival that lands inside the post-STW dormant pass is the shape
          # that would let that pass madvise a chunk this thread is about to
          # hand blocks out of. Counted here, where both facts are in hand.
          @dormant_revive_during_flush &+= 1 if @dormant_flush_active
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
          elsif @tight_grow
            fold_prefer_into_global(index)
            @grow_lo[index] = ChunkHeader.data_start(chunk).address
            @grow_hi[index] = ChunkHeader.data_end(chunk).address
            @prefer_freelists[index] = free_head
            @freelist_clean[index] = true
          else
            @freelists[index] = free_head
            @freelist_clean[index] = true
          end
          @free_bytes.add(added)
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
        ThreadListWatch.check(header.address, BlockHeader::SIZE.to_u64, ThreadListWatch::SITE_HDR_WRITE)
        BlockHeader.set_used(header, payload.to_u32!, flags | BlockHeader::Flags::LARGE)
        heap_set_mark(header) if @incremental_marking || @collecting
        return {user, true}
      end

      @large_cache_misses += 1

      chunk = map_chunk(mapped, UInt32::MAX, 0_u32)
      return {Pointer(Void).null, false} if chunk.null?
      trace_large_map(chunk, mapped, payload) if @trace_large
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
      # Already on a freelist. Inserting it a second time puts one block in the
      # bucket chain twice, and `take_large_free` then hands the same memory to
      # two owners while `trim_large_cache` is still free to unmap it under
      # both. Counted rather than raised: this runs inside the sweep.
      if BlockHeader.free?(header)
        @large_cached_twice &+= 1
        return
      end
      mapped = chunk.value.mapped_bytes
      ThreadListWatch.check(chunk.as(Void*).address, mapped, ThreadListWatch::SITE_CACHE_IN)
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
      poison_payload(user, payload) if @poison_freed
      ThreadListWatch.check(header.address, BlockHeader::SIZE.to_u64, ThreadListWatch::SITE_HDR_WRITE)
      header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE | BlockHeader::Flags::LARGE, Pointer(Void).null)
      if tail.null?
        @large_freelists[bucket] = user
      else
        ThreadListWatch.check(BlockHeader.from_user(tail).address, BlockHeader::SIZE.to_u64, ThreadListWatch::SITE_LINK_WRITE)
        th = BlockHeader.from_user(tail)
        tv = th.value
        tv.next_free = user
        th.value = tv
      end
      @free_bytes.add(mapped)
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
          # A bucket chain should only ever hold FREE blocks. A USED one means
          # the block was handed out already and something put it back, or
          # never took it off.
          @large_taken_used &+= 1 unless BlockHeader.free?(header)
          if prev.null?
            @large_freelists[b] = nxt
          else
            ThreadListWatch.check(BlockHeader.from_user(prev).address, BlockHeader::SIZE.to_u64, ThreadListWatch::SITE_LINK_WRITE)
            ph = BlockHeader.from_user(prev)
            pv = ph.value
            pv.next_free = nxt
            ph.value = pv
          end
          mapped = chunk.value.mapped_bytes
          ThreadListWatch.check(chunk.as(Void*).address, mapped, ThreadListWatch::SITE_CACHE_OUT)
          free_bytes_sub(mapped)
          @large_free_bytes -= mapped if @large_free_bytes >= mapped
          @large_cache_hits += 1
          return user
        end
        prev = user
        user = nxt
      end
      nil
    end

    # Unmap a detached chain (linked by `next_free`). Caller holds
    # `@alloc_lock`, which is what keeps a flush walk from starting underneath.
    protected def release_large_chain(chain : Void*) : Nil
      user = chain
      while user
        header = BlockHeader.from_user(user)
        chunk = (header.as(UInt8*) - ChunkHeader::SIZE).as(ChunkHeader*)
        nxt = header.value.next_free
        mapped = chunk.value.mapped_bytes
        base = chunk.as(Void*).address
        unless guard_release(base, mapped, GUARD_KIND_LARGE) ||
               refuse_live_release(base, mapped, GUARD_KIND_LARGE) ||
               quarantine_release(base, mapped)
          LibC.munmap(chunk.as(Void*), LibC::SizeT.new(mapped))
        end
        user = nxt
      end
    end

    # Splice a detached chain (linked by `next_free`) onto the pending-release
    # queue. Caller holds `@alloc_lock`.
    # `GCRY_TRACE_LARGE=1`. Raw `write(2)`: this runs on the allocation path and
    # must not allocate.
    private def trace_large_map(chunk : ChunkHeader*, mapped : UInt64, payload : UInt64) : Nil
      return if chunk.null?
      buf = uninitialized UInt8[160]
      p = buf.to_unsafe
      len = RawOut.append(p, 0, "gcry: large map base=0x")
      len = RawOut.append_hex(p, len, chunk.as(Void*).address)
      len = RawOut.append(p, len, " mapped=")
      len = RawOut.append_u64(p, len, mapped)
      len = RawOut.append(p, len, " payload=")
      len = RawOut.append_u64(p, len, payload)
      len = RawOut.append(p, len, " coll=")
      len = RawOut.append_u64(p, len, @collections)
      len = RawOut.append(p, len, "\n")
      RawOut.flush(p, len)
    end

    private def queue_large_release(chain : Void*) : Nil
      user = chain
      while user
        header = BlockHeader.from_user(user)
        chunk = (header.as(UInt8*) - ChunkHeader::SIZE).as(ChunkHeader*)
        nxt = header.value.next_free
        ThreadListWatch.check(header.address, BlockHeader::SIZE.to_u64, ThreadListWatch::SITE_LINK_WRITE)
        hv = header.value
        hv.next_free = @pending_large_release
        header.value = hv
        @pending_large_release = user
        @pending_large_release_bytes += chunk.value.mapped_bytes
        user = nxt
      end
    end

    # Munmap cached large objects until @large_free_bytes <= *limit*.
    # Call outside STW — munmap of many VMAs is slow on Linux.
    # Hard-capped by LARGE_CACHE_LIMIT even if retain is set higher.
    # Detach under `@alloc_lock`, unmap outside it.
    #
    # This used to do both without the lock, while `alloc_large` →
    # `take_large_free` walks the very same `@large_freelists` **holding**
    # `@alloc_lock`. So an allocating thread could take a chunk off the list and
    # hand it to the mutator while a peer trimming the cache walked past the
    # same entry and `munmap`ed it: a live buffer, just issued, unmapped under
    # its owner. That is the acikturkiye use-after-free — a 69 632-byte large
    # chunk released by this path with the write landing in the same collection
    # cycle, in a run where `GCRY_MARK_AUDIT` reported no missing heap edge and
    # `GCRY_SOUND=1` changed nothing, because the mark was never the problem
    # (`bench/log/linux/2026-08-23-acik-crash/FINDINGS.md`).
    #
    # The list mutation is serialised now; the syscalls still are not, which is
    # the property the old comment was protecting — `munmap` of many VMAs is
    # slow on Linux and holding the allocator across it would stall every
    # mutator. Same shape as the empty-chunk path: decide under the lock, tear
    # down after it.
    #
    # `GCRY_TRIM_UNLOCKED=1` restores the old behaviour for the gate.
    def trim_large_cache(limit : UInt64 = @large_cache_retain, defer : Bool = true) : Nil
      effective = limit > LARGE_CACHE_LIMIT ? LARGE_CACHE_LIMIT : limit
      return if @large_free_bytes <= effective

      detached = Pointer(Void).null # chain of users, linked by next_free
      detach = -> do
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
            free_bytes_sub(mapped)
            @large_free_bytes -= mapped if @large_free_bytes >= mapped
            @large_mapped_bytes -= mapped if @large_mapped_bytes >= mapped
            @unmapped_bytes += mapped
            hv = header.value
            hv.next_free = detached
            header.value = hv
            detached = user
            user = nxt
          end
          b -= 1
        end
      end

      if @trim_unlocked
        # A faithful control has to reproduce the *interleaving*, not just the
        # missing lock: the original unmapped each chunk while still walking the
        # list, so a peer inside `take_large_free` could take an entry that was
        # about to be torn down. Detaching everything first and unmapping after
        # narrows that window even without the lock — the first version of this
        # control did exactly that and produced 0 of 24, which said nothing.
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
            free_bytes_sub(mapped)
            @large_free_bytes -= mapped if @large_free_bytes >= mapped
            @large_mapped_bytes -= mapped if @large_mapped_bytes >= mapped
            @unmapped_bytes += mapped
            unless guard_release(chunk.as(Void*).address, mapped, GUARD_KIND_LARGE)
              LibC.munmap(chunk.as(Void*), LibC::SizeT.new(mapped))
            end
            user = nxt
          end
          b -= 1
        end
        update_heap_bounds_after_unmap
        return
      end
      with_alloc_lock { detach.call }

      # Off the list and out of the index, but for a mutator that is as far as
      # it goes. After `start_world` the collector walks `@chunks` in the three
      # `flush_pending_*` passes holding no lock, reading — and, in the
      # mostly-empty pass, writing — each chunk's header before it looks at any
      # flag. A mutator that unmaps one of those chunks mid-walk is a use after
      # free at best; at worst the walk's `madvise(MADV_DONTNEED)`, computed
      # from a header the kernel has already reissued to somebody else's
      # `mmap`, zeroes live memory with nothing to show for it.
      #
      # So a mutator releases only when it can see that no walk is in flight,
      # and queues for the collector when one is. Deferring *unconditionally*
      # is not an option: the queue then drains once per collection, and a
      # `GC.free` loop parks gigabytes of detached-but-mapped chunks until the
      # next one — measured as a null `mmap` and a fault at 0x18.
      #
      # `defer: false` is for the collector's own trims, which run outside the
      # walks by construction and can keep their syscalls off the lock.
      if defer && !@trim_immediate
        deferred = false
        with_alloc_lock do
          if @live_chunk_walk
            @live_walk_queued &+= 1
            queue_large_release(detached)
            deferred = true
          else
            @live_walk_direct &+= 1
            release_large_chain(detached)
          end
        end
        if deferred
          return
        else
          with_alloc_lock { update_heap_bounds_after_unmap }
          return
        end
      end

      # Nothing can hand these out now.
      user = detached
      while user
        header = BlockHeader.from_user(user)
        chunk = (header.as(UInt8*) - ChunkHeader::SIZE).as(ChunkHeader*)
        nxt = header.value.next_free
        mapped = chunk.value.mapped_bytes
        base = chunk.as(Void*).address
        unless guard_release(base, mapped, GUARD_KIND_LARGE) ||
               refuse_live_release(base, mapped, GUARD_KIND_LARGE) ||
               quarantine_release(base, mapped)
          LibC.munmap(chunk.as(Void*), LibC::SizeT.new(mapped))
        end
        user = nxt
      end
      # Also under the lock: it walks the chunk list and rewrites `@heap_min` /
      # `@heap_max`, which `find_block` reads to decide whether an address is
      # ours at all. Unsynchronised, a peer mapping or unmapping a chunk during
      # the walk leaves those bounds describing a heap that no longer exists.
      # Serialising the detach alone left `make large-cache-race` failing 2 of 5
      # on the locked arm; with this it is 0.
      if @trim_unlocked
        update_heap_bounds_after_unmap
      else
        with_alloc_lock { update_heap_bounds_after_unmap }
      end
    end

    # Size-class mapped bytes (heap_size minus large VMAs).
    def small_mapped_bytes : UInt64
      @heap_size >= @large_mapped_bytes ? @heap_size - @large_mapped_bytes : 0_u64
    end

    # Freelist bytes in size-class chunks (excludes large freelist).
    def small_free_bytes : UInt64
      fb = @free_bytes.get
      fb >= @large_free_bytes ? fb - @large_free_bytes : 0_u64
    end

    # Null on failure, and **never a raise**: every caller holds a
    # non-reentrant `Crystal::SpinLock` across this call — `alloc_large` inside
    # `with_alloc_lock`, `refill_size_class` inside the size-class freelist
    # lock — and in Crystal `raise` allocates. It builds a `CallStack`, which
    # is an `Array`, which goes straight back into `allocate` and takes the
    # very lock this thread is holding. Measured under `ulimit -v`: **5 of 5**
    # children spinning at 100% CPU forever, `SpinLock#lock` under
    # `CallStack#unwind` under `raise` under `map_chunk`, with no output and no
    # OOM error. An emergency collection from here is the same mistake one step
    # further on — the after-world sweep takes `freelist_lock_ptr(class_index)`
    # and `flush_pending_large_release` opens with `with_alloc_lock` — and it
    # used to live right here, excluded only for TLAB although the TLAB-off
    # refill holds a freelist lock just the same.
    #
    # So: fail quietly, let the caller unwind out of its lock, and leave both
    # the collection and the raise to the allocation entry points, where no
    # allocator lock is held. `alloc_old_small` already states the rule at its
    # own tight-grow collect: never collect under the freelist lock.
    private def map_chunk(bytes : UInt64, size_class : UInt32, flags : UInt32 = 0_u32) : ChunkHeader*
      ptr = mmap_anonymous(bytes)
      return Pointer(ChunkHeader).null if Gcry.mmap_failed?(ptr)

      # Linux: disable THP on GC-managed mmaps. THP can inflate RSS by
      # rounding 128 KiB chunks up to 2 MiB huge pages — madvise on a
      # partially-filled huge page does not reclaim the full 2 MiB even
      # when only 4 KiB is live. Base pages let MADV_DONTNEED / MADV_COLD
      # reclaim at 4 KiB granularity, keeping RSS proportional to the
      # live object set.
      {% if flag?(:linux) %}
        LibC.madvise(ptr, LibC::SizeT.new(bytes), Platform::MADV_NOHUGEPAGE)
      {% end %}

      chunk = ptr.as(ChunkHeader*)

      # Carve the metadata region. `mmap` hands back zeroed pages, so both
      # bitmaps start clear with no work — a chunk is born with nothing marked
      # and nothing occupied, which is exactly right.
      #
      # Large chunks never get one: they hold a single object, so there is
      # nothing to amortise, and a bitmap region would move `data_start` and
      # break the twelve sites that recover a large chunk as
      # `header - ChunkHeader::SIZE`.
      bitmap_words = 0_u32
      data_offset = ChunkHeader::SIZE.to_u32
      if @bitmap_marks && size_class != UInt32::MAX &&
         size_class < SIZE_CLASS_COUNT.to_u32
        bitmap_words, data_offset =
          Heap.chunk_geometry(@block_bytes[size_class.to_i32], bytes, true)
      end

      # Prepend and index-insert under the **one** lock that guards `@chunks`.
      #
      # This list used to be mutated under two: `unlink_chunk` holds
      # `@alloc_lock`, and this path reaches here from `refill_size_class`
      # holding only the size-class freelist lock. A prepend interleaved with
      # an unlink can leave the unlinked chunk reachable through `next` — the
      # predecessor search reads a head that changes under it — and the chunk
      # is then unmapped while still on the list. Every later walker
      # dereferences freed memory; `large_cache_race` children die on the
      # chunk's own base with `update_heap_bounds_after_unmap` on the stack
      # (`bench/log/linux/2026-08-25-aarch64-large-cache-locked-arm`).
      #
      # A lock of its own, not `@alloc_lock` and not `@index_lock`. Not
      # `@alloc_lock`: the large path already holds it across `alloc_large` →
      # `map_chunk` and the spinlock is not reentrant. Not `@index_lock`: the
      # unlink walks the list to find a predecessor, and holding the index lock
      # across that starves every `chunk_containing` — measured as a Darwin job
      # going from 1m50s to a 20-minute timeout. Order is list → index.
      @chunk_list_lock.sync do
        chunk.value = ChunkHeader.new(@chunks, bytes, size_class, flags, data_offset, bitmap_words)
        # Release store: the in-STW sweep and `each_chunk` walk this list
        # unlocked, and a mutator can be suspended between these two stores.
        # Frozen in SOURCE order the new chunk is merely invisible (it holds
        # nothing live yet); but nothing except this fence stops the compiler
        # sinking the header init past the head publish, and a frozen thread
        # between the REORDERED stores hands the walker an uninitialised
        # `next`. Same discipline as `index_insert_locked`'s count store.
        Atomic::Ops.store(pointerof(@chunks), chunk, :release, true)
        index_insert(chunk)
      end
      @heap_size += bytes
      @large_mapped_bytes += bytes if size_class == UInt32::MAX
      # Inline insert into sorted chunk index. Under TLAB MT this is called
      # from refill_size_class which already holds the size-class freelist
      # lock (via with_freelist_lock), so index_insert is serialised per class.
      # Under Boehm (library
      # heap) there is no contention.
      # `index_insert` invalidates the last-chunk cache **under `@index_lock`**.
      # A second `invalidate_chunk_cache` used to follow it here, outside the
      # lock — an unsynchronised `@last_chunk_idx = -1` on the path every
      # allocating thread takes when it maps a chunk, and the write the read in
      # `chunk_containing_unlocked` used to race. Restored only by the knob that
      # restores that read, so the gate has both halves of the old behaviour.
      invalidate_chunk_cache if @index_cache_unchecked
      note_mapped(chunk)
      # Cancel side must be armed wherever the record side is
      # (`guard_release` records under `@release_ledger || @unmap_guard`).
      # Gated on the ledger alone it recorded releases it never cancelled, so
      # every legal reuse of a base made the *next* release of that base look
      # like a double release: 21 of 24 children under `GCRY_UNMAP_GUARD=1`,
      # a reading with no defect behind it.
      note_map_base(ptr.address) if @release_ledger || @unmap_guard
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
      # Index removal and the list surgery in one section, for the reason
      # `map_chunk` spells out: the predecessor search reads `@chunks` and
      # every `next` along it, and a concurrent prepend under a *different*
      # lock can move the head out from under it. The search then walks a list
      # the target is no longer on, finds no predecessor, and returns having
      # removed the chunk from the index but **not** from the list — after
      # which the caller unmaps it and the next walker faults.
      @chunk_list_lock.sync do
        index_remove(target)
        if @chunks == target
          @chunks = target.value.next
        else
          prev = @chunks
          while prev
            if prev.value.next == target
              node = prev.value
              node.next = target.value.next
              prev.value = node
              break
            end
            prev = prev.value.next
          end
        end
      end
    end

    # Public for the invariant checker — walks the chunk linked list.
    def each_chunk(& : ChunkHeader* ->) : Nil
      chunk = @chunks
      while chunk
        yield chunk
        chunk = chunk.value.next
      end
    end

    # Public for the invariant checker — returns the head of a size-class freelist.
    def freelist_for(class_index : Int32) : Void*
      return Pointer(Void).null if class_index < 0 || class_index >= SIZE_CLASS_COUNT
      @freelists[class_index]
    end

    # Public for the invariant checker — returns the head of a nursery freelist.
    def nursery_freelist_for(class_index : Int32) : Void*
      return Pointer(Void).null if class_index < 0 || class_index >= SIZE_CLASS_COUNT
      @nursery_freelists[class_index]
    end

    # Binary search over address-sorted chunk index, with a single-slot
    # last-chunk cache (pointer chasing in mark drains one chunk at a time).
    #
    # Mutators race `index_insert` / last-chunk cache under Parallel EC —
    # serialize with @index_lock (separate from @alloc_lock to avoid deadlock
    # when refill holds @alloc_lock and a concurrent realloc looks up a chunk).
    # Skip the lock only while the world is stopped (true STW). Do NOT skip
    # for `@collecting` alone: post-STW flush keeps `@collecting` with the
    # world restarted so mutators mmap/index_insert while peers realloc —
    # unlocked lookup → false `owns_user_pointer?` ("not a gcry allocation").
    # Is *addr* still inside a chunk this heap has mapped?
    #
    # For audits that hold an address from earlier and need to know whether
    # reading it is safe *before* reading it. Dereferencing a released chunk
    # faults, and a fault is a crash where an audit wants a finding — see
    # `bench/live_graph_audit.cr`, which lost the report it was built to make
    # because it read a node whose chunk had been unmapped.
    def address_in_live_chunk?(addr : UInt64) : Bool
      !chunk_containing(addr).nil?
    end

    protected def chunk_containing(addr : UInt64) : ChunkHeader*?
      if @world_stopped
        # See `@stw_owner_pthread`: whether that skip is safe depends on nobody
        # but the collector being able to get here, and two threads in this
        # codebase can.
        if @index_audit
          if LibC.pthread_self.unsafe_as(UInt64) == @stw_owner_pthread
            @index_unlocked_owner &+= 1
          else
            @index_unlocked_foreign &+= 1
            @index_unlocked_foreign_id = LibC.pthread_self.unsafe_as(UInt64)
          end
        end
        chunk_containing_unlocked(addr)
      else
        @index_lock.sync { chunk_containing_unlocked(addr) }
      end
    end

    private def chunk_containing_unlocked(addr : UInt64) : ChunkHeader*?
      return nil if @heap_max == 0 || addr < @heap_min || addr >= @heap_max

      # O(1) table, when it is on. Two dependent loads, then the same
      # containment check the search path applies to its own result — an entry
      # can legitimately name a neighbouring chunk for an address in the header
      # region, and a miss simply falls through to the authority below.
      #
      # `contains?` dereferences the chunk, so this is only as safe as the
      # caller's lock discipline — which is unchanged: `chunk_containing` still
      # takes `@index_lock` unless `@world_stopped`, and radix entries live and
      # die inside the same critical sections as the sorted index. See
      # `chunk_radix.cr` for the full argument.
      unless @radix_l1.null?
        hit = radix_lookup(addr)
        if !hit.null? && ChunkHeader.contains?(hit, addr)
          radix_note_fast_hit
          return hit
        end
        radix_note_slow
      end

      # Last-chunk fast path: most lookups during mark hit the same chunk that
      # produced the previous result.
      #
      # `@last_chunk_idx` is read **once**. The first version tested the field
      # and then read it again to index with, and those are two loads: a
      # concurrent `invalidate_chunk_cache` between them turns a guard that saw
      # a valid index into a read at `@chunk_index[-1]` — libc's malloc header
      # for the array, which is why the bad value was the same small constant
      # (`0x91`) every single time. That is the crash `find_block` has been
      # dying on: four threads calling it while collections run died in 5 runs
      # of 8, and plain allocation at the same rate died in 0.
      #
      # The three cache fields cannot be read atomically together either, so
      # even a valid index can be paired with the wrong bounds. The chunk is
      # therefore *checked* to contain the address rather than assumed to, and a
      # miss falls through to the binary search, which is the authority. The
      # search path already did exactly this check on its own result.
      if @index_cache_unchecked
        # The pre-2026-08-22 path, kept only so the gate can show the crash:
        # the field is tested and then read again to index with, and nothing
        # checks that the chunk contains the address.
        if @last_chunk_idx >= 0 && addr >= @last_chunk_lo && addr < @last_chunk_hi
          return (@chunk_index + @last_chunk_idx).value
        end
        return chunk_search_unlocked(addr)
      end

      idx = @last_chunk_idx
      if idx >= 0 && idx < @chunk_index_count && addr >= @last_chunk_lo && addr < @last_chunk_hi
        cached = (@chunk_index + idx).value
        return cached if !cached.null? && ChunkHeader.contains?(cached, addr)
        # The index, the bounds and the array did not agree. Counted, because a
        # rate here is the difference between a race that is rare and one that
        # is constant.
        @index_cache_torn &+= 1
      end

      chunk_search_unlocked(addr)
    end

    private def chunk_search_unlocked(addr : UInt64) : ChunkHeader*?
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

    # ----- Mark bits -----
    #
    # Two representations, chosen once at `Heap#initialize` and never per call.
    #
    # Header (default): the mark-generation byte in `BlockHeader.flags`. One
    # object per write, so a lost update can only ever affect that object.
    #
    # Bitmap (`GCRY_BITMAP=1`): one bit per block, in the chunk's own `mark`
    # bitmap. **64 blocks share a word**, which changes the concurrency
    # contract — see `chunk_set_mark`.
    #
    # Large chunks stay on the header generation under both. They hold exactly
    # one object, so there is nothing for a bitmap to amortise, and keeping them
    # on the header avoids a bitmap region that would move `data_start` and
    # break the twelve sites that recover a large chunk as
    # `header - ChunkHeader::SIZE`.

    @[AlwaysInline]
    private def chunk_block_ordinal(chunk : ChunkHeader*, addr : UInt64) : UInt64
      class_index = chunk.value.size_class.to_i32
      offset = addr - ChunkHeader.data_start(chunk).address
      Heap.block_ordinal(offset, @block_magic[class_index])
    end

    @[AlwaysInline]
    private def chunk_marked?(chunk : ChunkHeader*, ordinal : UInt64) : Bool
      mark = ChunkHeader.mark_bitmap(chunk)
      return false if mark.null?
      ((mark[ordinal >> 6] >> (ordinal & 63)) & 1_u64) != 0
    end

    # Set one block's mark bit.
    #
    # The OR is atomic and it is not optional. 64 blocks share a word, and there
    # are two concurrent writers in configurations gcry ships: parallel mark
    # workers, and **allocate-black in the mutator** — `heap_set_mark(header) if
    # @incremental_marking || @collecting` at heap.cr and tlab.cr, seven sites,
    # where `tlab_alloc_small` holds only its per-slot lock. A plain `|=` there
    # drops a *different* object's mark, which the header representation
    # structurally cannot do: it would be a live object swept, presenting as a
    # rare load-dependent use-after-free.
    #
    # The relaxed load first is what keeps this cheap: re-marking an
    # already-marked object is the common case during a trace, and it skips the
    # locked instruction entirely.
    @[AlwaysInline]
    private def chunk_set_mark(chunk : ChunkHeader*, ordinal : UInt64) : Nil
      mark = ChunkHeader.mark_bitmap(chunk)
      return if mark.null?
      word = mark + (ordinal >> 6)
      bit = 1_u64 << (ordinal & 63)
      return if (word.value & bit) != 0
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, word, bit,
        LLVM::AtomicOrdering::Monotonic, false)
    end

    # Zero a chunk's whole mark bitmap.
    #
    # This is the ONLY way marks are cleared on the bitmap path. There is no
    # per-block clear, because clearing one bit is a read-modify-write of a word
    # holding 63 other blocks' marks — the same lost-update hazard as the set,
    # in the other direction, and the after-world sweep clears marks with
    # mutators running.
    @[AlwaysInline]
    private def chunk_clear_marks(chunk : ChunkHeader*) : Nil
      mark = ChunkHeader.mark_bitmap(chunk)
      return if mark.null?
      words = chunk.value.bitmap_words.to_i32
      i = 0
      while i < words
        mark[i] = 0_u64
        i += 1
      end
    end

    # ----- The Phase 1 union, and why it exists -----
    #
    # An object is marked if the bitmap says so **or** the header generation
    # does. That is transitional, and it buys one specific thing: the mutator's
    # allocation path is not touched at all.
    #
    # Allocate-black (`heap_set_mark(header) if @incremental_marking ||
    # @collecting`, seven sites across heap.cr and tlab.cr) holds a header and
    # no chunk. Routing it to the bitmap would mean `chunk_containing` per
    # allocation — which takes `@index_lock` whenever the world is not stopped,
    # so during the post-STW flush window it is a lock on the allocation fast
    # path. That is the exact shape that took the 2026-08-01 experiment to
    # 56.3% of Boehm, and this plan's hard constraint forbids it.
    #
    # So allocate-black keeps writing the header generation, unchanged, and the
    # *readers* take the union. Sound because the generation is bumped every
    # cycle (`clear_all_marks`), so a mark from cycle N stops counting in N+1
    # exactly as it does today. Cheap because the sweep is still walking headers
    # in this phase and `mark_impl` already reads the header for the FREE check
    # and the type_id gate.
    #
    # Phase 3 retires it: once allocation is pool-cursor driven the chunk is in
    # hand for free, allocate-black writes the bitmap directly, and the sweep
    # stops reading headers at all. **The union must go when the sweep does** —
    # a bitmap-only sweep with allocate-black still on the header would reclaim
    # live objects.

    # Union read for callers holding only a header: diagnostics, finalizer
    # liveness, birth-grace, the audits. Pays a chunk lookup, which is why no
    # hot path uses it — `sweep_small_blocks` counts ordinals, and
    # `mark_impl_unlocked` gets its chunk from `find_block_with_chunk`.
    @[AlwaysInline]
    private def heap_marked?(header : BlockHeader*) : Bool
      return BlockHeader.marked?(header) unless @bitmap_marks
      return true if !@bitmap_alloc && BlockHeader.marked?(header)
      chunk = chunk_containing(header.address)
      return BlockHeader.marked?(header) if chunk.nil? || !bitmap_chunk?(chunk)
      chunk_marked?(chunk, chunk_block_ordinal(chunk, header.address))
    end

    # Allocate-black's mark write.
    #
    # Phase 1 had this write only the header generation, with readers taking the
    # union, because the caller held no chunk and a lookup here is the 56.3%
    # shape. Phase 3's sweep reads **only** the bitmap, so the union is gone and
    # this has to reach the bitmap — and it now can, because the pool cursor
    # already resolved the chunk for the allocation this is marking.
    #
    # `@pool_chunk[class]` is that chunk, held under the same size-class lock
    # the allocation took, so this is a cached read rather than a lookup. The
    # containment check is what makes it safe to trust: a caller whose block is
    # not in the cursor's chunk (a large object, a TLAB slot, a free-list
    # residue) falls back to the header, which the header arm still reads.
    @[AlwaysInline]
    private def heap_set_mark(header : BlockHeader*) : Nil
      # Phase 1: the header generation, with readers taking the union, so no
      # lookup lands on the mutator's allocation path. Phase 3's sweep reads
      # only the bitmap, so the union is gone and this must reach it.
      unless @bitmap_alloc
        BlockHeader.set_mark(header)
        return
      end
      # `index_of?`, not `index_of`: the raising twin allocates, and this runs
      # inside a collection where that deadlocks.
      class_index = SizeClasses.index_of?(header.value.size)
      if class_index >= 0
        chunk = @pool_chunk[class_index]
        if !chunk.null? && ChunkHeader.contains?(chunk, header.address)
          chunk_set_mark(chunk, chunk_block_ordinal(chunk, header.address))
          return
        end
      end
      # No cursor for this block: resolve it. Reached only by large objects and
      # by blocks outside the current cursor's chunk, never by the steady-state
      # allocation path.
      chunk = chunk_containing(header.address)
      if chunk.nil? || !bitmap_chunk?(chunk)
        BlockHeader.set_mark(header)
        return
      end
      chunk_set_mark(chunk, chunk_block_ordinal(chunk, header.address))
    end

    # Clears the header generation only. Bitmap marks are never cleared one bit
    # at a time — see `chunk_clear_marks`.
    @[AlwaysInline]
    private def heap_clear_mark(header : BlockHeader*) : Nil
      BlockHeader.clear_mark(header)
    end

    # Is this block allocated?
    #
    # On a bitmap chunk `occ` is the authority, **not** `BlockHeader.free?`. The
    # streaming sweep publishes `occ = mark` and never writes FREE into the
    # headers of the blocks it reclaims — writing them would reintroduce the
    # O(blocks) walk the bitmap exists to remove, and the plan's answer is that
    # the flag becomes lazy and then goes away entirely (Phase 7).
    #
    # Consulting the stale header instead is not merely untidy. `find_object`
    # would hand a reclaimed block back as live, the mark phase would mark it,
    # and the next sweep's `occ = mark` would set its `occ` bit — resurrecting
    # a block nothing owns into the allocated set, permanently. A slow leak
    # driven by conservative false pointers, invisible in every counter.
    @[AlwaysInline]
    private def block_allocated?(chunk : ChunkHeader*, header : BlockHeader*) : Bool
      return !BlockHeader.free?(header) unless bitmap_alloc_chunk?(chunk)
      occ = ChunkHeader.occ_bitmap(chunk)
      return !BlockHeader.free?(header) if occ.null?
      ordinal = chunk_block_ordinal(chunk, header.address)
      ((occ[ordinal >> 6] >> (ordinal & 63)) & 1_u64) != 0
    end

    # Chunks whose *allocation* is bitmap-driven, i.e. whose `occ` is
    # maintained. Narrower than `bitmap_chunk?`, which only asks about marks.
    @[AlwaysInline]
    private def bitmap_alloc_chunk?(chunk : ChunkHeader*) : Bool
      @bitmap_alloc && !ChunkHeader.large?(chunk) && !ChunkHeader.nursery?(chunk)
    end

    # Mark read/write for a block whose chunk the caller already resolved: the
    # hot-path pair, reached from `mark_impl_unlocked`.
    # Large chunks and nursery chunks stay on the header generation: the first
    # because one object needs no bitmap, the second because its sweep is still
    # a header walk (see `sweep_small_blocks`). Both must agree with whichever
    # arm will read them.
    @[AlwaysInline]
    private def bitmap_chunk?(chunk : ChunkHeader*) : Bool
      @bitmap_marks && !ChunkHeader.large?(chunk) && !ChunkHeader.nursery?(chunk)
    end

    @[AlwaysInline]
    private def block_marked_in?(chunk : ChunkHeader*, header : BlockHeader*) : Bool
      return BlockHeader.marked?(header) unless bitmap_chunk?(chunk)
      marked = chunk_marked?(chunk, chunk_block_ordinal(chunk, header.address))
      # The Phase 1 union, alive exactly while the sweep still reads headers.
      # Under `bitmap_alloc` the sweep reads only the bitmap and allocate-black
      # writes the bitmap, so the union is both unnecessary and wrong.
      marked ||= BlockHeader.marked?(header) unless @bitmap_alloc
      marked
    end

    # The trace's mark write: bitmap for size-class blocks, header generation
    # for large. No lookup — the caller resolved the chunk anyway.
    @[AlwaysInline]
    private def set_block_mark_in(chunk : ChunkHeader*, header : BlockHeader*) : Nil
      unless bitmap_chunk?(chunk)
        BlockHeader.set_mark(header)
        return
      end
      chunk_set_mark(chunk, chunk_block_ordinal(chunk, header.address))
    end

    # Public read for diagnostics, which live outside `Heap` and must not be
    # allowed to disagree with the collector about what is marked. Reading
    # `BlockHeader.marked?` directly reports the header generation, which under
    # `GCRY_BITMAP=1` is not what the sweep consults — a diagnostic that
    # confidently reports the wrong answer is worse than one that is absent,
    # and these are the tools reached for when something is already wrong.
    def marked_for_report?(header : BlockHeader*) : Bool
      heap_marked?(header)
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
    # Is any chunk that is still live sitting inside the range about to be
    # unmapped?
    #
    # `unlink_chunk` removes a chunk from the index *before* anything releases
    # it, so an index entry that overlaps a range on its way to `munmap` is by
    # construction a chunk that is still in use — and unmapping it takes live
    # objects with it, leaving the mutator to fault at whatever page boundary
    # it walks into. That is the one story that fits every negative result in
    # `bench/log/linux/2026-08-24-acikturkiye-live-string-uaf`: the object graph
    # is intact, nothing is marked wrong, nothing holds a dangling pointer, and
    # `GCRY_UNMAP_GUARD=1` — which makes no `munmap` calls at all — took the
    # crash from 3 of 6 to 0 of 11.
    #
    # The empty-chunk flush is where a range can grow beyond what was released:
    # it coalesces neighbours into one `munmap`, and the run end comes from
    # chunk headers.
    #
    # One binary search per release, so it stays on: refusing to unmap is a
    # leak, and a leak is a better outcome than tearing down live memory.
    #
    # Measured **zero** over 163 collections of acikturkiye under load while
    # the crash was still happening 3 runs in 4, so this is not that crash.
    # It stays as an invariant, not as a fix.
    protected def release_range_hits_live?(base : UInt64, len : UInt64) : Bool
      finish = base &+ len
      @index_lock.sync do
        pos = index_lower_bound(base)
        # The entry before `pos` starts below `base`; it overlaps if it reaches
        # into the range.
        if pos > 0
          prev = (@chunk_index + (pos - 1)).value
          return true if prev.address &+ prev.value.mapped_bytes > base
        end
        return false if pos >= @chunk_index_count
        (@chunk_index + pos).value.address < finish
      end
    end

    # Refuse the release and say so once. Returns true when the caller must not
    # unmap.
    protected def refuse_live_release(base : UInt64, len : UInt64, kind : UInt8) : Bool
      return false unless release_range_hits_live?(base, len)
      @release_hit_live &+= 1
      return true unless @release_hit_live == 1
      buf = uninitialized UInt8[256]
      n = 0
      n = RawOut.append(buf.to_unsafe, n, "gcry: refusing to unmap [0x")
      n = RawOut.append_hex(buf.to_unsafe, n, base)
      n = RawOut.append(buf.to_unsafe, n, ", 0x")
      n = RawOut.append_hex(buf.to_unsafe, n, base &+ len)
      n = RawOut.append(buf.to_unsafe, n, ") — a chunk that is still indexed lives inside it. kind ")
      n = RawOut.append_u64(buf.to_unsafe, n, kind.to_u64)
      n = RawOut.append(buf.to_unsafe, n, ", collection ")
      n = RawOut.append_u64(buf.to_unsafe, n, @collections)
      n = RawOut.append(buf.to_unsafe, n, "\n")
      RawOut.flush(buf.to_unsafe, n)
      true
    end

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

    # Does the chunk index still describe the chunks that exist?
    #
    # `GCRY_INDEX_AUDIT=1`, from inside the stopped world so `@chunks` and the
    # index are both quiescent. Two questions, both of which a release is what
    # would break:
    #
    #   - **overlap.** Entries are sorted by base and a chunk owns
    #     `[base, base + mapped_bytes)`. Two entries that overlap mean one of
    #     them describes memory the other owns — which is what an index entry
    #     for a released chunk looks like once the kernel hands that base back
    #     to a later `mmap`. `chunk_containing` binary-searches this array, so
    #     from then on some addresses in the *new* chunk resolve through the
    #     *old* geometry.
    #   - **count.** The index and `@chunks` should hold the same chunks.
    #
    # Worth asking here because `GCRY_UNMAP_GUARD=1` — whose only effect is to
    # stop handing released address space back to the kernel — took the
    # acikturkiye crash from 3 of 6 to 0 of 4.
    private def report_index_overlap(base : UInt64, prev_end : UInt64) : Nil
      buf = uninitialized UInt8[256]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: chunk index — entry 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, base)
      len = RawOut.append(buf.to_unsafe, len, " starts inside the previous entry, which ends at 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, prev_end)
      len = RawOut.append(buf.to_unsafe, len, ". collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    protected def audit_chunk_index : Nil
      @index_audit_runs &+= 1
      prev_end = 0_u64
      i = 0
      while i < @chunk_index_count
        chunk = (@chunk_index + i).value
        base = chunk.address
        if i > 0 && base < prev_end
          @index_overlaps &+= 1
          report_index_overlap(base, prev_end) if @index_overlaps == 1
        end
        finish = base &+ chunk.value.mapped_bytes
        prev_end = finish if finish > prev_end
        i += 1
      end

      linked = 0
      walk = @chunks
      while walk
        linked += 1
        walk = walk.value.next
      end
      return if linked == @chunk_index_count
      @index_count_mismatch &+= 1
      return unless @index_count_mismatch == 1
      buf = uninitialized UInt8[256]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: chunk index — ")
      len = RawOut.append_u64(buf.to_unsafe, len, @chunk_index_count.to_u64)
      len = RawOut.append(buf.to_unsafe, len, " indexed against ")
      len = RawOut.append_u64(buf.to_unsafe, len, linked.to_u64)
      len = RawOut.append(buf.to_unsafe, len, " linked. collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    private def index_insert(chunk : ChunkHeader*) : Nil
      @index_lock.sync { index_insert_locked(chunk) }
    end

    # Caller holds `@index_lock`.
    #
    # The store order here is load-bearing for a reader this lock does not
    # cover: `chunk_containing` reads the index *unlocked* while the world is
    # stopped, and `stop_world` can suspend a mutator anywhere inside this
    # method. The old order — shift right, write the slot, THEN
    # `@chunk_index_count += 1` — has a window in which the top entry has been
    # copied to `a[count]` while `count` still hides it: a mutator frozen
    # there leaves the collector a sorted array whose **last entry does not
    # exist**, for the whole collection. The topmost address is always the
    # boot chunk, so the object that loses its mark to this is always one of
    # the runtime's own — measured as the `Thread::LinkedList` `0x18` family:
    # 19 of 19 fatal children read "absent from the array, 0 order
    # inversions" one suspension after a healthy walk, with no index_remove
    # and every insert/remove verifying clean at completion
    # (`bench/log/linux/2026-08-27-thread-list-tripwire/`).
    #
    # New order: duplicate the top entry into the new slot, publish the new
    # count with a release store, then shift. Every intermediate state a
    # suspended thread can expose is a sorted array with at most one
    # *adjacent duplicate* — harmless to a binary search — and never one
    # with an entry hidden.
    private def index_insert_locked(chunk : ChunkHeader*) : Nil
      invalidate_chunk_cache
      # Same critical section as the sorted index, deliberately. A reader that
      # sees a radix entry will dereference the chunk to verify it, so the entry
      # must not outlive the mapping — and matching the sorted index's lifetime
      # exactly is cheaper to reason about than a second protocol.
      radix_insert(chunk)
      index_ensure_cap(@chunk_index_count + 1)
      pos = index_lower_bound(chunk.address)
      count = @chunk_index_count
      if count > pos
        (@chunk_index + count).value = (@chunk_index + (count - 1)).value
      else
        # Top insert (or empty index): the new slot is the new chunk itself.
        (@chunk_index + pos).value = chunk
      end
      # Release, for the slot store above; the suspension that makes the
      # unlocked read legal syncs the rest.
      Atomic::Ops.store(pointerof(@chunk_index_count), count + 1, :release, true)
      if count > pos
        i = count - 1
        while i > pos
          (@chunk_index + i).value = (@chunk_index + (i - 1)).value
          i -= 1
        end
        (@chunk_index + pos).value = chunk
      end
      verify_thread_list_indexed("an index_insert")
    end

    private def index_remove(chunk : ChunkHeader*) : Nil
      @index_lock.sync { index_remove_locked(chunk) }
    end

    # Caller holds `@index_lock`.
    private def index_remove_locked(chunk : ChunkHeader*) : Nil
      begin
        invalidate_chunk_cache
        # Retract before the caller's munmap, for the same reason the sorted
        # index does: a reader that still sees the entry dereferences it.
        radix_remove(chunk)
        # No cursor drop here. A chunk under a cursor is pinned live by the
        # sweep and never reaches this path — see `bitmap_cursor_on?`.
        # Range test AND base identity: the hook exists because the entry
        # vanishes, and a defect that has already rewritten `mapped_bytes`
        # would blind a range-only test while the base still names the chunk.
        if ThreadListWatch.check(chunk.address, chunk.value.mapped_bytes, ThreadListWatch::SITE_INDEX_REMOVE) ||
           (ThreadListWatch.chunk_base != 0 && chunk.address == ThreadListWatch.chunk_base &&
           ThreadListWatch.check(chunk.address, UInt64::MAX - chunk.address, ThreadListWatch::SITE_INDEX_REMOVE))
          Exception::CallStack.print_backtrace
        end
        pos = index_lower_bound(chunk.address)
        unless pos >= @chunk_index_count || (@chunk_index + pos).value != chunk
          i = pos
          last = @chunk_index_count - 1
          while i < last
            (@chunk_index + i).value = (@chunk_index + (i + 1)).value
            i += 1
          end
          @chunk_index_count -= 1
        end
        verify_thread_list_indexed("an index_remove")
      end
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
      # Must agree with `find_block` (collect.cr) exactly — see the note there.
      data_start = ChunkHeader.data_start(chunk).address
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
require "./invariant"
require "./trace"
require "./heap_dump"
