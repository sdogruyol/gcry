require "./block"
require "./kernels"

lib LibC
  {% if flag?(:darwin) %}
    alias GcryPthreadKeyT = ULong
  {% else %}
    alias GcryPthreadKeyT = UInt
  {% end %}
  fun pthread_key_create(key : GcryPthreadKeyT*, destructor : Void* -> Void) : Int
  fun pthread_key_delete(key : GcryPthreadKeyT) : Int
  fun pthread_setspecific(key : GcryPthreadKeyT, value : Void*) : Int
end

module Gcry
  # One (class, kind) allocation cursor: the chunk it stands on, the `occ`
  # word it is consuming, that word's free bits as a private mask, and the
  # block it is handing out right now (`in_flight`), which the collector
  # roots. `in_flight` doubles as the mid-allocation marker: the sentinel from
  # the path's entry until the block's address is known.
  struct CursorSlot
    property chunk : ChunkHeader* = Pointer(ChunkHeader).null
    property word : Int32 = 0
    property free_mask : UInt64 = 0_u64
    property word_base : UInt64 = 0_u64
    property occ_word : UInt64* = Pointer(UInt64).null
    property in_flight : Void* = Pointer(Void).null
  end

  # Reusable-capacity index for one (class, kind), owned by its class lock.
  # Store addresses, not dereferenceable cached ChunkHeader pointers: mappings
  # may disappear at a collection. Every pop resolves the address through the
  # current chunk index and checks class, kind, ownership and occupancy again.
  struct BitmapPoolIndex
    property addresses : UInt64* = Pointer(UInt64).null
    property capacity : Int32 = 0
    property count : Int32 = 0
    property next_index : Int32 = 0
    property version : UInt64 = 0_u64
    property valid : Bool = false
    property blacklist_enabled : Bool = false
  end

  # One thread's cursors for one heap, `LibC.malloc`ed and zeroed. Reached
  # through a thread-local cache (`Heap#cursor_set_cached`); fields are written
  # through the pointer one at a time — a compound assignment on
  # `ptr.value.field` writes a copy.
  struct CursorSet
    # The mid-allocation marker a slot's `in_flight` carries before the block's
    # address is known. A method, not a constant: a constant built by a call
    # is initialised through `__crystal_once`, which asks for `Thread.current`,
    # which allocates, which reads the constant — a spin at boot.
    @[AlwaysInline]
    def self.sentinel : Void*
      Pointer(Void).new(8_u64)
    end

    STATE_FREE    = 0_u8
    STATE_LIVE    = 1_u8
    STATE_EXITING = 2_u8 # the owner's thread-exit destructor ran; retired and freed at the next stop-the-world

    property owner : UInt64 = 0_u64
    property state : UInt8 = 0_u8
    # Non-zero for sets that never take the hit path: the fallback shared by
    # threads past the table, and the runtime's monitor thread, which is
    # exempt from the stop-the-world signal and cooperates only through
    # `wait_if_world_stopped_other_thread` at `allocate`. The settle neither
    # retires nor credits such a set, since its owner may be running.
    property no_hit_path : UInt8 = 0_u8
    # Allocated on the hit path, monotonic; the heap credits the delta over
    # `*_credited` (`Heap#credit_cursor_set`).
    property bytes_local : UInt64 = 0_u64
    property bytes_credited : UInt64 = 0_u64
    property objects_local : UInt64 = 0_u64
    property objects_credited : UInt64 = 0_u64
    property slots : StaticArray(CursorSlot, POOL_SLOTS) = StaticArray(CursorSlot, POOL_SLOTS).new(CursorSlot.new)

    @[AlwaysInline]
    def self.slot(set : CursorSet*, i : Int32) : CursorSlot*
      (set.as(UInt8*) + offsetof(CursorSet, @slots)).as(CursorSlot*) + i
    end
  end

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

    # Per-thread allocation cursors. Every thread that allocates owns a
    # `CursorSet` — one slot per (class, kind) — and the hit path pops from
    # its own slot with no lock: the chunk under a slot was taken under the
    # class lock and carries `ChunkHeader::Flags::CURSOR`, so no other cursor
    # can be on it, and the only other writer of its `occ` word is a `free`
    # (atomic, like the set here). Counters are accumulated per set and
    # credited to the heap on the locked path and at every stop-the-world.
    #
    # This replaced a process-wide "single mutator" flag that skipped the
    # locks while one thread existed: the runtime's monitor thread allocates
    # its main `Fiber` at start-up, and exempting it handed one block to two
    # threads (process_spec/regression/7_sysmon_alloc_race_spec.cr).
    MAX_CURSOR_SETS = 64
    @cursor_sets = uninitialized StaticArray(CursorSet*, MAX_CURSOR_SETS)
    @cursor_set_count = 0
    # Threads past the table share this one, under the class lock only — the
    # hit path is off for them (`fast_alloc` refuses it). Never null once
    # `cursor_set` has run.
    @fallback_cursor_set = Pointer(CursorSet).null
    # A thread's exit runs the key's destructor with its set, which marks the
    # set exiting; the next stop-the-world retires it and frees its slot.
    @cursor_key = uninitialized LibC::GcryPthreadKeyT
    @cursor_key_ok = false
    # Its own lock, taken once per (thread, heap) and never with another heap
    # lock held inside it: set creation happens under the class lock, and the
    # collector holds `@alloc_lock` around the after-world sweep while it
    # waits for that class lock — taking `@alloc_lock` here deadlocked
    # `process_spec` under `-Dgcry_headerless`.
    @cursor_lock = Crystal::SpinLock.new
    getter cursor_set_count : Int32
    getter cursor_sets_pinned : UInt64 = 0_u64
    getter cursor_sets_retired : UInt64 = 0_u64

    # The calling thread's set for the heap it last allocated from. A miss
    # takes `@alloc_lock` once per (thread, heap). Integers with literal
    # initialisers, not pointers: a class variable whose initialiser is a call
    # is initialised lazily through `__crystal_once`, which asks for
    # `Thread.current`, which allocates, which reads the variable — a spin on
    # the once-lock at boot, before the runtime's first thread exists.
    @[ThreadLocal]
    @@tls_cursor_heap : UInt64 = 0_u64
    @[ThreadLocal]
    @@tls_cursor_set : UInt64 = 0_u64
    # Set by the thread-exit destructor: any allocation after it uses the
    # fallback set, so a retired set is never re-adopted by a dying thread.
    @[ThreadLocal]
    @@tls_cursor_exiting : UInt8 = 0_u8

    getter bitmap_locked_allocations : UInt64 = 0_u64
    getter bitmap_alloc_refills : UInt64 = 0_u64
    getter bitmap_alloc_chunk_advances : UInt64 = 0_u64
    getter bitmap_dormant_revives : UInt64 = 0_u64

    # A failed capacity search remains true until a free, sweep, or retirement
    # publishes capacity for this (class, kind). The same generation invalidates
    # the available-address index; neither cache owns or pins any chunk.
    @bitmap_capacity_versions = uninitialized StaticArray(UInt64, POOL_SLOTS)
    @bitmap_empty_versions = uninitialized StaticArray(UInt64, POOL_SLOTS)
    @bitmap_pool_indexes = uninitialized StaticArray(BitmapPoolIndex, POOL_SLOTS)
    @bitmap_search_counts = uninitialized StaticArray(UInt64, POOL_SLOTS)
    @bitmap_search_skip_counts = uninitialized StaticArray(UInt64, POOL_SLOTS)

    def bitmap_pool_searches : UInt64
      @bitmap_search_counts.sum
    end

    def bitmap_pool_search_skips : UInt64
      @bitmap_search_skip_counts.sum
    end

    private def bitmap_capacity_changed(chunk : ChunkHeader*) : Nil
      slot = chunk.value.size_class.to_i32
      slot += SIZE_CLASS_COUNT if ChunkHeader.atomic?(chunk)
      # A signal can suspend an explicit free while the collector also frees
      # this class. Atomic addition prevents losing either invalidation.
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Add,
        @bitmap_capacity_versions.to_unsafe + slot, 1_u64,
        LLVM::AtomicOrdering::Monotonic, false)
    end

    protected def bitmap_alloc_init : Nil
      @cursor_sets = StaticArray(CursorSet*, MAX_CURSOR_SETS).new(Pointer(CursorSet).null)
      @cursor_set_count = 0
      @bitmap_pool_indexes = StaticArray(BitmapPoolIndex, POOL_SLOTS).new(BitmapPoolIndex.new)
      @bitmap_capacity_versions = StaticArray(UInt64, POOL_SLOTS).new(1_u64)
      @bitmap_empty_versions = StaticArray(UInt64, POOL_SLOTS).new(0_u64)
      @bitmap_search_counts = StaticArray(UInt64, POOL_SLOTS).new(0_u64)
      @bitmap_search_skip_counts = StaticArray(UInt64, POOL_SLOTS).new(0_u64)
    end

    @[AlwaysInline]
    protected def cursor_set_cached : CursorSet*
      @@tls_cursor_heap == self.as(Void*).address ? Pointer(CursorSet).new(@@tls_cursor_set) : Pointer(CursorSet).null
    end

    # Never raises and never allocates from the managed heap: it runs under
    # the class lock, and a `raise` there allocates its exception on the same
    # lock — the self-deadlock that hung `process_spec` at the 65th thread.
    protected def cursor_set : CursorSet*
      set = cursor_set_cached
      return set unless set.null?
      key = current_thread_key
      exiting = @@tls_cursor_exiting != 0_u8
      set = @cursor_lock.sync { cursor_set_under_lock(key, exiting) }
      @@tls_cursor_heap = self.as(Void*).address
      @@tls_cursor_set = set.address
      set
    end

    private def cursor_set_under_lock(key : UInt64, exiting : Bool) : CursorSet*
      unless @cursor_key_ok
        @cursor_key_ok = LibC.pthread_key_create(pointerof(@cursor_key), ->(p : Void*) {
          # Thread exit. Plain stores: the collector reads them only with this
          # thread frozen or gone, and the fallback takes any later allocation.
          p.as(CursorSet*).value.state = CursorSet::STATE_EXITING
          @@tls_cursor_heap = 0_u64
          @@tls_cursor_exiting = 1_u8
        }) == 0
      end
      if @fallback_cursor_set.null?
        @fallback_cursor_set = alloc_cursor_set
        return Pointer(CursorSet).null if @fallback_cursor_set.null? # out of C heap; the caller's malloc fails next
        @fallback_cursor_set.value.no_hit_path = 1_u8
      end
      return @fallback_cursor_set if exiting || !@cursor_key_ok
      sysmon = monitor_thread?
      free = Pointer(CursorSet).null
      i = 0
      while i < @cursor_set_count
        set = @cursor_sets[i]
        return set if set.value.state == CursorSet::STATE_LIVE && set.value.owner == key
        free = set if free.null? && set.value.state == CursorSet::STATE_FREE
        i += 1
      end
      if free.null? && @cursor_set_count < MAX_CURSOR_SETS
        free = alloc_cursor_set
        unless free.null?
          @cursor_sets[@cursor_set_count] = free
          @cursor_set_count += 1
        end
      end
      return @fallback_cursor_set if free.null?
      free.value.owner = key
      free.value.state = CursorSet::STATE_LIVE
      free.value.no_hit_path = sysmon ? 1_u8 : 0_u8
      LibC.pthread_setspecific(@cursor_key, free.as(Void*))
      free
    end

    private def alloc_cursor_set : CursorSet*
      set = LibC.malloc(LibC::SizeT.new(sizeof(CursorSet))).as(CursorSet*)
      set.as(UInt8*).clear(sizeof(CursorSet)) unless set.null?
      set
    end

    # The chunk holding `user`, as an address, for the specs; 0 when none.
    def chunk_address_of(user : Void*) : UInt64
      chunk = chunk_containing(user.address)
      chunk ? chunk.address : 0_u64
    end

    # Blocks handed out on the hit path since the sets were created, for the
    # specs and `/gc-stats`.
    def cursor_hit_allocations : UInt64
      n = 0_u64
      each_cursor_set { |set| n &+= set.value.objects_local }
      n
    end

    # Compatibility aliases. These counters are cumulative diagnostics; the
    # locked-path counter is best-effort under concurrent classes.
    def bitmap_alloc_fast : UInt64
      bitmap_locked_allocations
    end

    def fast_path_objects : UInt64
      cursor_hit_allocations
    end

    # Whether the hit path is open at all (`refresh_fast_path`).
    def fast_path? : Bool
      @fast_path
    end

    # Chunks a cursor is standing on, for the specs and `/gc-stats`.
    def cursor_held_chunks : Int32
      n = 0
      each_chunk { |chunk| n += 1 if !ChunkHeader.large?(chunk) && ChunkHeader.cursor?(chunk) }
      n
    end

    protected def each_cursor_set(&)
      i = 0
      while i < @cursor_set_count
        yield @cursor_sets[i]
        i += 1
      end
      yield @fallback_cursor_set unless @fallback_cursor_set.null?
    end

    protected def destroy_cursor_sets : Nil
      i = 0
      while i < POOL_SLOTS
        pool = @bitmap_pool_indexes.to_unsafe + i
        unless pool.value.addresses.null?
          LibC.munmap(pool.value.addresses.as(Void*), LibC::SizeT.new(pool.value.capacity.to_u64 * 8))
          pool.value.addresses = Pointer(UInt64).null
          pool.value.capacity = 0
          pool.value.valid = false
        end
        i += 1
      end
      each_cursor_set { |set| LibC.free(set.as(Void*)) }
      @cursor_set_count = 0
      @fallback_cursor_set = Pointer(CursorSet).null
      if @cursor_key_ok
        LibC.pthread_key_delete(@cursor_key)
        @cursor_key_ok = false
      end
      if @@tls_cursor_heap == self.as(Void*).address
        @@tls_cursor_heap = 0_u64
        @@tls_cursor_set = 0_u64
      end
    end

    # Is the set between its sentinel store and its clear — inside `fast_alloc`
    # or `bitmap_alloc_locked` — for any slot? Read only with the owner frozen.
    @[AlwaysInline]
    private def cursor_set_mid_allocation?(set : CursorSet*) : Bool
      i = 0
      while i < POOL_SLOTS
        return true unless CursorSet.slot(set, i).value.in_flight.null?
        i += 1
      end
      false
    end

    # Hand the set's uncredited allocation bytes and objects to the heap's
    # counters. The locals are monotonic and written only by the owner; the
    # credited marks move by compare-and-swap, so any thread may credit any
    # set — the owner on its locked path, the collector at a stop-the-world,
    # a reader of the public counters — and a delta is credited exactly once.
    # A store the owner was frozen inside is credited next time.
    @[AlwaysInline]
    protected def credit_cursor_set(set : CursorSet*) : Nil
      bytes_credited = (set.as(UInt8*) + offsetof(CursorSet, @bytes_credited)).as(UInt64*)
      loop do
        local = set.value.bytes_local
        credited = bytes_credited.value
        delta = local &- credited
        break if delta == 0_u64
        _, ok = Atomic::Ops.cmpxchg(bytes_credited, credited, local,
          LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::SequentiallyConsistent)
        next unless ok
        @total_bytes.add(delta)
        @bytes_since_gc.add(delta)
        free_bytes_sub(delta)
        break
      end
      objects_credited = (set.as(UInt8*) + offsetof(CursorSet, @objects_credited)).as(UInt64*)
      loop do
        local = set.value.objects_local
        credited = objects_credited.value
        delta = local &- credited
        break if delta == 0_u64
        _, ok = Atomic::Ops.cmpxchg(objects_credited, credited, local,
          LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::SequentiallyConsistent)
        next unless ok
        @live_objects.add(delta)
        break
      end
    end

    protected def credit_all_cursor_sets : Nil
      each_cursor_set { |set| credit_cursor_set(set) }
    end

    private def retire_cursor_slot(s : CursorSlot*, exhausted : Bool = false) : Nil
      chunk = s.value.chunk
      unless chunk.null?
        ChunkHeader.set_cursor(chunk, false)
        bitmap_capacity_changed(chunk) unless exhausted
      end
      s.value.chunk = Pointer(ChunkHeader).null
      s.value.free_mask = 0_u64
      s.value.word = 0
      s.value.word_base = 0_u64
      s.value.occ_word = Pointer(UInt64).null
    end

    # Stop-the-world, before the roots are marked. Three things, in order:
    # chunks pinned through the previous cycle were skipped by its after-world
    # sweep, so their marks are stale and are zeroed here; every set's
    # counters are credited; then each set is either retired — its chunks go
    # back to the pool lists, and its owner refills under the lock when it
    # resumes — or, if its owner is frozen mid-allocation, left alone with its
    # chunks pinned, because that owner will finish an unlocked `occ` store
    # into them when it resumes.
    protected def bitmap_settle_cursor_sets : Nil
      return unless @bitmap_alloc
      each_chunk do |chunk|
        next if ChunkHeader.large?(chunk)
        next unless ChunkHeader.pinned?(chunk)
        mark = ChunkHeader.mark_bitmap(chunk)
        unless mark.null?
          words = chunk.value.bitmap_words.to_i32
          i = 0
          while i < words
            mark[i] = 0_u64
            i += 1
          end
        end
        ChunkHeader.set_pinned(chunk, false)
      end
      each_cursor_set do |set|
        if set.value.no_hit_path != 0_u8 || cursor_set_mid_allocation?(set)
          i = 0
          while i < POOL_SLOTS
            chunk = CursorSet.slot(set, i).value.chunk
            ChunkHeader.set_pinned(chunk, true) unless chunk.null?
            i += 1
          end
          @cursor_sets_pinned &+= 1
        else
          credit_cursor_set(set)
          i = 0
          while i < POOL_SLOTS
            retire_cursor_slot(CursorSet.slot(set, i))
            i += 1
          end
          @cursor_sets_retired &+= 1
          if set.value.state == CursorSet::STATE_EXITING
            set.value.owner = 0_u64
            set.value.state = CursorSet::STATE_FREE
          end
        end
      end
    end

    # Root every block a cursor slot is mid-handover on. Called from the root
    # phase, like `mark_large_alloc_in_flight`. The sentinel a slot carries
    # from its entry until it knows the block is not an address.
    protected def mark_bitmap_alloc_in_flight : Nil
      return unless @bitmap_alloc
      each_cursor_set do |set|
        i = 0
        while i < POOL_SLOTS
          u = CursorSet.slot(set, i).value.in_flight
          mark_explicit_root(u) if u.address > CursorSet.sentinel.address
          i += 1
        end
      end
    end

    # Drop the slot's copy once the caller's frame holds the pointer. The slot
    # is this thread's own, so the store is unconditional.
    protected def clear_bitmap_alloc_in_flight(index : Int32, flags : UInt32, user : Void*) : Nil
      set = cursor_set_cached
      return if set.null?
      slot = (flags & BlockHeader::Flags::ATOMIC) != 0 ? index + SIZE_CLASS_COUNT : index
      CursorSet.slot(set, slot).value.in_flight = Pointer(Void).null
    end

    # Fork child: drop every publication, since only one thread survived.
    protected def reset_bitmap_alloc_in_flight : Nil
      each_cursor_set do |set|
        i = 0
        while i < POOL_SLOTS
          CursorSet.slot(set, i).value.in_flight = Pointer(Void).null
          i += 1
        end
      end
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
      set = cursor_set
      s = CursorSet.slot(set, slot)

      # Mid-allocation from here until `clear_bitmap_alloc_in_flight`: a
      # stop-the-world that finds the sentinel pins this set instead of
      # retiring it (`bitmap_settle_cursor_sets`), so everything read from the
      # slot below stays true across a suspension. The fence keeps the
      # compiler from hoisting those reads above the store.
      s.value.in_flight = CursorSet.sentinel
      Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, true)
      credit_cursor_set(set)

      mask = s.value.free_mask
      if mask == 0_u64
        unless bitmap_refill_pool(s, index, payload, atomic)
          s.value.in_flight = Pointer(Void).null
          return Pointer(Void).null
        end
        mask = s.value.free_mask
        if mask == 0_u64
          s.value.in_flight = Pointer(Void).null
          return Pointer(Void).null
        end
      end

      bit = mask.trailing_zeros_count
      # `blsr`: clear the lowest set bit. The mask is this thread's own.
      s.value.free_mask = mask & (mask &- 1)

      chunk = s.value.chunk
      occ = ChunkHeader.occ_bitmap(chunk)
      word = s.value.word
      bit_mask = 1_u64 << bit

      # Publish the block as a root **before** the `occ` store makes it
      # allocated. Everything from that store until the caller holds the
      # pointer is a window in which the block is occupied, unmarked, and
      # referenced only by a header address the root scan refuses.
      header_addr = s.value.word_base &+ bit.to_u64 &* @block_bytes[index]
      s.value.in_flight = Pointer(Void).new(header_addr &+ BlockHeader::SIZE)

      # Atomic: a `free` on another thread can clear a bit in this word. Same
      # hazard as the mark bit, same reasoning — see `chunk_set_mark`.
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, occ + word, bit_mask,
        LLVM::AtomicOrdering::Monotonic, false)

      # `@freelist_clean` is a freelist-shaped claim — "this class's next block
      # comes straight off a fresh chunk, so `allocate` may skip the memset".
      # The pool cursor hands out reused blocks from `~occ` with no such
      # guarantee, and a stale `true` here would hand a caller dirty memory that
      # Crystal assumes is zeroed (`Reference.allocate` zeroes nothing itself).
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

      # Allocate-black, and it is not optional here: a block allocated while
      # `@collecting` that carries `occ=1, mark=0` into `occ &= mark` is
      # reclaimed live (`after collect #3: root 9 DEAD` in
      # `stw-mt-property-test` before this). The cursor's chunk is in hand, so
      # this is the cheap form — no lookup.
      if @incremental_marking || @collecting
        ordinal = (word.to_u64 << 6) &+ bit.to_u64
        chunk_set_mark(chunk, ordinal)
      end

      @bitmap_locked_allocations &+= 1
      BlockHeader.user_from(header)
    end

    # Advance the cursor to the next word with a free block, taking another
    # chunk from the class's pool list when the current one is exhausted.
    protected def bitmap_refill_pool(s : CursorSlot*, index : Int32, payload : UInt32,
                                     atomic : Bool) : Bool
      loop do
        chunk = s.value.chunk
        if chunk.null?
          chunk = bitmap_take_pool_chunk(index, payload, atomic)
          return false if chunk.null?
          ChunkHeader.set_cursor(chunk, true)
          s.value.chunk = chunk
          s.value.word = 0
          @bitmap_alloc_chunk_advances &+= 1
        end

        nblocks = chunk_block_count(chunk)
        words = ((nblocks + 63) >> 6).to_i32
        word = s.value.word
        while word < words
          mask = chunk_free_mask(chunk, word, nblocks)
          if mask != 0_u64
            s.value.word = word
            s.value.free_mask = mask
            s.value.word_base = ChunkHeader.data_start(chunk).address &+
                                (word.to_u64 << 6) &* @block_bytes[index]
            s.value.occ_word = ChunkHeader.occ_bitmap(chunk) + word
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
        retire_cursor_slot(s, exhausted: true)
      end
    end

    # Cache all available chunks in ascending address order. A rebuild costs
    # one heap walk plus a sort, amortized across the available chunks instead
    # of repeating the heap walk for every exhausted allocation cursor.
    protected def bitmap_take_pool_chunk(index : Int32, payload : UInt32,
                                         atomic : Bool) : ChunkHeader*
      slot = atomic ? index + SIZE_CLASS_COUNT : index
      version = Atomic::Ops.load(@bitmap_capacity_versions.to_unsafe + slot,
        LLVM::AtomicOrdering::Monotonic, false)
      pool = @bitmap_pool_indexes.to_unsafe + slot
      # Adding blacklist bits only removes capacity; each pop rechecks them.
      # Disabling the blacklist can restore capacity, so a mode change rebuilds.
      if pool.value.blacklist_enabled != @blacklist_enabled
        pool.value.valid = false
        @bitmap_empty_versions[slot] = 0_u64
      end
      if !pool.value.valid || pool.value.version != version
        pool.value.count = 0
        pool.value.next_index = 0
        pool.value.valid = false
        @bitmap_search_counts[slot] &+= 1
        best = Pointer(ChunkHeader).null
        indexed = true
        each_chunk do |chunk|
          next unless bitmap_pool_candidate?(chunk, index, atomic)
          best = chunk if best.null? || chunk.address < best.address
          indexed = false if indexed && !bitmap_pool_append(pool, chunk.address)
        end
        # OOM in optional metadata must not raise under the class lock. Fall
        # back to the old lowest-address search result and retry indexing on
        # a later refill. Never publish a truncated available-chunk index.
        return best if !indexed && !best.null?
        pool.value.addresses.to_slice(pool.value.count).sort! if pool.value.count > 1
        pool.value.version = version
        pool.value.blacklist_enabled = @blacklist_enabled
        pool.value.valid = indexed
      end

      while pool.value.next_index < pool.value.count
        at = pool.value.next_index
        pool.value.next_index = at + 1
        address = pool.value.addresses[at]
        # A stale address is harmless only after this lookup. Do not cast it
        # to ChunkHeader* or read its flags before the live index accepts it.
        if chunk = bitmap_indexed_chunk(address)
          if chunk.address == address && bitmap_pool_candidate?(chunk, index, atomic)
            return chunk
          end
        end
      end

      if @bitmap_empty_versions[slot] == version
        @bitmap_search_skip_counts[slot] &+= 1
      else
        # Dormant chunks need their own revive protocol: the data pages were
        # discarded and must not be reused during a live flush walk.
        revived, refused = bitmap_revive_dormant(index, atomic)
        return revived if revived
        # Keep the entry version: a sweep may have happened while this thread
        # was suspended. Its newer version must invalidate this result.
        @bitmap_empty_versions[slot] = version unless refused
      end
      map_chunk(@small_chunk_bytes, index.to_u32,
        atomic ? ChunkHeader::Flags::ATOMIC : 0_u32)
    end

    # The public containment lookup deliberately excludes chunk metadata.
    # Cached entries are mapping bases, so resolve an exact index key instead.
    # Match chunk_containing's stopped-world protocol: a suspended mutator
    # may own the index lock; the collector must use the stable sorted index
    # without waiting for that mutator to resume.
    private def bitmap_indexed_chunk(address : UInt64) : ChunkHeader*?
      if @world_stopped
        bitmap_indexed_chunk_unlocked(address)
      else
        @index_lock.sync { bitmap_indexed_chunk_unlocked(address) }
      end
    end

    private def bitmap_indexed_chunk_unlocked(address : UInt64) : ChunkHeader*?
      at = index_lower_bound(address)
      if at < @chunk_index_count
        chunk = @chunk_index[at]
        return chunk if chunk.address == address
      end
      nil
    end

    private def bitmap_pool_candidate?(chunk : ChunkHeader*, index : Int32, atomic : Bool) : Bool
      return false if ChunkHeader.large?(chunk) || chunk.value.size_class != index.to_u32
      return false unless ChunkHeader.atomic?(chunk) == atomic
      return false if ChunkHeader.dormant?(chunk) || ChunkHeader.nursery?(chunk) || ChunkHeader.cursor?(chunk)
      nblocks = chunk_block_count(chunk)
      return false if nblocks == 0
      words = ((nblocks + 63) >> 6).to_i32
      word = 0
      while word < words
        return true if chunk_free_mask(chunk, word, nblocks) != 0_u64
        word += 1
      end
      false
    end

    private def bitmap_pool_append(pool : BitmapPoolIndex*, address : UInt64) : Bool
      if pool.value.count == pool.value.capacity
        old_capacity = pool.value.capacity
        return false if old_capacity > Int32::MAX // 2
        capacity = old_capacity == 0 ? 512 : old_capacity * 2
        bytes = capacity.to_u64 * 8
        memory = LibC.mmap(Pointer(Void).null, LibC::SizeT.new(bytes),
          LibC::PROT_READ | LibC::PROT_WRITE, LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS, -1, 0)
        return false if Gcry.mmap_failed?(memory)
        addresses = memory.as(UInt64*)
        unless pool.value.addresses.null?
          pool.value.addresses.copy_to(addresses, pool.value.count)
          LibC.munmap(pool.value.addresses.as(Void*), LibC::SizeT.new(old_capacity.to_u64 * 8))
        end
        pool.value.addresses = addresses
        pool.value.capacity = capacity
      end
      pool.value.addresses[pool.value.count] = address
      pool.value.count = pool.value.count + 1
      true
    end

    # Bitmap-path counterpart of `revive_dormant_chunk`: no freelist, no header
    # writes. Same flag flip and byte accounting as the header path; free bytes
    # were never subtracted when the chunk went dormant, so none are added back.
    private def bitmap_revive_dormant(index : Int32, atomic : Bool) : {ChunkHeader*?, Bool}
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
          return {nil, true} if refused
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
          return {chunk, false}
        end
        chunk = chunk.value.next
      end
      {nil, false}
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
      bitmap_capacity_changed(chunk)
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
      ChunkHeader.cursor?(chunk)
    end

    # Drop every pool cursor standing on `chunk`, so an empty chunk can reach
    # the release path. Only legal with that class's freelist lock held — see
    # the pin note above.
    #
    # Slots of *other* classes can also point here (a chunk carries one class,
    # but the atomic and pointerful kinds are separate slots of it), and both
    # are covered by the same lock only when they share it. So retire only the
    # two slots of `class_index` and report whether any cursor is left; a
    # foreign slot keeps the chunk pinned for this cycle, which is the old
    # behaviour and still correct.
    # Allocation-free, and that is load-bearing rather than tidy: this runs
    # inside the sweep with the class's freelist lock held, and the spinlock is
    # not reentrant. An `[a, b].each` here allocates an `Array(Int32)` on the
    # managed heap, which re-enters `allocate` and deadlocks against the lock
    # its own caller is holding — observed as `process_spec` hanging under
    # `-Dgcry_headerless`.
    protected def bitmap_retire_cursor_on(chunk : ChunkHeader*, class_index : Int32) : Bool
      return false if class_index < 0 || class_index >= SIZE_CLASS_COUNT
      # Only this thread's own set: another thread's owner may be inside its
      # unlocked hit path on the chunk, and the stop-the-world is where its
      # cursors are retired (`bitmap_settle_cursor_sets`).
      set = cursor_set_cached
      return false if set.null?
      slot = class_index
      2.times do
        s = CursorSet.slot(set, slot)
        retire_cursor_slot(s) if s.value.chunk == chunk
        slot += SIZE_CLASS_COUNT
      end
      !ChunkHeader.cursor?(chunk)
    end
  end
end
