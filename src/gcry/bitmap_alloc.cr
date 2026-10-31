require "./block"
require "./kernels"

{% unless flag?(:win32) %}
lib LibC
  {% if flag?(:darwin) %}
    alias GcryPthreadKeyT = ULong
  {% else %}
    alias GcryPthreadKeyT = UInt
  {% end %}
  fun pthread_key_create(key : GcryPthreadKeyT*, destructor : Void* -> Void) : Int
  fun pthread_key_delete(key : GcryPthreadKeyT) : Int
  fun pthread_setspecific(key : GcryPthreadKeyT, value : Void*) : Int
  fun pthread_getspecific(key : GcryPthreadKeyT) : Void*
end
{% end %}

module Gcry
  # One (class, kind) allocation cursor: the chunk it stands on, the `occ`
  # word it is consuming, that word's blocks not handed out yet as a private
  # mask, and the block it is handing out right now (`in_flight`), which the
  # collector roots. `in_flight` doubles as the mid-allocation marker: the
  # sentinel from the path's entry until the block's address is known.
  #
  # `free_mask` is also the cursor's *claim*: its bits are already set in
  # `occ` (`Heap#cursor_claim_word`), so handing a block out writes nothing
  # another thread reads. Other threads do read `chunk`, `word` and
  # `free_mask` (`Heap#cursor_claim`), so the owner stores those three
  # atomically (`store_chunk`, `store_word`, `store_mask`, `publish_mask`), and `free_mask` is
  # zero whenever `word` or `chunk` changes: a reader that finds a nonzero
  # mask finds the word it belongs to.
  struct CursorSlot
    property chunk : ChunkHeader* = Pointer(ChunkHeader).null
    property word : Int32 = 0
    property free_mask : UInt64 = 0_u64
    property word_base : UInt64 = 0_u64
    property in_flight : Void* = Pointer(Void).null

    # Relaxed stores: plain `mov`/`str`, atomic only so that a reader on
    # another thread is not racing a non-atomic store (`Heap#cursor_claim`).
    @[AlwaysInline]
    def self.store_chunk(s : CursorSlot*, chunk : ChunkHeader*) : Nil
      Atomic::Ops.store(chunk_field(s), chunk.address, LLVM::AtomicOrdering::Monotonic, false)
    end

    @[AlwaysInline]
    def self.store_word(s : CursorSlot*, word : Int32) : Nil
      Atomic::Ops.store(word_field(s), word, LLVM::AtomicOrdering::Monotonic, false)
    end

    # A hand-out: it only takes bits away, so relaxed.
    @[AlwaysInline]
    def self.store_mask(s : CursorSlot*, mask : UInt64) : Nil
      Atomic::Ops.store(mask_field(s), mask, LLVM::AtomicOrdering::Monotonic, false)
    end

    # A new word's mask, or zero before the word or chunk moves: release, so
    # a reader that sees the mask sees the word stored before it, and one
    # that sees zero sees the release of the bits before it.
    @[AlwaysInline]
    def self.publish_mask(s : CursorSlot*, mask : UInt64) : Nil
      Atomic::Ops.store(mask_field(s), mask, LLVM::AtomicOrdering::Release, false)
    end

    @[AlwaysInline]
    def self.chunk_field(s : CursorSlot*) : UInt64*
      (s.as(UInt8*) + offsetof(CursorSlot, @chunk)).as(UInt64*)
    end

    @[AlwaysInline]
    def self.word_field(s : CursorSlot*) : Int32*
      (s.as(UInt8*) + offsetof(CursorSlot, @word)).as(Int32*)
    end

    @[AlwaysInline]
    def self.mask_field(s : CursorSlot*) : UInt64*
      (s.as(UInt8*) + offsetof(CursorSlot, @free_mask)).as(UInt64*)
    end
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
    # fast path is: `tzcnt` the cached mask, clear that bit from it, return
    # `word_base + ordinal * block_bytes`; the block's `occ` bit was set when
    # the cursor took the word (the claim, below). **No chunk lookup, no
    # freelist chase, no dependent load through free memory, no shared
    # write.** The size-class lock is taken once per *chunk* rather than once
    # per block, and the claim is one atomic per *word* of 64 blocks.
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
    #
    # ## Occupancy is claimed a word at a time
    #
    # A cursor sets the `occ` bits of all of a word's free blocks when it takes
    # the word (`cursor_claim_word`, one atomic OR), and hands those blocks out
    # from its private `free_mask` with no shared write. Until 2026-10-17 each
    # hand-out was a `lock or` into `occ`, the one locked instruction left on
    # the hit path: a plain OR in its place took Binarytrees from 88% to 103%
    # of Boehm on Linux x86-64 and from 77% to 92% on arm64
    # (`bench/log/macos/2026-10-16-binarytrees/`, the `noatomic` probe). A
    # plain OR is not sound — a `GC.free` on another thread clears bits of the
    # same word, and a plain read-modify-write can write a cleared bit back —
    # and nothing else needs the per-block write.
    #
    # So `occ` means *allocated or claimed*: a claimed bit is a block in the
    # `free_mask` of the slot that holds the chunk (`cursor_claim`). Every
    # store into an `occ` word, and why the claim survives each of them
    # (`bench/log/linux/2026-10-17-occupancy-claim/FINDINGS.md`):
    #
    # 1. **The claim**, by the owner, on a CURSOR chunk no other cursor can
    #    take, of bits `chunk_free_mask` found clear. It stores `word`, then
    #    `free_mask` (release), then marks the bits if a sweep can run before
    #    the next stop-the-world (point 5), then ORs them into `occ` (release).
    #    `free_mask` is zero before the word changes, so a stop that freezes
    #    the owner part-way finds either no claim or the whole mask.
    # 2. **The hand-out** writes nothing shared: popping the bit from
    #    `free_mask` is the allocation. `in_flight` is stored before the pop,
    #    with a compiler fence between them, so a stop that lands at any point
    #    finds the block still in `free_mask` (and claimed) or rooted.
    # 3. **The release**: `retire_cursor_slot` clears what is left of
    #    `free_mask` from `occ` and `mark` (atomic AND) before it clears the
    #    slot. It runs only with the owner outside its allocation window — at
    #    a stop for a set not mid-allocation, or on the owner's own thread —
    #    so the stored mask is exactly the blocks not handed out.
    # 4. **`free`** (`bitmap_free_block`): any thread, under the class lock,
    #    atomic AND. A correct program frees only blocks it was handed, never
    #    in a `free_mask`, and the owner writes `occ` only at a claim, of
    #    clear bits, so no update is lost either way: that is what the
    #    per-block `lock or` was for. A double or stale free into a claimed
    #    block is refused under the lock (`block_allocated_exact?`), which is
    #    also the lock any change of the chunk's owner takes.
    # 5. **The sweep's `occ = mark`.** In a stop, the settle runs before the
    #    mark (`bitmap_settle_cursor_sets`): a set not mid-allocation is
    #    retired and releases its claims; a set frozen mid-allocation keeps
    #    its chunks PINNED and the settle sets its claim in `mark` and `occ`,
    #    so the in-stop sweep keeps the claim and counts none of it freed.
    #    After the stop the sweep skips PINNED chunks and holds the class
    #    lock, the lock every other claim made after the restart is made under
    #    (the hit path is closed while `@collecting`); those claims, and every
    #    claim made while `@incremental_marking` (whose finishing slice sweeps
    #    with no settle), are marked when they are made.
    # 6. **The dormant revive** zeroes a chunk no word of which is claimed
    #    yet; a fresh chunk is zero from `mmap`.
    #
    # Readers: `chunk_free_mask` (`~occ`) never offers a claimed block, which
    # is the point. The mark reads `occ` raw: a claimed block is released
    # before it runs, or marked by the settle and so never traced.
    # `block_allocated_exact?`, `chunk_occupied_count` and the diagnostics on
    # them subtract the claim, so `free`, the invariant walks and `/gc-stats`
    # count allocated blocks only. Allocate-black still marks each block on
    # both paths while a cycle runs, as before.

    # Per-thread allocation cursors. Every thread that allocates owns a
    # `CursorSet` — one slot per (class, kind) — and the hit path pops from
    # its own slot with no lock: the chunk under a slot was taken under the
    # class lock and carries `ChunkHeader::Flags::CURSOR`, so no other cursor
    # can be on it, and the only other writer of its `occ` word is a `free`
    # (atomic, like the claim). Counters are accumulated per set and
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
    @cursor_key = uninitialized Gcry::OS::GcryPthreadKeyT
    @cursor_key_ok = false
    # Its own lock, taken once per (thread, heap) and never with another heap
    # lock held inside it: set creation happens under the class lock, and the
    # collector holds `@alloc_lock` around the after-world sweep while it
    # waits for that class lock — taking `@alloc_lock` here deadlocked
    # `process_spec` on the headerless layout.
    @cursor_lock = Crystal::SpinLock.new
    getter cursor_set_count : Int32
    getter cursor_sets_pinned : UInt64 = 0_u64
    getter cursor_sets_retired : UInt64 = 0_u64

    # One TLS read carries both the heap address (high 64 bits) and the set
    # address (low 64 bits). Check the heap identity before dereferencing the
    # set: a peer can destroy a quiescent heap while this thread still caches
    # its now-freed set, then this thread allocates from a different heap.
    # Keeping the identity inside the set made that check a use-after-free.
    # A literal integer initializer avoids __crystal_once and its boot-time
    # Thread.current allocation recursion. UInt128 keeps the single TLS
    # accessor introduced for the hit path without reading freed memory.
    @[ThreadLocal]
    @@tls_cursor_cache : UInt128 = 0_u128
    # Set by the thread-exit destructor: any allocation after it uses the
    # fallback set, so a retired set is never re-adopted by a dying thread.
    @[ThreadLocal]
    @@tls_cursor_exiting : UInt8 = 0_u8

    # Darwin: the hit path reads this thread's set from the heap's pthread
    # key slot (`cursor_set_hit`), 1 + the key once the slot has been checked
    # against `pthread_getspecific`, 0 before that or after `destroy`. One
    # word, written under `@cursor_lock` and read without it: a hit path that
    # sees it nonzero sees the whole key, never a key written apart from its
    # "ready" flag. `@cursor_tsd_refused` is set if the check ever fails, and
    # the hit path then stays on the Crystal thread-local for good.
    {% if flag?(:darwin) %}
      @cursor_tsd_slot = 0_u64
      @cursor_tsd_refused = false
    {% end %}

    getter bitmap_locked_allocations : UInt64 = 0_u64
    getter bitmap_alloc_refills : UInt64 = 0_u64
    # Hit-path census. `cursor_word_advances` counts the cursor moving to the
    # next word of the chunk it holds with no lock (`cursor_advance_word`);
    # the `fast_miss_*` counters say why an allocation left the hit path for
    # the locked one. Plain increments, best-effort across threads, exact for
    # one mutator — the same standing as `bitmap_locked_allocations`.
    getter cursor_word_advances : UInt64 = 0_u64
    getter fast_miss_collecting : UInt64 = 0_u64
    getter fast_miss_size : UInt64 = 0_u64
    getter fast_miss_no_set : UInt64 = 0_u64
    getter fast_miss_refill : UInt64 = 0_u64
    getter fast_miss_threshold : UInt64 = 0_u64
    getter bitmap_alloc_chunk_advances : UInt64 = 0_u64
    getter bitmap_dormant_revives : UInt64 = 0_u64
    # Claimed blocks a retiring cursor gave back unused (`cursor_release_claim`):
    # the cost of claiming a word ahead, and the evidence for the specs that
    # retirement releases. Plain increments: exact in a stop, best-effort
    # across classes retiring under their own locks, like the counters above.
    getter cursor_claims_released : UInt64 = 0_u64
    # Research only: called by `bitmap_take_pool_chunk` with the chunk it is
    # about to take, after `bitmap_pool_candidate?` accepted it and before
    # CURSOR is set, under the class lock and `@chunk_list_lock` — on the
    # allocating thread, so it must not allocate. A hook that parks its
    # thread there until a stop has come and gone puts the stop's sweep
    # between a taker's check and its take, every time
    # (`process_spec/regression/80_stop_sweep_frozen_pool_taker_spec.cr`).
    property pool_take_hook : Proc(ChunkHeader*, Nil)? = nil
    # Research only: called by `retire_cursor_slot` on the allocating thread,
    # under its class lock, right after it clears CURSOR on the chunk it is
    # retiring; must not allocate. A hook that parks its thread there until a
    # stop has come and gone puts the stop's sweep in the window
    # (`process_spec/regression/82_stop_sweep_frozen_cursor_retire_spec.cr`).
    property cursor_retire_hook : Proc(ChunkHeader*, Nil)? = nil
    # Research only: false retires a cursor slot in the order before
    # 2026-10-22 — CURSOR cleared, then the chunk read, then the slot
    # cleared — the control arm of regression 82 (`retire_cursor_slot`).
    property cursor_retire_slot_first : Bool = true

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

    # Research only — `GCRY_DISABLE_POOL_INDEX=1`: treat the available-chunk
    # index as invalid on every take, so each refill walks the class again.
    # `make pool-refill-cost --disabled` is the red arm. Never a product setting.
    property pool_index_disabled : Bool = false

    private def bitmap_capacity_changed(chunk : ChunkHeader*) : Nil
      bitmap_capacity_bump(bitmap_capacity_slot(chunk))
    end

    @[AlwaysInline]
    private def bitmap_capacity_slot(chunk : ChunkHeader*) : Int32
      slot = chunk.value.size_class.to_i32
      slot += SIZE_CLASS_COUNT if ChunkHeader.atomic?(chunk)
      slot
    end

    private def bitmap_capacity_bump(slot : Int32) : Nil
      # A signal can suspend an explicit free while the collector also frees
      # this class. Atomic addition prevents losing either invalidation.
      # Release/acquire publishes the preceding occupancy/ownership changes
      # with the generation on weakly ordered CPUs as well as x86.
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Add,
        @bitmap_capacity_versions.to_unsafe + slot, 1_u64,
        LLVM::AtomicOrdering::Release, false)
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
      cached = @@tls_cursor_cache
      return Pointer(CursorSet).null unless (cached >> 64) == self.as(Void*).address
      Pointer(CursorSet).new(cached.to_u64!)
    end

    # This thread's set for the hit path (`fast_alloc`) alone; everything
    # else asks `cursor_set_cached`, whose answer includes the fallback set.
    #
    # On Darwin a `@[ThreadLocal]` read is two out-of-line calls: Crystal's
    # `NoInline` accessor for the variable, then the variable's TLV thunk,
    # `tlv_get_addr`. On the hit path that was 8% of Binarytrees' run time on
    # an M1 (macos-latest: 81% → 87% of Boehm without it) and 11% on an
    # Intel Mac, where the thunk saves every register. With the unchecked
    # shift in `fast_alloc`, Binarytrees went 79% → 88% of Boehm on the M1
    # and 92% → 131% on Intel (`bench/log/macos/2026-10-16-binarytrees/`).
    # The heap's pthread key
    # already holds the same set — `cursor_set_under_lock` stores it there
    # when the thread claims it, for the exit destructor — so the hit path
    # reads the key's slot directly, as `pthread_getspecific` itself does in
    # libpthread (`_pthread_getspecific_direct`): one register read and one
    # load (`Platform.tsd_read`). Go's runtime reads its `g` the same way on
    # darwin/arm64.
    #
    # Why the slot is never stale: a slot holds a set only from the owner's
    # claim, and only its owner reads it. Darwin clears a thread's slot
    # before it runs the key's exit destructor, and `pthread_key_delete`
    # (`destroy`) clears it in every thread, so a recycled key starts empty
    # (libpthread `pthread_tsd.c`). Sets are freed only by `destroy`; a set is
    # retired and reused only after its owner's destructor ran, or in a fork
    # child for threads that no longer exist. A null slot — before the
    # claim, on the fallback set, on an exiting thread — sends the caller to
    # the locked path, which asks `cursor_set` and is always right.
    {% if flag?(:darwin) %}
      @[AlwaysInline]
      protected def cursor_set_hit : CursorSet*
        slot = @cursor_tsd_slot
        return cursor_set_cached if slot == 0_u64
        Gcry::Platform.tsd_read(slot &- 1).as(CursorSet*)
      end
    {% else %}
      @[AlwaysInline]
      protected def cursor_set_hit : CursorSet*
        cursor_set_cached
      end
    {% end %}

    # Whether the hit path reads the key slot (`cursor_set_hit`), for specs.
    def cursor_set_from_tsd? : Bool
      {% if flag?(:darwin) %}
        @cursor_tsd_slot != 0_u64
      {% else %}
        false
      {% end %}
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
      @@tls_cursor_cache = (self.as(Void*).address.to_u128 << 64) | set.address.to_u128
      set
    end

    private def cursor_set_under_lock(key : UInt64, exiting : Bool) : CursorSet*
      unless @cursor_key_ok
        @cursor_key_ok = Gcry::OS.pthread_key_create(pointerof(@cursor_key), ->(p : Void*) {
          # Thread exit. Plain stores: the collector reads them only with this
          # thread frozen or gone, and the fallback takes any later allocation.
          p.as(CursorSet*).value.state = CursorSet::STATE_EXITING
          @@tls_cursor_cache = 0_u128
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
      Gcry::OS.pthread_setspecific(@cursor_key, free.as(Void*))
      {% if flag?(:darwin) %}
        # The direct read is libpthread's layout, not its API: check it
        # against the API on every claim, and on any disagreement keep the
        # hit path on the Crystal thread-local for the life of the heap.
        if Gcry::Platform.tsd_read(@cursor_key.to_u64) == free.as(Void*) &&
           Gcry::OS.pthread_getspecific(@cursor_key) == free.as(Void*)
          @cursor_tsd_slot = @cursor_key.to_u64 &+ 1 unless @cursor_tsd_refused
        else
          @cursor_tsd_refused = true
          @cursor_tsd_slot = 0_u64
        end
      {% end %}
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
      yield @oom_reserve_set unless @oom_reserve_set.null?
    end

    protected def destroy_cursor_sets : Nil
      i = 0
      while i < POOL_SLOTS
        pool = @bitmap_pool_indexes.to_unsafe + i
        unless pool.value.addresses.null?
          Gcry.os_unmap(pool.value.addresses.as(Void*), pool.value.capacity.to_u64 * 8)
          pool.value.addresses = Pointer(UInt64).null
          pool.value.capacity = 0
          pool.value.valid = false
        end
        i += 1
      end
      # Drop this thread's cache before freeing its sets.
      @@tls_cursor_cache = 0_u128 unless cursor_set_cached.null?
      {% if flag?(:darwin) %}
        # Off before the key goes: `pthread_key_delete` empties the slot in
        # every thread, and nothing may read it by number after that.
        @cursor_tsd_slot = 0_u64
      {% end %}
      if @cursor_key_ok
        Gcry::OS.pthread_key_delete(@cursor_key)
        @cursor_key_ok = false
      end
      each_cursor_set { |set| LibC.free(set.as(Void*)) }
      @cursor_set_count = 0
      @fallback_cursor_set = Pointer(CursorSet).null
      @oom_reserve_set = Pointer(CursorSet).null
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

    # Drop the slot's chunk. What is left of its claim goes back first
    # (`cursor_release_claim`), and only then is the slot cleared. The caller
    # guarantees the owner is outside its allocation window — a stop with the
    # set not mid-allocation, or the owner's own thread — so the stored mask
    # is exactly the blocks not handed out.
    #
    # Everything this reads of the chunk it reads while the chunk is still
    # CURSOR, then it clears the slot, and clearing CURSOR is the last
    # access. The order is what a stop that freezes the owner part-way relies
    # on, because the in-stop sweep honours CURSOR and nothing else: it
    # cannot take the class lock the owner holds, and the finishing slice of
    # an incremental cycle runs no settle to pin anything. Until 2026-10-22
    # CURSOR went first, and then the chunk was read
    # (`bitmap_pool_candidate?`, `bitmap_capacity_changed`) and the slot
    # cleared. A refill that retires an exhausted chunk is frozen there with
    # the chunk no cursor's: if its blocks are all dead by then, the sweep
    # releases it — queued, then unmapped by the flush after `start_world`
    # — and the owner resumes into the chunk's header, and its slot names
    # the chunk for a later settle to write PINNED into. Frozen in this order
    # instead: before CURSOR is cleared the chunk is CURSOR and no slot
    # names it, which the sweep keeps, as it keeps a chunk a taker has just
    # set CURSOR on; after, nothing touches the chunk again.
    # `process_spec/regression/82_stop_sweep_frozen_cursor_retire_spec.cr`.
    #
    # Whether to publish capacity is decided before CURSOR is cleared, so a
    # free landing between the read and the clear is not seen here; it
    # published its own (`bitmap_free_block`), and a pool that missed both
    # finds the chunk at the next publication of its class.
    private def retire_cursor_slot(s : CursorSlot*, exhausted : Bool = false) : Nil
      return retire_cursor_slot_cursor_first(s, exhausted) unless @cursor_retire_slot_first
      chunk = s.value.chunk
      slot = 0
      publish = false
      unless chunk.null?
        cursor_release_claim(s, chunk)
        slot = bitmap_capacity_slot(chunk)
        # A concurrent free can restore a bit in a word this cursor already
        # passed. Another thread may have cached "empty" while we still owned
        # the chunk. Publish that capacity when ownership ends, even though
        # this cursor reached its last word. Scan this chunk only, not the heap.
        # Not for a reserve chunk, which no other cursor takes.
        publish = !exhausted || (!ChunkHeader.reserve?(chunk) && bitmap_chunk_has_free_block?(chunk))
      end
      CursorSlot.store_chunk(s, Pointer(ChunkHeader).null)
      CursorSlot.publish_mask(s, 0_u64)
      CursorSlot.store_word(s, 0)
      s.value.word_base = 0_u64
      unless chunk.null?
        # Signal fence, as in `cursor_claim_word`: the CURSOR clear is a
        # relaxed RMW, and nothing else stops the compiler hoisting it above
        # the slot stores — the order a stop on this thread relies on.
        Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, true)
        ChunkHeader.set_cursor(chunk, false)
        if hook = @cursor_retire_hook
          hook.call(chunk)
        end
        bitmap_capacity_bump(slot) if publish
      end
    end

    # The order before 2026-10-22, for the control arm of regression 82
    # (`cursor_retire_slot_first = false`): CURSOR cleared, the chunk read,
    # then the slot cleared.
    private def retire_cursor_slot_cursor_first(s : CursorSlot*, exhausted : Bool) : Nil
      chunk = s.value.chunk
      unless chunk.null?
        cursor_release_claim(s, chunk)
        ChunkHeader.set_cursor(chunk, false)
        if hook = @cursor_retire_hook
          hook.call(chunk)
        end
        if !exhausted || bitmap_pool_candidate?(chunk, chunk.value.size_class.to_i32, ChunkHeader.atomic?(chunk))
          bitmap_capacity_changed(chunk)
        end
      end
      CursorSlot.store_chunk(s, Pointer(ChunkHeader).null)
      CursorSlot.publish_mask(s, 0_u64)
      CursorSlot.store_word(s, 0)
      s.value.word_base = 0_u64
    end

    # Take *word* of the slot's chunk, whose free blocks are *mask*: point the
    # slot at it, then claim the blocks in `occ`, one atomic for the word
    # (point 1 of "Occupancy is claimed a word at a time"). The slot's mask is
    # zero on entry — the previous word is used up, or the chunk is new — so
    # the word changes while no claim is published.
    #
    # The order is what a stop that freezes the owner part-way relies on:
    # the mask is in the slot before anything is in `occ` or `mark`, so the
    # settle finds it and completes the claim itself (`cursor_premark_claim`),
    # and the flags are read only after the mask is stored, so a claim that
    # skipped its marks read them before any stop of this cycle and is
    # settled by it. `mark` before `occ`: the incremental finishing slice
    # sweeps with no settle, so a stop between the two must find the bits
    # marked and not yet occupied — which `occ = mark` turns into the claim
    # — and never occupied and unmarked, which it would reclaim as dead.
    @[AlwaysInline]
    private def cursor_claim_word(s : CursorSlot*, chunk : ChunkHeader*, word : Int32,
                                  mask : UInt64, index : Int32) : Nil
      CursorSlot.store_word(s, word)
      s.value.word_base = ChunkHeader.data_start(chunk).address &+
                          (word.to_u64 << 6) &* @block_bytes[index]
      CursorSlot.publish_mask(s, mask)
      Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, true)
      # A sweep may run before the next stop: the after-world sweep, or the
      # finishing slice of an incremental cycle. Claimed blocks are not
      # objects, so they must not be swept as dead ones (allocate-black for
      # the whole word; the sweep's `live` takes them back out).
      if @collecting || @incremental_marking || @lazy_sweep_pending
        mark = ChunkHeader.mark_bitmap(chunk)
        unless mark.null?
          Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, mark + word, mask,
            LLVM::AtomicOrdering::Monotonic, false)
        end
      end
      # Release: a thread that sees these bits sees the mask that names them
      # as claimed (`block_allocated_exact?`).
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, ChunkHeader.occ_bitmap(chunk) + word, mask,
        LLVM::AtomicOrdering::Release, false)
    end

    # Give back the blocks of the slot's claim it did not hand out: clear them
    # from `occ`, and from `mark` (claims made while a sweep could run are
    # marked, and a mark with no occupancy behind it would be resurrected by
    # the next `occ = mark`). Atomic AND: a `free` may be clearing other bits
    # of the word. The mask goes to zero after the bits, so a reader that
    # still finds it finds them already clear (`block_allocated_exact?`).
    private def cursor_release_claim(s : CursorSlot*, chunk : ChunkHeader*) : Nil
      mask = s.value.free_mask
      return if mask == 0_u64
      word = s.value.word
      occ = ChunkHeader.occ_bitmap(chunk)
      unless occ.null?
        Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And, occ + word, ~mask,
          LLVM::AtomicOrdering::Monotonic, false)
      end
      mark = ChunkHeader.mark_bitmap(chunk)
      unless mark.null?
        Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And, mark + word, ~mask,
          LLVM::AtomicOrdering::Monotonic, false)
      end
      CursorSlot.publish_mask(s, 0_u64)
      @cursor_claims_released &+= mask.popcount.to_u64
    end

    # A set frozen mid-allocation keeps its chunks across the stop, and its
    # claims with them. Mark each claim and complete it in `occ` (the owner
    # may be frozen between storing its mask and its OR; finishing the OR
    # here is idempotent with the owner's): the mark makes the in-stop sweep
    # keep the bits and keeps the trace out of blocks that hold no object
    # yet, including one the owner has published as `in_flight` but not yet
    # popped. The mask and the word agree at every point the owner can be
    # frozen at (`cursor_claim_word`).
    private def cursor_premark_claim(s : CursorSlot*, chunk : ChunkHeader*) : Nil
      mask = s.value.free_mask
      return if mask == 0_u64
      word = s.value.word
      mark = ChunkHeader.mark_bitmap(chunk)
      unless mark.null?
        Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, mark + word, mask,
          LLVM::AtomicOrdering::Monotonic, false)
      end
      occ = ChunkHeader.occ_bitmap(chunk)
      unless occ.null?
        Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, occ + word, mask,
          LLVM::AtomicOrdering::Monotonic, false)
      end
    end

    # Stop-the-world, before the roots are marked. Three things, in order:
    # chunks pinned through the previous cycle were skipped by its after-world
    # sweep, so their marks are stale and are zeroed here; every set's
    # counters are credited; then each set is either retired — its chunks go
    # back to the pool lists with their claims released, and its owner
    # refills under the lock when it resumes — or, if its owner is frozen
    # mid-allocation, left alone with its chunks pinned and its claims
    # marked, because that owner will finish its allocation from them,
    # without the class lock, when it resumes.
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
            s = CursorSet.slot(set, i)
            chunk = s.value.chunk
            unless chunk.null?
              ChunkHeader.set_pinned(chunk, true)
              cursor_premark_claim(s, chunk)
            end
            i += 1
          end
          # The out-of-memory reserve's set is never on the hit path, so it is
          # pinned at every stop; counting it would add one per collection to
          # a number that says a mutator was frozen mid-allocation.
          @cursor_sets_pinned &+= 1 unless set == @oom_reserve_set
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

    # Drop the slot's copy once the caller's frame holds the pointer - but
    # only if it is still *this* call's pointer. A thread past the 64th (or
    # one whose pthread key failed) shares `@fallback_cursor_set`, and this
    # runs after `with_freelist_lock` released the class lock, so the slot may
    # already carry a peer's sentinel or freshly published address; a plain
    # null store would erase that peer's root before its frame holds the
    # block. The locked path pays a CAS here, never the hit path.
    protected def clear_bitmap_alloc_in_flight(index : Int32, flags : UInt32, user : Void*) : Nil
      set = oom_reserve_active? ? @oom_reserve_set : cursor_set_cached
      return if set.null?
      slot = (flags & BlockHeader::Flags::ATOMIC) != 0 ? index + SIZE_CLASS_COUNT : index
      s = CursorSet.slot(set, slot)
      field = (s.as(UInt8*) + offsetof(CursorSlot, @in_flight)).as(UInt64*)
      Atomic::Ops.cmpxchg(field, user.address, 0_u64,
        LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::Monotonic)
    end

    # Fork child: only the forking thread survived. Drop every publication (a
    # slot another thread left mid-handover would be rooted from every
    # collection for the life of the child), rebuild `@cursor_lock` (a fork
    # taken while another thread held it - its first allocation on this heap
    # - would leave it held forever, and the child's next new thread would
    # spin in `cursor_set`), and mark every set the survivor does not own as
    # exiting so the next stop-the-world frees its slot instead of carrying
    # a dead owner's key until the table fills and every later thread falls
    # back to the shared set.
    protected def reset_cursor_sets_after_fork : Nil
      @cursor_lock = Crystal::SpinLock.new
      mine = cursor_set_cached
      each_cursor_set do |set|
        i = 0
        while i < POOL_SLOTS
          CursorSet.slot(set, i).value.in_flight = Pointer(Void).null
          i += 1
        end
        if set != mine && set != @fallback_cursor_set && set != @oom_reserve_set &&
           set.value.state == CursorSet::STATE_LIVE
          set.value.state = CursorSet::STATE_EXITING
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

    # Handed out and not freed: a block a cursor has claimed and not handed
    # out yet is not allocated (`block_allocated_exact?`).
    def block_allocated_public?(chunk : ChunkHeader*, header : BlockHeader*) : Bool
      block_allocated_exact?(chunk, header)
    end

    def bitmap_alloc_chunk_public?(chunk : ChunkHeader*) : Bool
      bitmap_alloc_chunk?(chunk)
    end

    # Allocated blocks in a chunk, straight from `occ` — one popcount pass
    # instead of a header walk — less the blocks its cursor has claimed and
    # not handed out (`cursor_claim`). Exact on a quiescent heap or in a
    # stop; with the chunk's owner allocating it is one reading of a moving
    # count, as any walk is.
    def chunk_occupied_count(chunk : ChunkHeader*) : UInt64
      occ = ChunkHeader.occ_bitmap(chunk)
      return 0_u64 if occ.null?
      n = @kernels.popcount_words(occ, chunk.value.bitmap_words.to_i32)
      claimed = chunk_claimed_count(chunk)
      n > claimed ? n - claimed : 0_u64
    end

    # Blocks of *chunk* its cursor has claimed and not handed out. Zero
    # unless a cursor holds the chunk.
    protected def chunk_claimed_count(chunk : ChunkHeader*) : UInt64
      word, mask = cursor_claim(chunk)
      return 0_u64 if word < 0 || mask == 0_u64
      occ = ChunkHeader.occ_bitmap(chunk)
      return 0_u64 if occ.null?
      (Atomic::Ops.load(occ + word, LLVM::AtomicOrdering::Acquire, false) & mask).popcount.to_u64
    end

    # The claim on *chunk*: the word its cursor is on and that word's blocks
    # not handed out yet, or `{-1, 0}` when no cursor holds the chunk.
    #
    # The holder is one slot (CURSOR is exclusive), at the chunk's (class,
    # kind) index of some set: this thread's set is asked first, which is
    # the whole search when a thread frees what it allocated. A slot is read
    # by `slot_claim`, which needs no lock and takes none, so a stop that
    # freezes the reader holds nothing.
    protected def cursor_claim(chunk : ChunkHeader*) : {Int32, UInt64}
      return {-1, 0_u64} unless ChunkHeader.cursor?(chunk)
      class_index = chunk.value.size_class.to_i32
      return {-1, 0_u64} if class_index < 0 || class_index >= SIZE_CLASS_COUNT
      slot = ChunkHeader.atomic?(chunk) ? class_index + SIZE_CLASS_COUNT : class_index
      own = cursor_set_cached
      unless own.null?
        word, mask = slot_claim(CursorSet.slot(own, slot), chunk)
        return {word, mask} if word >= 0
      end
      each_cursor_set do |set|
        # A set appended by another thread is published by its count; the
        # entry may not be visible yet, and it cannot hold this chunk unless
        # it took it under the class lock, which then orders the entry.
        next if set.null? || set == own
        word, mask = slot_claim(CursorSet.slot(set, slot), chunk)
        return {word, mask} if word >= 0
      end
      {-1, 0_u64}
    end

    # One slot's claim on *chunk*, `{-1, 0}` when the slot is elsewhere. The
    # word and the chunk are read on both sides of the mask, with acquire
    # loads, and read again if either moved. The owner stores the word before
    # a nonzero mask (release) and zeroes the mask before the word or the
    # chunk changes (`cursor_claim_word`, `retire_cursor_slot`), so a mask
    # read between two equal readings belongs to that word.
    #
    # Exact with the owner frozen (a stop: nothing moves, one pass), and under
    # the chunk's class lock (`free`): the owner cannot leave the chunk
    # without that lock, and within one hold its word only grows, so two
    # equal readings cannot straddle a change, and the loop ends after at
    # most one pass per word of the chunk. Anywhere else it is one consistent
    # reading of a cursor that may have moved on since.
    @[AlwaysInline]
    private def slot_claim(s : CursorSlot*, chunk : ChunkHeader*) : {Int32, UInt64}
      loop do
        c1 = Atomic::Ops.load(CursorSlot.chunk_field(s), LLVM::AtomicOrdering::Acquire, false)
        return {-1, 0_u64} unless c1 == chunk.address
        w1 = Atomic::Ops.load(CursorSlot.word_field(s), LLVM::AtomicOrdering::Acquire, false)
        mask = Atomic::Ops.load(CursorSlot.mask_field(s), LLVM::AtomicOrdering::Acquire, false)
        w2 = Atomic::Ops.load(CursorSlot.word_field(s), LLVM::AtomicOrdering::Acquire, false)
        c2 = Atomic::Ops.load(CursorSlot.chunk_field(s), LLVM::AtomicOrdering::Acquire, false)
        return {w1, mask} if w1 == w2 && c1 == c2
      end
    end

    # `block_allocated?` without the blocks a cursor has claimed and not
    # handed out: handed out and not freed. What `free`, `live?` and every
    # diagnostic mean by allocated; the mark and the sweep read `occ` raw
    # (see "Occupancy is claimed a word at a time").
    #
    # `occ` is read before the claim and again after it. Before: a bit a claim
    # set is seen with that claim's mask, which the owner stored ahead of its
    # release OR (acquire here), so it is found claimed — or handed out since,
    # which no reader can tell from a free racing the hand-out, the same race
    # the per-block OR had. After: a bit a retire released while the claim
    # was read is found clear. Under the class lock (`free`) nothing else can
    # change the bit between the two reads.
    protected def block_allocated_exact?(chunk : ChunkHeader*, header : BlockHeader*) : Bool
      return block_allocated?(chunk, header) unless bitmap_alloc_chunk?(chunk)
      occ = ChunkHeader.occ_bitmap(chunk)
      return block_allocated?(chunk, header) if occ.null?
      ordinal = chunk_block_ordinal(chunk, header.address)
      word = (ordinal >> 6).to_i32
      bit = 1_u64 << (ordinal & 63)
      return false if (Atomic::Ops.load(occ + word, LLVM::AtomicOrdering::Acquire, false) & bit) == 0
      return true unless ChunkHeader.cursor?(chunk)
      claim_word, claim_mask = cursor_claim(chunk)
      return false if claim_word == word && (claim_mask & bit) != 0
      (Atomic::Ops.load(occ + word, LLVM::AtomicOrdering::Acquire, false) & bit) != 0
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
    # `blsr`, one address computation. The `occ` bit was set by the claim.
    protected def bitmap_alloc_locked(index : Int32, payload : UInt32, flags : UInt32) : Void*
      # Kind comes from the request's own flags, so callers are unchanged. The
      # cursor is per (class, kind) because atomic and pointerful blocks live in
      # different chunks now; `@block_bytes` stays class-indexed.
      atomic = (flags & BlockHeader::Flags::ATOMIC) != 0
      slot = atomic ? index + SIZE_CLASS_COUNT : index
      return Pointer(Void).null if oom_test_refuse?
      # A thread reporting an out-of-memory error takes its blocks from the
      # reserve (`oom_reserve.cr`), not from its own set.
      reserve = oom_reserve_active?
      set = reserve ? @oom_reserve_set : cursor_set
      # C-heap metadata can fail before a cursor exists. Let the caller retry
      # collection and raise OOM after releasing the class lock.
      return Pointer(Void).null if set.null?
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
        unless bitmap_refill_pool(s, index, payload, atomic, reserve)
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
      chunk = s.value.chunk
      word = s.value.word

      # Publish the block as a root **before** the pop hands it out: from the
      # pop until the caller holds the pointer the block is occupied (claimed),
      # out of the slot's mask, and referenced only by a header address the
      # root scan refuses. Before the pop it is still in the mask, which a
      # stop marks (`cursor_premark_claim`). The fence keeps the compiler from
      # sinking the publication below the pop.
      header_addr = s.value.word_base &+ bit.to_u64 &* @block_bytes[index]
      s.value.in_flight = Pointer(Void).new(header_addr &+ BlockHeader::SIZE)
      Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, true)
      # `blsr`: clear the lowest set bit. The block's `occ` bit has been set
      # since the claim, so this is the whole allocation.
      CursorSlot.store_mask(s, mask & (mask &- 1))

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
      @oom_reserve_allocations &+= 1 if reserve
      BlockHeader.user_from(header)
    end

    # Move a held cursor to the next word of its chunk that has free blocks,
    # with no lock. The chunk is CURSOR-held: no other cursor takes it and a
    # sweep with the world running leaves it alone (a set frozen
    # mid-allocation keeps its chunks pinned across the stop, an idle one is
    # retired there and never gets here). The one concurrent writer of its
    # occupancy is a `free` clearing a bit, and the locked refill tolerates
    # that the same way — a block freed behind the cursor is found on the
    # chunk's next pass; the claim (`cursor_claim_word`) sets only bits it
    # found clear, which no `free` touches. The blacklist is written only
    # while marking, when this thread is stopped. Runs inside the
    # mid-allocation window, so a stop-the-world that lands during the scan
    # pins the set rather than retiring the slot under it. Zero when the slot
    # holds no chunk or the chunk is exhausted; the caller then takes the
    # locked path, which retires the chunk and takes another from the pool.
    #
    # Measured before this: 96% of locked refills (`bitmap_alloc_refills`
    # 705 k against `bitmap_alloc_chunk_advances` 29 k per 15 s of Kemal
    # `/json`) were exactly this word advance, taken under the class lock.
    @[AlwaysInline]
    protected def cursor_advance_word(s : CursorSlot*, index : Int32) : UInt64
      chunk = s.value.chunk
      return 0_u64 if chunk.null?
      nblocks = chunk_block_count(chunk)
      words = ((nblocks + 63) >> 6).to_i32
      word = s.value.word
      while word < words
        mask = chunk_free_mask(chunk, word, nblocks)
        if mask != 0_u64
          cursor_claim_word(s, chunk, word, mask, index)
          @cursor_word_advances &+= 1
          return mask
        end
        word += 1
      end
      0_u64
    end

    # Advance the cursor to the next word with a free block, taking another
    # chunk from the class's pool list when the current one is exhausted.
    protected def bitmap_refill_pool(s : CursorSlot*, index : Int32, payload : UInt32,
                                     atomic : Bool, reserve : Bool = false) : Bool
      loop do
        chunk = s.value.chunk
        if chunk.null?
          chunk = reserve ? oom_reserve_take_chunk(index, atomic) : bitmap_take_pool_chunk(index, payload, atomic)
          return false if chunk.null?
          # In use again: a fully free chunk past the warm budget keeps its
          # one cycle of grace only while nothing takes it.
          ChunkHeader.set_idle(chunk, false) if ChunkHeader.idle?(chunk)
          CursorSlot.store_chunk(s, chunk)
          CursorSlot.store_word(s, 0)
          @bitmap_alloc_chunk_advances &+= 1
        end

        nblocks = chunk_block_count(chunk)
        words = ((nblocks + 63) >> 6).to_i32
        word = s.value.word
        while word < words
          mask = chunk_free_mask(chunk, word, nblocks)
          if mask != 0_u64
            cursor_claim_word(s, chunk, word, mask, index)
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
    # Return a CURSOR-owned chunk: the STW sweep ignores the caller's class
    # lock, so ownership must survive the handoff to bitmap_refill_pool.
    protected def bitmap_take_pool_chunk(index : Int32, payload : UInt32,
                                         atomic : Bool) : ChunkHeader*
      slot = atomic ? index + SIZE_CLASS_COUNT : index
      version = Atomic::Ops.load(@bitmap_capacity_versions.to_unsafe + slot,
        LLVM::AtomicOrdering::Acquire, false)
      pool = @bitmap_pool_indexes.to_unsafe + slot
      pool.value.valid = false if @pool_index_disabled
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
        # First refill of this slot: size the index before the walk, so the
        # common case indexes on its first pass. Outside the list lock (below):
        # an mmap under that spinlock would stall every `map_chunk` and
        # `unlink_chunk` on other threads for the syscall.
        bitmap_pool_grow(pool, 1) if pool.value.capacity == 0
        best = Pointer(ChunkHeader).null
        candidates = 0
        with_chunk_list_for_allocation do
          each_chunk do |chunk|
            next unless bitmap_pool_candidate?(chunk, index, atomic)
            best = chunk if best.null? || chunk.address < best.address
            # Overflow is only counted here; the walk never allocates.
            pool.value.addresses[candidates] = chunk.address if candidates < pool.value.capacity
            candidates += 1
          end
          # The overflow fallback keeps this pointer across the unlocked
          # metadata grow below. Pin it before releasing list protection.
          ChunkHeader.set_cursor(best, true) if candidates > pool.value.capacity
        end
        if candidates > pool.value.capacity
          # Grow now, outside the walk, so the next refill indexes fully. This
          # one falls back to the lowest-address search result. OOM in optional
          # metadata must not raise under the class lock: a failed grow leaves
          # the pool as it was and the fallback still stands. Never publish a
          # truncated available-chunk index.
          bitmap_pool_grow(pool, candidates)
          return best
        end
        pool.value.count = candidates
        pool.value.addresses.to_slice(candidates).sort! if candidates > 1
        pool.value.version = version
        pool.value.blacklist_enabled = @blacklist_enabled
        pool.value.valid = true
      end

      while pool.value.next_index < pool.value.count
        at = pool.value.next_index
        pool.value.next_index = at + 1
        address = pool.value.addresses[at]
        # A stale address is harmless only after this lookup. Do not cast it
        # to ChunkHeader* or read its flags before the live index accepts it.
        # The check and the CURSOR store are one hold of the list lock: the
        # chunk is nobody's between them, and an in-stop sweep that finds the
        # lock held by a frozen thread makes no chunk dormant (`Heap#sweep`).
        with_chunk_list_for_allocation do
          if chunk = bitmap_indexed_chunk(address)
            if chunk.address == address && bitmap_pool_candidate?(chunk, index, atomic)
              if hook = @pool_take_hook
                hook.call(chunk)
              end
              ChunkHeader.set_cursor(chunk, true)
              return chunk
            end
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
      chunk = map_chunk(@small_chunk_bytes, index.to_u32,
        ChunkHeader::Flags::CURSOR | (atomic ? ChunkHeader::Flags::ATOMIC : 0_u32))
      bitmap_credit_capacity(chunk)
      chunk
    end

    # A fresh bitmap chunk's blocks are free capacity, and `free_bytes` is
    # where capacity is kept: everything after this subtracts from it (an
    # allocation, its credit, the sweep's unmap of an empty chunk) or adds
    # back to it (a free, the sweep's reclaim). `refill_size_class` does the
    # same for a header chunk. Until 2026-10-14 nothing did it here, so on
    # the default layout every block from a fresh chunk was subtracted from
    # capacity never added, the subtraction saturated, and `free_bytes` read
    # 0 on a quiet heap with 2 199 744 bytes free
    # (process_spec/regression/70). Dormant chunks keep their capacity, as
    # header chunks do, and revival adds none.
    protected def bitmap_credit_capacity(chunk : ChunkHeader*) : Nil
      return if chunk.null?
      class_index = chunk.value.size_class.to_i32
      return if class_index < 0 || class_index >= SIZE_CLASS_COUNT
      free_bytes_add(chunk_block_count(chunk) &* SizeClasses.payload(class_index).to_u64)
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

    # *reserve* picks which chunks are candidates at all: the reserve's cursor
    # takes only reserve chunks and every other cursor never does.
    private def bitmap_pool_candidate?(chunk : ChunkHeader*, index : Int32, atomic : Bool,
                                       reserve : Bool = false) : Bool
      return false if ChunkHeader.large?(chunk) || chunk.value.size_class != index.to_u32
      return false unless ChunkHeader.atomic?(chunk) == atomic
      return false unless ChunkHeader.reserve?(chunk) == reserve
      return false if ChunkHeader.dormant?(chunk) || ChunkHeader.nursery?(chunk) || ChunkHeader.cursor?(chunk)
      bitmap_chunk_has_free_block?(chunk)
    end

    # Whether `occ` (and the blacklist) leaves any block of *chunk* free.
    private def bitmap_chunk_has_free_block?(chunk : ChunkHeader*) : Bool
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

    # Replace the pool's address buffer with one holding at least `needed`
    # entries. Contents are not carried over: callers grow only while the pool
    # is invalid and about to be rebuilt. Returns false on OOM, leaving the old
    # buffer in place.
    private def bitmap_pool_grow(pool : BitmapPoolIndex*, needed : Int32) : Bool
      capacity = pool.value.capacity == 0 ? 512 : pool.value.capacity
      while capacity < needed
        return false if capacity > Int32::MAX // 2
        capacity *= 2
      end
      return true if capacity == pool.value.capacity
      bytes = capacity.to_u64 * 8
      memory = Gcry.os_map(bytes)
      return false if Gcry.mmap_failed?(memory)
      unless pool.value.addresses.null?
        Gcry.os_unmap(pool.value.addresses.as(Void*), pool.value.capacity.to_u64 * 8)
      end
      pool.value.addresses = memory.as(UInt64*)
      pool.value.capacity = capacity
      true
    end

    # Bitmap-path counterpart of `revive_dormant_chunk`: no freelist, no header
    # writes. Same flag flip and byte accounting as the header path; free bytes
    # were never subtracted when the chunk went dormant, so none are added back.
    private def bitmap_revive_dormant(index : Int32, atomic : Bool) : {ChunkHeader*?, Bool}
      chunk = dormant_chunk_for_allocation(index, false, atomic)
      return {nil, false} unless chunk
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
          # A suspended reviver must be either dormant (skipped) or cursor
          # owned (pinned) throughout the transition and bitmap reset.
          ChunkHeader.set_cursor(chunk, true)
          ChunkHeader.set_dormant(chunk, false)
        end
      end
      return {nil, true} if refused
      # The chunk is this thread's cursor now and nothing allocates from it
      # until this returns: announce the reuse of its released pages here.
      lo, hi = dormant_release_range(chunk)
      Platform.reuse_released_pages(lo, hi - lo) if hi > lo
      mapped = chunk.value.mapped_bytes
      # After the flag, under no lock the sweep takes: kept exact by the
      # transitions (`@dormant_chunk_bytes`), not by the sweep's recount.
      dormant_bytes_sub(mapped)
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
      {chunk, false}
    end

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
    # Both clears are atomic for the usual reason: 64 blocks share each word,
    # and a cursor's claim and release write other bits of the same word.
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
    # *after* its block became occupied but before the block's address exists
    # in any register the root scan can see. That block is `occ=1, mark=0`,
    # unreachable, and `occ &= mark` would free it under the mutator — which
    # then returns a dangling pointer. Under the pin the word is not swept
    # after the stop, and the stop's own sweep keeps it because the settle
    # marks the pinned set's claim (`cursor_premark_claim`) and roots its
    # `in_flight` block.
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
    # its own caller is holding — observed as `process_spec` hanging on
    # the headerless layout.
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
