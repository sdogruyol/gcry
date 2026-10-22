# Thread-local allocation buffers (TLAB): each mutator OS thread takes a private
# freelist head per size-class so parallel ExecutionContexts can allocate without
# racing on the global freelist. Chunk refill takes the per-size-class freelist
# SpinLock (not the global @alloc_lock).
#
# Fields (@alloc_lock, @freelist_locks, @tlab_enabled, …) are in heap.cr.

require "./platform/os"

module Gcry
  class Heap
    MAX_TLABS = 64

    struct Tlab
      property freelists : StaticArray(Void*, SIZE_CLASS_COUNT)
      property nursery_freelists : StaticArray(Void*, SIZE_CLASS_COUNT)
      property owner : UInt64
      property live : Bool

      def initialize
        @freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
        @nursery_freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
        @owner = 0_u64
        @live = false
      end
    end

    @tlabs = uninitialized StaticArray(Tlab, MAX_TLABS)
    # Per-slot locks: must not GC-allocate under @alloc_lock (Pointer.malloc
    # → GC.malloc → re-enter alloc → non-recursive SpinLock deadlock at boot).
    @tlab_slot_locks = uninitialized StaticArray(Crystal::SpinLock, MAX_TLABS)

    # TLAB-off USED stash (see alloc_old_small_batched). Same slot count as TLAB.
    struct AllocBatch
      property freelists : StaticArray(Void*, SIZE_CLASS_COUNT)
      property owner : UInt64
      property live : Bool

      def initialize
        @freelists = StaticArray(Void*, SIZE_CLASS_COUNT).new(Pointer(Void).null)
        @owner = 0_u64
        @live = false
      end
    end

    @alloc_batches = uninitialized StaticArray(AllocBatch, MAX_TLABS)
    @alloc_batch_slot_locks = uninitialized StaticArray(Crystal::SpinLock, MAX_TLABS)

    def tlab_enabled? : Bool
      @tlab_enabled
    end

    # Refused under the bitmap allocator, which is the other half of
    # `bitmap_alloc=`'s exclusion. That setter clears `@tlab_enabled` because
    # two allocators must not hand out the same blocks, but the env wiring
    # applies `GCRY_TLAB=1` *after* the heap exists, so the pair was
    # reachable — and the allocation paths' own `!@bitmap_alloc` guards do not
    # cover what follows from it: `sweep_after_world?` returns false while
    # TLAB is on, which silently moves a bitmap heap onto the in-STW sweep.
    def tlab_enabled=(value : Bool) : Bool
      return false if value && @bitmap_alloc
      @tlab_enabled = value
    end

    def tlab_refills : UInt64
      @tlab_refills
    end

    getter tlab_refill_discards : UInt64

    def tlab_steals : UInt64
      @tlab_steals
    end

    def tlab_hits : UInt64
      @tlab_hits.get
    end

    def alloc_batch_hits : UInt64
      @alloc_batch_hits.get
    end

    def alloc_batch_refills : UInt64
      @alloc_batch_refills
    end

    protected def ensure_tlabs : Nil
      return if @tlabs_booted
      @alloc_lock.sync { ensure_tlabs_under_lock }
    end

    # Caller holds @alloc_lock.
    private def ensure_tlabs_under_lock : Nil
      return if @tlabs_booted
      MAX_TLABS.times do |i|
        @tlabs[i] = Tlab.new
        @tlab_slot_locks[i] = Crystal::SpinLock.new
      end
      @tlabs_booted = true
    end

    private def tlab_slot_index(tlab : Tlab*) : Int32
      ((tlab.address - @tlabs.to_unsafe.address) // sizeof(Tlab)).to_i32
    end

    private def lock_tlab_slot(slot : Int32) : Nil
      # Pointer receiver so SpinLock.@m is mutated in place (not a copy).
      (@tlab_slot_locks.to_unsafe + slot).value.lock
    end

    private def unlock_tlab_slot(slot : Int32) : Nil
      (@tlab_slot_locks.to_unsafe + slot).value.unlock
    end

    # Large-object path + TLAB table boot. SpinLock only — pthread_mutex ×
    # STW suspend-while-holding deadlocks.
    protected def with_alloc_lock(&)
      @alloc_lock.sync { yield }
    end

    # Per-size-class global freelist (old or nursery). STW sweep must not take
    # these (suspended mutator may hold one). Lock order: freelist → @alloc_lock
    # (never reverse).
    private def init_freelist_locks : Nil
      SIZE_CLASS_COUNT.times do |i|
        @freelist_locks[i] = Crystal::SpinLock.new
        @nursery_freelist_locks[i] = Crystal::SpinLock.new
      end
    end

    private def freelist_lock_ptr(index : Int32, nursery : Bool) : Crystal::SpinLock*
      if nursery
        @nursery_freelist_locks.to_unsafe + index
      else
        @freelist_locks.to_unsafe + index
      end
    end

    protected def with_freelist_lock(index : Int32, nursery : Bool, &)
      lock = freelist_lock_ptr(index, nursery)
      lock.value.lock
      begin
        yield
      ensure
        lock.value.unlock
      end
    end

    # Every lock a small allocation of `index` can take, held together: each
    # TLAB slot, then the class freelist, then each allocation-batch slot
    # (the slots' fast paths hand out blocks that are still FREE-headed and
    # off the global freelist). TLAB slots before the class lock — the TLAB
    # path holds its slot lock when it refills under the freelist lock, so
    # that is the order it establishes. Batch slots after it: a batch refill
    # publishes its stash into its slot while it holds the class lock
    # (`refill_alloc_batch`, class → batch slot). Until 2026-10-22 the batch
    # slots were taken first, with the TLAB slots, and a refill holding the
    # class lock and waiting for its slot deadlocked against a release
    # holding every slot and waiting for the class lock
    # (`process_spec/regression/84_stop_sweep_frozen_freelist_holder_spec.cr`,
    # the exclusion arms).
    #
    # This is what makes a post-STW page release sound: a run of free pages is
    # computed from block headers and then handed to `madvise` with the world
    # running, and any block in it handed out in between would be zeroed
    # after the mutator wrote it (`make page-release-corruption`, 4 of 28
    # before this). Under these locks nothing can be handed out until the
    # syscall has returned. Only the opt-in release walks pay for it.
    protected def with_small_allocation_excluded(index : Int32, nursery : Bool, &)
      batch_first = @small_exclusion_batch_first
      i = 0
      while i < MAX_TLABS
        (@tlab_slot_locks.to_unsafe + i).value.lock
        (@alloc_batch_slot_locks.to_unsafe + i).value.lock if batch_first
        i += 1
      end
      begin
        with_freelist_lock(index, nursery) do
          unless batch_first
            i = 0
            while i < MAX_TLABS
              (@alloc_batch_slot_locks.to_unsafe + i).value.lock
              i += 1
            end
          end
          begin
            yield
          ensure
            unless batch_first
              i = MAX_TLABS - 1
              while i >= 0
                (@alloc_batch_slot_locks.to_unsafe + i).value.unlock
                i -= 1
              end
            end
          end
        end
      ensure
        i = MAX_TLABS - 1
        while i >= 0
          (@alloc_batch_slot_locks.to_unsafe + i).value.unlock if batch_first
          (@tlab_slot_locks.to_unsafe + i).value.unlock
          i -= 1
        end
      end
    end

    # Research only: true takes the allocation-batch slot locks with the TLAB
    # slots, before the class lock — the order before 2026-10-22, and the
    # control arm of regression 84's exclusion window.
    property small_exclusion_batch_first : Bool = false

    # For regression 84: run `with_small_allocation_excluded` with an empty
    # block, as a release walk does.
    def exclude_small_allocation_for_spec(index : Int32) : Nil
      with_small_allocation_excluded(index, false) { }
    end

    private def current_thread_key : UInt64
      {% if flag?(:win32) %}
        Platform.current_thread_id
      {% elsif flag?(:wasm32) %}
        1_u64
      {% elsif flag?(:darwin) || flag?(:musl) %}
        # PthreadT is Void* — no integer conversion (same as darwin).
        Gcry::OS.pthread_self.as(Void*).address
      {% else %}
        Gcry::OS.pthread_self.to_u64!
      {% end %}
    end

    protected def current_tlab : Tlab*
      ensure_tlabs
      key = current_thread_key
      i = 0
      while i < MAX_TLABS
        if @tlabs[i].live && @tlabs[i].owner == key
          return @tlabs.to_unsafe + i
        end
        i += 1
      end
      @alloc_lock.sync { current_tlab_under_lock(key) }
    end

    # Caller must hold @alloc_lock (or be single-threaded).
    #
    # Every write to a slot goes through a pointer. `@tlabs[i].owner = key` —
    # what this said from TLAB's first commit (51ae436, 2026-07-24) until
    # 2026-09-27 — assigns to a *copy*: `StaticArray#[]` returns the struct by
    # value. No slot was ever claimed, so every thread got slot 0 and shared
    # it; and `flush_all_tlabs`, which skips slots that are not live, never
    # flushed one. A TLAB's chain survived every collection, the sweep read
    # its blocks as free, made their chunk dormant or relinked them onto the
    # class list, and the TLAB went on handing them out: zeroed by the dormant
    # flush, or handed out twice (`bench/log/linux/2026-09-27-dormant-revive-race/`).
    #
    # Slots are not released when a thread exits, so a program that has had
    # more than `MAX_TLABS` allocating threads shares slots by key, as every
    # thread used to. The slot lock serializes the sharers and the flush now
    # empties the slot, so a shared slot is slower, not unsound.
    protected def current_tlab_under_lock(key : UInt64 = current_thread_key) : Tlab*
      ensure_tlabs_under_lock
      i = 0
      while i < MAX_TLABS
        if @tlabs[i].live && @tlabs[i].owner == key
          return @tlabs.to_unsafe + i
        end
        i += 1
      end
      i = 0
      while i < MAX_TLABS
        unless @tlabs[i].live
          tlab = @tlabs.to_unsafe + i
          tlab.value.owner = key
          tlab.value.live = true
          return tlab
        end
        i += 1
      end
      @tlab_slots_shared &+= 1
      @tlabs.to_unsafe + (key % MAX_TLABS).to_i32
    end

    # Adaptive batch size: targets ~8 KiB per refill (per-class, clamped to [1, 256]).
    # Skips !free? nodes (USED-on-freelist after mid-alloc STW). If skipping
    # empties the list, force a fresh size-class chunk once.

    # Like tlab_refill but if the freelist is empty after map, drop the
    # alloc lock and STW-collect once (map_chunk must not collect under TLAB
    # lock — that deadlocks), then retry.
    # No live-TLAB steal: nulling another thread's freelist head races with
    # lock-free tlab_alloc_small (TOCTOU dual-alloc). Idle freelists return via
    # flush_all_tlabs under STW. (@tlab_steals stays 0; reserved for a future
    # CAS steal if imbalance warrants it.)
    protected def tlab_refill(class_index : Int32, payload : UInt32, nursery : Bool) : Void*
      head = tlab_refill_once(class_index, payload, nursery)
      return head unless head.null?
      return Pointer(Void).null unless @enabled
      # Give up only when *this* thread is the collector: collecting from here
      # would re-enter its own cycle. `@collecting` alone is heap-wide, and it
      # stays true through the post-STW phase while every other thread runs —
      # so a refill that missed once there (a dormant revive refused mid-walk,
      # say) was reported as `OutOfMemoryError` with memory to spare. Any other
      # thread collects instead: it queues for the collection section behind
      # the cycle in flight, and returns once a full collection that began
      # after its call has finished, its own or a peer's. Surfaced by the idle
      # collector (`GCRY_IDLE_RELEASE_MS`), whose background cycles overlap
      # allocation: `stw_mt_property_test --tlab` failed 3 of 3 with it on at
      # 5 ms.
      if @collecting
        Atomic::Ops.fence(LLVM::AtomicOrdering::Acquire, false)
        return Pointer(Void).null if @collector_pthread == Gcry::Platform.current_thread_id
      end
      collect(scan_stack: true)
      tlab_refill_once(class_index, payload, nursery)
    end

    # Refill keeps @alloc_lock (not per-class freelist locks): Parallel TLAB
    # hit path does find_block→@index_lock; concurrent per-class refill×mmap
    # amplified index contention and crushed Kemal TLAB-on thr (~26k→~15k).
    # TLAB-off alloc/free still use with_freelist_lock.
    #
    # A collection can stop this thread anywhere in here, `@alloc_lock` or not:
    # the stopped world takes no allocator lock. Everything the refill read
    # before that is stale after it. The flush put every TLAB back on the class
    # lists, and the sweep may have rebuilt those lists and made chunks dormant
    # — including the chunk of a batch this thread had already taken off the
    # list and not yet installed, which no list or TLAB held, so to the sweep
    # its blocks were simply free. Installing it then handed out blocks the
    # post-STW flush zeroes as soon as this thread lets go of the lock it is
    # waiting on (`root N cookie broken`, headered TLAB with
    # `GCRY_PARALLEL_DORMANT=1`; `bench/log/linux/2026-09-27-dormant-revive-race/`).
    #
    # So the refill runs against the TLAB epoch, which every collection bumps
    # inside the stop. If it moved, the batch goes back out of the TLAB, the
    # class list this refill may have overwritten with a stale chain is dropped
    # and marked for the next sweep to rebuild, and the refill starts over.
    # All of that happens before the lock is released, so the post-STW flush
    # cannot run in between; a collection after the check finds the batch in
    # the TLAB and flushes it like any other.
    private def tlab_refill_once(class_index : Int32, payload : UInt32, nursery : Bool) : Void*
      head = Pointer(Void).null
      batch = (8192_u64 / payload.to_u64).to_i32.clamp(1, 256)
      @alloc_lock.sync do
        4.times do
          # See `tlab_alloc_small`: nothing refills a TLAB in a stopped world.
          break if @world_stopped
          epoch = @tlab_epoch.get
          head = tlab_refill_locked(class_index, payload, nursery, batch)
          break if @tlab_epoch.get == epoch
          discard_refill_across_collection(class_index, nursery)
          head = Pointer(Void).null
        end
      end
      head
    end

    # Caller holds `@alloc_lock` and saw the TLAB epoch move under it.
    private def discard_refill_across_collection(class_index : Int32, nursery : Bool) : Nil
      @tlab_refill_discards &+= 1
      tlab = current_tlab_under_lock
      unless tlab.null?
        slot = tlab_slot_index(tlab)
        lock_tlab_slot(slot)
        begin
          if nursery
            tlab.value.nursery_freelists[class_index] = Pointer(Void).null
          else
            tlab.value.freelists[class_index] = Pointer(Void).null
          end
        ensure
          unlock_tlab_slot(slot)
        end
      end
      bit = 1_u64 << class_index
      if nursery
        @nursery_freelists[class_index] = Pointer(Void).null
        @freelist_rebuild_request_nursery |= bit
      else
        @freelists[class_index] = Pointer(Void).null
        @prefer_freelists[class_index] = Pointer(Void).null
        @freelist_rebuild_request |= bit
      end
    end

    private def tlab_refill_locked(class_index : Int32, payload : UInt32, nursery : Bool, batch : Int32) : Void*
      head = Pointer(Void).null
      2.times do |attempt|
        if nursery
          if @nursery_freelists[class_index].null?
            refill_size_class(class_index, payload, nursery: true, alloc_held: true)
          end
        else
          if @freelists[class_index].null?
            refill_size_class(class_index, payload, nursery: false, alloc_held: true)
          end
        end

        src = nursery ? @nursery_freelists[class_index] : @freelists[class_index]
        skip_budget = 4096
        while !src.null? && !BlockHeader.free?(BlockHeader.from_user(src)) && skip_budget > 0
          src = BlockHeader.from_user(src).value.next_free
          if nursery
            @nursery_freelists[class_index] = src
          else
            @freelists[class_index] = src
          end
          skip_budget -= 1
        end
        if skip_budget == 0
          if nursery
            @nursery_freelists[class_index] = Pointer(Void).null
          else
            @freelists[class_index] = Pointer(Void).null
          end
          src = Pointer(Void).null
        end

        if src.null? && attempt == 0
          refill_size_class(class_index, payload, nursery: nursery, alloc_held: true)
          next
        end

        # Global still empty: do not steal from other live TLABs (TOCTOU).
        break if src.null?

        if @blacklist_enabled
          taken = take_non_blacklisted(src, class_index, nursery)
          unless taken.null?
            th = BlockHeader.from_user(taken)
            tv = th.value
            tv.next_free = nursery ? @nursery_freelists[class_index] : @freelists[class_index]
            th.value = tv
            if nursery
              @nursery_freelists[class_index] = taken
            else
              @freelists[class_index] = taken
            end
            src = taken
          end
        end

        break if src.null? || !BlockHeader.free?(BlockHeader.from_user(src))

        head = src
        tail = src
        count = 1
        while count < batch
          h = BlockHeader.from_user(tail)
          nxt = h.value.next_free
          break if nxt.null?
          break unless BlockHeader.free?(BlockHeader.from_user(nxt))
          tail = nxt
          count += 1
        end
        last = BlockHeader.from_user(tail)
        rest = last.value.next_free
        while !rest.null? && !BlockHeader.free?(BlockHeader.from_user(rest))
          rest = BlockHeader.from_user(rest).value.next_free
        end
        lv = last.value
        lv.next_free = Pointer(Void).null
        last.value = lv
        if nursery
          @nursery_freelists[class_index] = rest
        else
          @freelists[class_index] = rest
        end

        tlab = current_tlab_under_lock
        if tlab.null?
          lv2 = last.value
          lv2.next_free = nursery ? @nursery_freelists[class_index] : @freelists[class_index]
          last.value = lv2
          if nursery
            @nursery_freelists[class_index] = head
          else
            @freelists[class_index] = head
          end
          head = Pointer(Void).null
          break
        end

        slot = tlab_slot_index(tlab)
        lock_tlab_slot(slot)
        begin
          if nursery
            tlab.value.nursery_freelists[class_index] = head
          else
            tlab.value.freelists[class_index] = head
          end
        ensure
          unlock_tlab_slot(slot)
        end
        @tlab_refills += 1
        break
      end
      head
    end

    protected def tlab_alloc_small(payload : UInt32, flags : UInt32, class_index : Int32, nursery : Bool, rounded : UInt64) : Void*
      # Per-slot lock closes Parallel dual-alloc on freelist head (TOCTOU on the
      # lock-free load/store, or two OS threads briefly sharing a slot). Epoch
      # protocol still applies across STW flush.
      32.times do
        # A thread still running while the world is stopped — one the stop
        # missed in its birth window, or the collector itself — takes the class
        # list instead of its TLAB. The flush already emptied the TLABs; a refill
        # now would sit in one while the sweep relinked the same blocks onto the
        # class list, and the next flush would splice the list into a cycle.
        # Measured: every node of such a cycle was installed in a TLAB at the
        # same epoch as the rebuild that relinked it, both inside the stop.
        return tlab_bypass(payload, flags, class_index, nursery, rounded) if @world_stopped
        epoch = @tlab_epoch.get
        tlab = current_tlab
        slot = tlab_slot_index(tlab)
        user = Pointer(Void).null

        lock_tlab_slot(slot)
        begin
          user = if nursery
                   tlab.value.nursery_freelists[class_index]
                 else
                   tlab.value.freelists[class_index]
                 end

          if !user.null? && !find_block(user)
            if nursery
              tlab.value.nursery_freelists[class_index] = Pointer(Void).null
            else
              tlab.value.freelists[class_index] = Pointer(Void).null
            end
            user = Pointer(Void).null
          end

          if !user.null? && !BlockHeader.free?(BlockHeader.from_user(user))
            if nursery
              tlab.value.nursery_freelists[class_index] = Pointer(Void).null
            else
              tlab.value.freelists[class_index] = Pointer(Void).null
            end
            user = Pointer(Void).null
          end

          if !user.null?
            header = BlockHeader.from_user(user)
            if BlockHeader.free?(header)
              next_free = header.value.next_free
              if nursery
                tlab.value.nursery_freelists[class_index] = next_free
              else
                tlab.value.freelists[class_index] = next_free
              end
              BlockHeader.set_used(header, payload, flags)
              heap_set_mark_allocating(header) if @incremental_marking || @collecting
              @tlab_hits.add(1_u64)
            else
              user = Pointer(Void).null
            end
          end
        ensure
          unlock_tlab_slot(slot)
        end

        if user.null?
          filled = tlab_refill(class_index, payload, nursery)
          if filled.null?
            return tlab_bypass(payload, flags, class_index, nursery, rounded) if @world_stopped
            oom!("failed to refill TLAB size class", payload.to_u64)
          end
          next if @tlab_epoch.get != epoch
          next # claim the freshly installed batch under the slot lock
        end

        # Atomic counters — no @alloc_lock on the TLAB hit path (Parallel thr).
        free_bytes_sub(payload.to_u64)
        @nursery_alloc_bytes.add(payload.to_u64) if nursery
        note_alloc_bytes(rounded)
        return user
      end
      oom!("failed to claim TLAB node size class", payload.to_u64)
    end

    # The class-list allocation `allocate` uses when TLAB is off.
    private def tlab_bypass(payload : UInt32, flags : UInt32, class_index : Int32, nursery : Bool, rounded : UInt64) : Void*
      user, _ = if nursery
                  alloc_nursery(payload, flags, class_index, rounded)
                else
                  alloc_old_small(payload, flags, class_index, rounded)
                end
      user
    end

    # Return a small object to the current thread's TLAB.
    protected def tlab_free_small(pointer : Void*, class_index : Int32, payload : UInt32, nursery : Bool) : Nil
      tlab = current_tlab
      slot = tlab_slot_index(tlab)
      lock_tlab_slot(slot)
      begin
        header = BlockHeader.from_user(pointer)
        if nursery
          header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, tlab.value.nursery_freelists[class_index])
          tlab.value.nursery_freelists[class_index] = pointer
        else
          header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, tlab.value.freelists[class_index])
          tlab.value.freelists[class_index] = pointer
        end
      ensure
        unlock_tlab_slot(slot)
      end
      @free_bytes.add(payload.to_u64)
    end

    # The collector, just before it stops the world: take every slot lock, so
    # no mutator is stopped inside a TLAB critical section.
    #
    # Until 2026-09-27 a thread could be. `tlab_alloc_small` reads its head
    # block and that block's `next_free` under the slot lock, then writes the
    # TLAB head and marks the block USED. Stopped in between, it came back to a
    # TLAB the flush had emptied and a heap the sweep had changed: the flush had
    # put its chain on the class list, and the sweep could make the chunk of
    # that chain dormant and rebuild the list without it. The thread then
    # returned the block and stored the stale `next_free` as its TLAB head —
    # so it and the TLAB hits after it came out of a DORMANT chunk the
    # post-STW flush zeroes. Measured with `GCRY_PARALLEL_DORMANT=1` on
    # `stw_mt_property_test_hdr --tlab`: every `root N cookie broken` run also
    # logged a TLAB hit from a DORMANT chunk
    # (`bench/log/linux/2026-09-27-dormant-revive-race/`).
    #
    # Taken last, after `@roots_lock` and the finalizer lock, because nothing
    # inside a slot's critical section takes those, while code under them can
    # allocate. A thread spinning here for its slot has not entered the section
    # and is stopped outside it. Released as soon as the world is stopped: no
    # mutator can reach a slot then, and `flush_all_tlabs` does not lock them.
    protected def lock_tlab_slots_for_stop : Bool
      return false unless @tlabs_booted && @tlab_enabled
      i = 0
      while i < MAX_TLABS
        (@tlab_slot_locks.to_unsafe + i).value.lock
        i += 1
      end
      true
    end

    protected def unlock_tlab_slots_after_stop : Nil
      i = MAX_TLABS - 1
      while i >= 0
        (@tlab_slot_locks.to_unsafe + i).value.unlock
        i -= 1
      end
    end

    # Classes, as `1 << class`, whose freelist a thread the stop froze may be
    # in the middle of: its class lock (`freelist_lock_ptr`) was held when the
    # stop tried it (`note_frozen_freelists`), or one of its USED stash chains
    # sits in an allocation-batch slot whose lock was held
    # (`flush_all_alloc_batches`). Old and nursery lists apart, as their
    # locks are. Valid from `note_frozen_freelists` to
    # `clear_frozen_freelists`, both inside the stop.
    @stop_frozen_classes = 0_u64
    @stop_frozen_nursery_classes = 0_u64
    # Header (freelist) chunks an in-stop sweep left unswept because their
    # class was frozen (`Heap#sweep`).
    getter stop_sweep_freelist_declined : UInt64 = 0_u64
    # Research only: false writes every class's freelist in the stop whoever
    # holds its lock, the code before 2026-10-22 — the control arm of
    # `process_spec/regression/84_stop_sweep_frozen_freelist_holder_spec.cr`.
    property stop_freelist_try_lock : Bool = true
    # Research only: called by `refill_size_class` on the allocating thread
    # with the chunk it has just laid out, every block FREE and on no list
    # yet, before it stores the list head — under the class lock (TLAB off),
    # so it must not allocate. Regression 84 parks a thread there across a
    # stop.
    property refill_publish_hook : Proc(ChunkHeader*, Nil)? = nil
    # Research only, for regression 84's batch arms; both run on the
    # allocating thread and must not allocate. `alloc_batch_pop_hook`: in
    # `alloc_old_small_batched` under the batch slot lock, with the stash
    # head read and checked and its `next_free` not yet stored.
    # `alloc_batch_publish_hook`: as `refill_alloc_batch` publishes a stash,
    # before it takes the slot lock.
    property alloc_batch_pop_hook : Proc(Void*, Nil)? = nil
    property alloc_batch_publish_hook : Proc(Void*, Nil)? = nil
    # Research only: false publishes a batch's stash after the class lock is
    # released, the order before 2026-10-22 (`refill_alloc_batch`).
    property alloc_batch_publish_locked : Bool = true

    # In the stop, before anything writes a freelist: which class locks are
    # held? With every mutator frozen, a held one is held by a thread the stop
    # froze inside its section — a pop (`alloc_old_small_locked`,
    # `alloc_nursery_locked`), a free's push (`push_size_class_free`), a
    # refill that has laid a chunk out as FREE blocks and not yet stored the
    # head (`refill_size_class`), a batch claim (`refill_alloc_batch`) — with
    # a list head, a `next_free` or a whole chunk in its registers that it
    # stores when it resumes. Those classes are frozen for this stop: their
    # lists are not written and their freelist chunks not swept (`Heap#sweep`,
    # `flush_all_alloc_batches`, `flush_all_tlabs`, `scrub_freelists`), as
    # the in-stop sweep already leaves `@chunks` alone under a frozen
    # list-lock holder. Waiting is not an option: the holder is frozen (the
    # 0.21.1 `@chunk_list_lock` hang).
    # Before this the stop wrote them regardless, and the resumed thread
    # stored a stale head over the sweep's pushes and rebuilds, popped a block
    # the rebuild had linked again, or installed a freelist into a chunk the
    # sweep had found all FREE and made dormant or queued for unmap.
    # `bench/log/linux/2026-10-22-in-stop-sweep-audit/FINDINGS.md`.
    #
    # A lock that is free is given straight back. A frozen holder cannot let
    # go before the world restarts, so the answer stands for the whole stop,
    # and the only threads that could take a free one now are the ones that
    # could before — the collector itself, from a hook that allocates against
    # the rule, which holding the lock would hang.
    #
    # Only on a heap with freelist chunks: the header allocator, or a nursery.
    # A bitmap chunk keeps no freelist; its cursor protocol is the settle's.
    protected def note_frozen_freelists : Nil
      @stop_frozen_classes = 0_u64
      @stop_frozen_nursery_classes = 0_u64
      return unless @stop_freelist_try_lock
      return if @bitmap_alloc && !@nursery_enabled
      i = 0
      while i < SIZE_CLASS_COUNT
        bit = 1_u64 << i
        lock = freelist_lock_ptr(i, false)
        if try_lock_spinlock(lock)
          lock.value.unlock
        else
          @stop_frozen_classes |= bit
        end
        lock = freelist_lock_ptr(i, true)
        if try_lock_spinlock(lock)
          lock.value.unlock
        else
          @stop_frozen_nursery_classes |= bit
        end
        i += 1
      end
    end

    protected def clear_frozen_freelists : Nil
      @stop_frozen_classes = 0_u64
      @stop_frozen_nursery_classes = 0_u64
    end

    # Research only: false leaves the sweep after the world even when the
    # stop found a frozen freelist class — the code before 2026-10-22, the
    # control arm of regression 84's lazy windows.
    property stop_frozen_sweep_in_stop : Bool = true
    # Collections whose sweep ran in the stop rather than after it because a
    # thread the stop froze was inside a freelist class.
    getter stop_frozen_sweeps_in_stop : UInt64 = 0_u64

    # Should this collection sweep inside the stop, though it would sweep
    # after the world? Yes when the stop found a class a frozen thread is
    # inside (`note_frozen_freelists`, `flush_all_alloc_batches`).
    #
    # Only the in-stop sweep honours those classes: it leaves their chunks
    # unswept. The after-world sweep takes each chunk's class lock instead,
    # and that covers a thread *inside* the lock but not what it leaves
    # behind once it lets go. Two such things are an allocation batch's
    # stash, USED blocks linked only through their headers, which no scan
    # reads and no mark covers: one the flush kept because its slot lock was
    # held (the owner frozen in a pop), and one a refill frozen under the
    # class lock claimed before the stop and publishes after it. With the
    # world running the sweep found those blocks unmarked and put them on
    # the class list while the stash still linked them, and the next pop
    # from either handed the same block out twice. Such a stop is rare —
    # a thread frozen in a few instructions under a class lock — and costs
    # that one collection the pause of its sweep.
    protected def sweep_frozen_classes_in_stop? : Bool
      return false unless @stop_frozen_sweep_in_stop
      # Only a stash needs it. Without allocation batches the after-world
      # sweep waits on the resumed holder's class lock and finds its work
      # done; and on a bitmap heap with a nursery, bits a frozen bitmap
      # refill or free set are for chunks the frozen skip ignores anyway.
      return false unless @alloc_batch > 0 && @alloc_batches_booted
      return false if @stop_frozen_classes == 0_u64
      @stop_frozen_sweeps_in_stop &+= 1
      true
    end

    @[AlwaysInline]
    private def stop_frozen_class?(class_index : Int32, nursery : Bool) : Bool
      mask = nursery ? @stop_frozen_nursery_classes : @stop_frozen_classes
      (mask & (1_u64 << class_index)) != 0
    end

    # Research only: false splices and scrubs every class's list in the stop
    # whoever holds its lock, the code before 2026-10-22 — the control arm of
    # `process_spec/regression/85_frozen_class_gaps_spec.cr`'s *tlab-flush*
    # window.
    property stop_tlab_flush_frozen_skip : Bool = true
    # TLAB chains a flush left in their TLAB because their class was frozen.
    getter stop_tlab_flush_frozen_kept : UInt64 = 0_u64

    # Flush TLAB freelists back to global (call under STW / before sweep / destroy).
    # Bump epoch first so resumed mid-alloc abandons stale TLAB heads already
    # published here. Walks each chain and splices only FREE nodes.
    #
    # A frozen class's chains stay where they are (`note_frozen_freelists`).
    # With TLAB on, a class lock is held only by a thread on the class-list
    # path: an allocation that read `@world_stopped` true (`tlab_bypass`; a
    # thread the previous stop missed in its birth window), or an allocation
    # or free that read `@tlab_enabled` false before a runtime switch. Frozen
    # there, it has the list head in hand and stores it when it resumes: the
    # chains spliced in front of it here went off every list and out of
    # every TLAB, FREE blocks nothing would hand out until their chunk
    # emptied (`scrub_freelists` rewriting the list under it did the same to
    # the rest of the list). Kept in the TLAB they stay its owner's to hand
    # out: their chunks are not swept in this stop, so nothing else claims
    # them, and the next stop that finds the class free flushes them.
    protected def flush_all_tlabs : Nil
      return unless @tlabs_booted && @tlab_enabled
      @tlab_epoch.add(1)
      skip_frozen = @stop_tlab_flush_frozen_skip
      # No per-slot locks: callers run under STW, and the collector took every
      # slot lock before stopping it (`lock_tlab_slots_for_stop`), so no mutator
      # is stopped inside a slot's critical section.
      MAX_TLABS.times do |i|
        next unless @tlabs[i].live
        tlab = @tlabs.to_unsafe + i
        SIZE_CLASS_COUNT.times do |c|
          head = tlab.value.freelists[c]
          unless head.null?
            if skip_frozen && stop_frozen_class?(c, false)
              @stop_tlab_flush_frozen_kept &+= 1
            else
              @freelists[c] = splice_free_nodes(head, @freelists[c])
              tlab.value.freelists[c] = Pointer(Void).null
            end
          end

          head = tlab.value.nursery_freelists[c]
          unless head.null?
            if skip_frozen && stop_frozen_class?(c, true)
              @stop_tlab_flush_frozen_kept &+= 1
            else
              @nursery_freelists[c] = splice_free_nodes(head, @nursery_freelists[c])
              tlab.value.nursery_freelists[c] = Pointer(Void).null
            end
          end
        end
      end
    end

    # Prepend every FREE node in `head`'s chain onto `global_head`. USED nodes
    # are skipped (left claimed by a suspended mid-alloc mutator).
    private def splice_free_nodes(head : Void*, global_head : Void*) : Void*
      user = head
      while user
        header = BlockHeader.from_user(user)
        nxt = header.value.next_free
        if BlockHeader.free?(header)
          payload = header.value.size
          header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, global_head)
          global_head = user
        end
        user = nxt
      end
      global_head
    end

    # Drop USED nodes that leaked onto global freelists (TLAB mid-alloc + STW).
    # Call under STW immediately after flush_all_tlabs. No-op when TLAB is off —
    # scrubbing a fuzz-corrupted freelist would SEGV on !free? / bad next_free.
    # A frozen class's list is left alone, as `flush_all_tlabs` leaves it.
    protected def scrub_freelists : Nil
      return unless @tlab_enabled
      skip_frozen = @stop_tlab_flush_frozen_skip
      SIZE_CLASS_COUNT.times do |c|
        scrub_one_freelist(c, false) unless skip_frozen && stop_frozen_class?(c, false)
        scrub_one_freelist(c, true) unless skip_frozen && stop_frozen_class?(c, true)
      end
    end

    private def scrub_one_freelist(class_index : Int32, nursery : Bool) : Nil
      head = nursery ? @nursery_freelists[class_index] : @freelists[class_index]
      return if head.null?

      user = head
      found_used = false
      while user
        break unless find_block(user)
        header = BlockHeader.from_user(user)
        unless BlockHeader.free?(header)
          found_used = true
          break
        end
        nxt = header.value.next_free
        break if !nxt.null? && !find_block(nxt)
        user = nxt
      end
      return unless found_used

      new_head = Pointer(Void).null
      user = head
      while user
        break unless find_block(user)
        header = BlockHeader.from_user(user)
        nxt = header.value.next_free
        if BlockHeader.free?(header)
          payload = header.value.size
          header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, new_head)
          new_head = user
        end
        break if !nxt.null? && !find_block(nxt)
        user = nxt
      end

      if nursery
        @nursery_freelists[class_index] = new_head
        @nursery_freelist_clean[class_index] = false
      else
        @freelists[class_index] = new_head
        @freelist_clean[class_index] = false
      end
    end

    # --- TLAB-off alloc batch (USED stash) ---------------------------------
    # Claim up to N freelist nodes under the per-class freelist lock, mark them
    # USED (+mark bit while collecting), stash extras on a per-thread chain.
    # Hits skip the freelist lock (unlike TLAB FREE caches — safe with lazy
    # sweep). STW flush returns unused stash to the global freelist.

    protected def ensure_alloc_batches : Nil
      return if @alloc_batches_booted
      @alloc_lock.sync { ensure_alloc_batches_under_lock }
    end

    private def ensure_alloc_batches_under_lock : Nil
      return if @alloc_batches_booted
      MAX_TLABS.times do |i|
        @alloc_batches[i] = AllocBatch.new
        @alloc_batch_slot_locks[i] = Crystal::SpinLock.new
      end
      @alloc_batches_booted = true
    end

    private def alloc_batch_slot_index(ab : AllocBatch*) : Int32
      ((ab.address - @alloc_batches.to_unsafe.address) // sizeof(AllocBatch)).to_i32
    end

    private def lock_alloc_batch_slot(slot : Int32) : Nil
      (@alloc_batch_slot_locks.to_unsafe + slot).value.lock
    end

    private def unlock_alloc_batch_slot(slot : Int32) : Nil
      (@alloc_batch_slot_locks.to_unsafe + slot).value.unlock
    end

    protected def current_alloc_batch : AllocBatch*
      ensure_alloc_batches
      key = current_thread_key
      i = 0
      while i < MAX_TLABS
        if @alloc_batches[i].live && @alloc_batches[i].owner == key
          return @alloc_batches.to_unsafe + i
        end
        i += 1
      end
      @alloc_lock.sync { current_alloc_batch_under_lock(key) }
    end

    private def current_alloc_batch_under_lock(key : UInt64 = current_thread_key) : AllocBatch*
      ensure_alloc_batches_under_lock
      i = 0
      while i < MAX_TLABS
        if @alloc_batches[i].live && @alloc_batches[i].owner == key
          return @alloc_batches.to_unsafe + i
        end
        i += 1
      end
      i = 0
      while i < MAX_TLABS
        unless @alloc_batches[i].live
          # Through a pointer, as in `current_tlab_under_lock`: indexing
          # returns a copy.
          ab = @alloc_batches.to_unsafe + i
          ab.value.owner = key
          ab.value.live = true
          return ab
        end
        i += 1
      end
      @alloc_batch_slots_shared &+= 1
      @alloc_batches.to_unsafe + (key % MAX_TLABS).to_i32
    end

    # Pop one USED node from the thread stash, or refill under freelist lock.
    protected def alloc_old_small_batched(payload : UInt32, flags : UInt32, index : Int32, rounded : UInt64) : Void*
      batch = @alloc_batch
      batch = 1 if batch < 1
      batch = 64 if batch > 64

      ab = current_alloc_batch
      slot = alloc_batch_slot_index(ab)
      user = Pointer(Void).null

      lock_alloc_batch_slot(slot)
      begin
        user = ab.value.freelists[index]
        if !user.null?
          header = BlockHeader.from_user(user)
          if BlockHeader.free?(header)
            # Corrupt / flushed under us — drop chain.
            ab.value.freelists[index] = Pointer(Void).null
            user = Pointer(Void).null
          else
            if hook = @alloc_batch_pop_hook
              hook.call(user)
            end
            ab.value.freelists[index] = header.value.next_free
            BlockHeader.set_used(header, payload, flags)
            heap_set_mark_allocating(header) if @incremental_marking || @collecting
            @alloc_batch_hits.add(1_u64)
          end
        end
      ensure
        unlock_alloc_batch_slot(slot)
      end

      if user.null?
        user = refill_alloc_batch(index, payload, flags, batch)
        oom!("failed to refill alloc-batch size class", payload.to_u64) if user.null?
      end

      note_alloc_bytes(rounded)
      user
    end

    # Under freelist lock: claim up to `batch` FREE nodes as USED; return the
    # first and stash the rest on the current thread's AllocBatch slot.
    # Lock order: freelist → alloc-batch slot (never reverse).
    private def refill_alloc_batch(class_index : Int32, payload : UInt32, flags : UInt32, batch : Int32) : Void*
      first = Pointer(Void).null
      stash_head = Pointer(Void).null
      claimed = 0

      with_freelist_lock(class_index, false) do
        2.times do |attempt|
          if @freelists[class_index].null?
            refill_size_class(class_index, payload, nursery: false)
          end

          src = @freelists[class_index]
          skip_budget = 4096
          while !src.null? && !BlockHeader.free?(BlockHeader.from_user(src)) && skip_budget > 0
            src = BlockHeader.from_user(src).value.next_free
            @freelists[class_index] = src
            skip_budget -= 1
          end
          if skip_budget == 0
            @freelists[class_index] = Pointer(Void).null
            src = Pointer(Void).null
          end

          if src.null? && attempt == 0
            refill_size_class(class_index, payload, nursery: false)
            next
          end
          break if src.null?

          if @blacklist_enabled
            taken = take_non_blacklisted(src, class_index, false)
            unless taken.null?
              th = BlockHeader.from_user(taken)
              tv = th.value
              tv.next_free = @freelists[class_index]
              th.value = tv
              @freelists[class_index] = taken
              src = taken
            end
          end
          break if src.null? || !BlockHeader.free?(BlockHeader.from_user(src))

          claimed = 0
          stash_head = Pointer(Void).null
          first = Pointer(Void).null
          while claimed < batch && !src.null?
            break unless BlockHeader.free?(BlockHeader.from_user(src))
            header = BlockHeader.from_user(src)
            nxt = header.value.next_free
            @freelists[class_index] = nxt
            BlockHeader.set_used(header, payload, flags)
            heap_set_mark_allocating(header) if @incremental_marking || @collecting
            if first.null?
              first = src
              # next_free unused for the returned object
              hv = header.value
              hv.next_free = Pointer(Void).null
              header.value = hv
            else
              hv = header.value
              hv.next_free = stash_head
              header.value = hv
              stash_head = src
            end
            claimed += 1
            src = nxt
            # Skip USED-on-freelist nodes
            while !src.null? && !BlockHeader.free?(BlockHeader.from_user(src))
              src = BlockHeader.from_user(src).value.next_free
              @freelists[class_index] = src
            end
          end
          break
        end

        # Published before the class lock goes, the order the lock order
        # (freelist → alloc-batch slot) already allows. Published after it,
        # until 2026-10-22, a stop could freeze this thread between the two
        # holding neither lock, with the stash — USED blocks linked only
        # through headers no scan reads, and none of them yet in any slot —
        # in its registers: the in-stop sweep reclaimed all but the head onto
        # the class list, and the publish then made the same blocks this
        # thread's stash. Under the lock, a frozen thread is one
        # `note_frozen_freelists` sees.
        publish_alloc_batch_stash(class_index, stash_head) if @alloc_batch_publish_locked
      end

      publish_alloc_batch_stash(class_index, stash_head) unless @alloc_batch_publish_locked

      return Pointer(Void).null if first.null?

      free_bytes_sub(payload.to_u64 * claimed.to_u64)
      @alloc_batch_refills += 1

      first
    end

    # Put *stash_head*'s chain in front of this thread's stash of the class.
    private def publish_alloc_batch_stash(class_index : Int32, stash_head : Void*) : Nil
      return if stash_head.null?
      if hook = @alloc_batch_publish_hook
        hook.call(stash_head)
      end
      ab = current_alloc_batch
      slot = alloc_batch_slot_index(ab)
      lock_alloc_batch_slot(slot)
      begin
        # Prepend new stash in front of any residual (should be empty).
        tail = stash_head
        loop do
          h = BlockHeader.from_user(tail)
          nxt = h.value.next_free
          break if nxt.null?
          tail = nxt
        end
        hv = BlockHeader.from_user(tail).value
        hv.next_free = ab.value.freelists[class_index]
        BlockHeader.from_user(tail).value = hv
        ab.value.freelists[class_index] = stash_head
      ensure
        unlock_alloc_batch_slot(slot)
      end
    end

    # Return unused USED-stash nodes to the global freelist (STW / destroy).
    # Bump epoch so a resumed mid-claim abandons stale stash heads.
    #
    # A slot's lock is tried, not waited on, and a slot whose lock is held is
    # left as it is. Its owner was frozen by the stop inside
    # `alloc_old_small_batched` or the publish of `refill_alloc_batch`, with a
    # stash head and its `next_free` in hand: flushed, its stash went onto
    # the class list as FREE nodes, and the owner resumed to store the stale
    # `next_free` as its stash and hand out a block that list also held —
    # the epoch above was never read. Its stash nodes are USED and reachable
    # only through their headers, which no scan reads, so their classes are
    # frozen for the sweep as well (`note_frozen_freelists`), or it
    # would reclaim them under the stash. A class frozen already keeps every
    # slot's stash: its list is not written in this stop.
    protected def flush_all_alloc_batches : Nil
      return if @alloc_batch <= 0
      return unless @alloc_batches_booted
      @alloc_batch_epoch.add(1)
      held = 0_u64
      MAX_TLABS.times do |i|
        next unless @alloc_batches[i].live
        next if !@stop_freelist_try_lock || try_lock_spinlock(@alloc_batch_slot_locks.to_unsafe + i)
        held |= 1_u64 << i
        ab = @alloc_batches.to_unsafe + i
        SIZE_CLASS_COUNT.times do |c|
          @stop_frozen_classes |= 1_u64 << c unless ab.value.freelists[c].null?
        end
      end
      MAX_TLABS.times do |i|
        next unless @alloc_batches[i].live
        next if (held & (1_u64 << i)) != 0
        ab = @alloc_batches.to_unsafe + i
        SIZE_CLASS_COUNT.times do |c|
          head = ab.value.freelists[c]
          next if head.null?
          next if stop_frozen_class?(c, false)
          ab.value.freelists[c] = Pointer(Void).null
          payload = SizeClasses.payload(c)
          user = head
          n = 0_u64
          while user
            header = BlockHeader.from_user(user)
            nxt = header.value.next_free
            unless BlockHeader.free?(header)
              header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, @freelists[c])
              @freelists[c] = user
              n &+= 1
            end
            user = nxt
          end
          free_bytes_add(payload.to_u64 * n) if n > 0
          @freelist_clean[c] = false if n > 0
        end
        unlock_alloc_batch_slot(i) if @stop_freelist_try_lock
      end
    end
  end
end
