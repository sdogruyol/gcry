# Thread-local allocation buffers (TLAB): each mutator OS thread takes a private
# freelist head per size-class so parallel ExecutionContexts can allocate without
# racing on the global freelist. Chunk refill takes the per-size-class freelist
# SpinLock (not the global @alloc_lock).
#
# Fields (@alloc_lock, @freelist_locks, @tlab_enabled, …) are in heap.cr.

require "c/pthread"

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

    def tlab_enabled=(value : Bool) : Bool
      @tlab_enabled = value
    end

    def tlab_refills : UInt64
      @tlab_refills
    end

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
    # TLAB slot and allocation-batch slot (their fast paths hand out blocks
    # that are still FREE-headed and off the global freelist), then the class
    # freelist. Slot locks first — the TLAB path holds its slot lock when it
    # refills under the freelist lock, so that is the order it establishes.
    #
    # This is what makes a post-STW page release sound: a run of free pages is
    # computed from block headers and then handed to `madvise` with the world
    # running, and any block in it handed out in between would be zeroed
    # after the mutator wrote it (`make page-release-corruption`, 4 of 28
    # before this). Under these locks nothing can be handed out until the
    # syscall has returned. Only the opt-in release walks pay for it.
    protected def with_small_allocation_excluded(index : Int32, nursery : Bool, &)
      i = 0
      while i < MAX_TLABS
        (@tlab_slot_locks.to_unsafe + i).value.lock
        (@alloc_batch_slot_locks.to_unsafe + i).value.lock
        i += 1
      end
      begin
        with_freelist_lock(index, nursery) { yield }
      ensure
        i = MAX_TLABS - 1
        while i >= 0
          (@alloc_batch_slot_locks.to_unsafe + i).value.unlock
          (@tlab_slot_locks.to_unsafe + i).value.unlock
          i -= 1
        end
      end
    end

    private def current_thread_key : UInt64
      {% if flag?(:win32) || flag?(:wasm32) %}
        1_u64
      {% elsif flag?(:darwin) || flag?(:musl) %}
        # PthreadT is Void* — no integer conversion (same as darwin).
        LibC.pthread_self.as(Void*).address
      {% else %}
        LibC.pthread_self.to_u64!
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
      tlab = @alloc_lock.sync { current_tlab_under_lock(key) }
      if tlab.null?
        raise OutOfMemoryError.new("TLAB table full (#{MAX_TLABS} threads)")
      end
      tlab
    end

    # Caller must hold @alloc_lock (or be single-threaded).
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
          @tlabs[i].owner = key
          @tlabs[i].live = true
          return @tlabs.to_unsafe + i
        end
        i += 1
      end
      Pointer(Tlab).null
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
      return Pointer(Void).null if @collecting || !@enabled
      collect(scan_stack: true)
      tlab_refill_once(class_index, payload, nursery)
    end

    # Refill keeps @alloc_lock (not per-class freelist locks): Parallel TLAB
    # hit path does find_block→@index_lock; concurrent per-class refill×mmap
    # amplified index contention and crushed Kemal TLAB-on thr (~26k→~15k).
    # TLAB-off alloc/free still use with_freelist_lock.
    private def tlab_refill_once(class_index : Int32, payload : UInt32, nursery : Bool) : Void*
      head = Pointer(Void).null
      batch = (8192_u64 / payload.to_u64).to_i32.clamp(1, 256)
      @alloc_lock.sync do
        2.times do |attempt|
          if nursery
            if @nursery_freelists[class_index].null?
              refill_size_class(class_index, payload, nursery: true)
            end
          else
            if @freelists[class_index].null?
              refill_size_class(class_index, payload, nursery: false)
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
            refill_size_class(class_index, payload, nursery: nursery)
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
      end
      head
    end

    protected def tlab_alloc_small(payload : UInt32, flags : UInt32, class_index : Int32, nursery : Bool, rounded : UInt64) : Void*
      # Per-slot lock closes Parallel dual-alloc on freelist head (TOCTOU on the
      # lock-free load/store, or two OS threads briefly sharing a slot). Epoch
      # protocol still applies across STW flush.
      32.times do
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
          raise OutOfMemoryError.new("failed to refill TLAB size class #{payload}") if filled.null?
          next if @tlab_epoch.get != epoch
          next # claim the freshly installed batch under the slot lock
        end

        # Atomic counters — no @alloc_lock on the TLAB hit path (Parallel thr).
        free_bytes_sub(payload.to_u64)
        @nursery_alloc_bytes.add(payload.to_u64) if nursery
        note_alloc_bytes(rounded)
        return user
      end
      raise OutOfMemoryError.new("failed to claim TLAB node size class #{payload}")
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

    # Flush TLAB freelists back to global (call under STW / before sweep / destroy).
    # Bump epoch first so resumed mid-alloc abandons stale TLAB heads already
    # published here. Walks each chain and splices only FREE nodes.
    protected def flush_all_tlabs : Nil
      return unless @tlabs_booted && @tlab_enabled
      @tlab_epoch.add(1)
      # No per-slot locks: callers run under STW. A suspended mutator may hold
      # lock_tlab_slot; taking it here livelocks the collector.
      MAX_TLABS.times do |i|
        next unless @tlabs[i].live
        SIZE_CLASS_COUNT.times do |c|
          head = @tlabs[i].freelists[c]
          unless head.null?
            @freelists[c] = splice_free_nodes(head, @freelists[c])
            @tlabs[i].freelists[c] = Pointer(Void).null
          end

          head = @tlabs[i].nursery_freelists[c]
          unless head.null?
            @nursery_freelists[c] = splice_free_nodes(head, @nursery_freelists[c])
            @tlabs[i].nursery_freelists[c] = Pointer(Void).null
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
    protected def scrub_freelists : Nil
      return unless @tlab_enabled
      SIZE_CLASS_COUNT.times do |c|
        scrub_one_freelist(c, false)
        scrub_one_freelist(c, true)
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
      ab = @alloc_lock.sync { current_alloc_batch_under_lock(key) }
      if ab.null?
        raise OutOfMemoryError.new("alloc-batch table full (#{MAX_TLABS} threads)")
      end
      ab
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
          @alloc_batches[i].owner = key
          @alloc_batches[i].live = true
          return @alloc_batches.to_unsafe + i
        end
        i += 1
      end
      Pointer(AllocBatch).null
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
        raise OutOfMemoryError.new("failed to refill alloc-batch size class #{payload}") if user.null?
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
      end

      return Pointer(Void).null if first.null?

      free_bytes_sub(payload.to_u64 * claimed.to_u64)
      @alloc_batch_refills += 1

      unless stash_head.null?
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

      first
    end

    # Return unused USED-stash nodes to the global freelist (STW / destroy).
    # Bump epoch so a resumed mid-claim abandons stale stash heads.
    protected def flush_all_alloc_batches : Nil
      return if @alloc_batch <= 0
      return unless @alloc_batches_booted
      @alloc_batch_epoch.add(1)
      # No per-slot locks under STW (same rationale as flush_all_tlabs).
      MAX_TLABS.times do |i|
        next unless @alloc_batches[i].live
        SIZE_CLASS_COUNT.times do |c|
          head = @alloc_batches[i].freelists[c]
          next if head.null?
          @alloc_batches[i].freelists[c] = Pointer(Void).null
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
      end
    end
  end
end
