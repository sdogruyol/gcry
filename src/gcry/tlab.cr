# Thread-local allocation buffers (TLAB): each mutator OS thread takes a private
# freelist head per size-class so parallel ExecutionContexts can allocate without
# racing on the global freelist. Chunk refill still serializes on @alloc_lock.
#
# Fields (@alloc_lock, @tlab_enabled, …) are declared/initialized in heap.cr.

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
      @tlab_hits
    end

    protected def ensure_tlabs : Nil
      return if @tlabs_booted
      MAX_TLABS.times do |i|
        @tlabs[i] = Tlab.new
      end
      @tlabs_booted = true
    end

    protected def with_alloc_lock(&)
      if @tlab_enabled
        @alloc_lock.sync { yield }
      else
        yield
      end
    end

    private def current_thread_key : UInt64
      {% if flag?(:win32) || flag?(:wasm32) %}
        1_u64
      {% elsif flag?(:darwin) %}
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
      @alloc_lock.sync { current_tlab_under_lock(key) }
    end

    # Caller must hold @alloc_lock (or be single-threaded).
    protected def current_tlab_under_lock(key : UInt64 = current_thread_key) : Tlab*
      ensure_tlabs
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
      @tlabs.to_unsafe
    end

    # Steal a batch from the global freelist into the calling thread's TLAB.
    # Adaptive batch size: targets ~8 KiB per refill (per-class, clamped to [1, 256]).
    # Skips !free? nodes (USED-on-freelist after mid-alloc STW).
    protected def tlab_refill(class_index : Int32, payload : UInt32, nursery : Bool) : Void*
      head = Pointer(Void).null
      batch = (8192_u64 / payload.to_u64).to_i32.clamp(1, 256)
      @alloc_lock.sync do
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
        while !src.null? && !BlockHeader.free?(BlockHeader.from_user(src))
          src = BlockHeader.from_user(src).value.next_free
          if nursery
            @nursery_freelists[class_index] = src
          else
            @freelists[class_index] = src
          end
        end

        if @blacklist_enabled && !src.null?
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

        unless src.null?
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
          if nursery
            tlab.value.nursery_freelists[class_index] = head
          else
            tlab.value.freelists[class_index] = head
          end
          @tlab_refills += 1
          @tlab_steals += count.to_u64
        end
      end
      head
    end

    protected def tlab_alloc_small(payload : UInt32, flags : UInt32, class_index : Int32, nursery : Bool) : Void*
      # Claim with set_used *before* unlinking. If STW+flush races mid-alloc,
      # freelist head is no longer `user` — do not re-link `next_free` onto TLAB
      # (that would dual-link nodes already spliced to the global freelist).
      tlab = current_tlab
      user = if nursery
               tlab.value.nursery_freelists[class_index]
             else
               tlab.value.freelists[class_index]
             end

      if !user.null? && !BlockHeader.free?(BlockHeader.from_user(user))
        if nursery
          tlab.value.nursery_freelists[class_index] = Pointer(Void).null
        else
          tlab.value.freelists[class_index] = Pointer(Void).null
        end
        user = Pointer(Void).null
      end

      if user.null?
        user = tlab_refill(class_index, payload, nursery)
        raise OutOfMemoryError.new("failed to refill TLAB size class #{payload}") if user.null?
        tlab = current_tlab
      else
        @tlab_hits += 1
      end

      header = BlockHeader.from_user(user)
      next_free = header.value.next_free
      BlockHeader.set_used(header, payload, flags)
      heap_set_mark(header) if @incremental_marking || @collecting

      if nursery
        if tlab.value.nursery_freelists[class_index] == user
          tlab.value.nursery_freelists[class_index] = next_free
        end
      else
        if tlab.value.freelists[class_index] == user
          tlab.value.freelists[class_index] = next_free
        end
      end

      with_alloc_lock do
        @free_bytes -= payload if @free_bytes >= payload
        @nursery_alloc_bytes += payload.to_u64 if nursery
      end
      user
    end

    # Return a small object to the current thread's TLAB (no global lock).
    protected def tlab_free_small(pointer : Void*, class_index : Int32, payload : UInt32, nursery : Bool) : Nil
      tlab = current_tlab
      header = BlockHeader.from_user(pointer)
      if nursery
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, tlab.value.nursery_freelists[class_index])
        tlab.value.nursery_freelists[class_index] = pointer
      else
        header.value = BlockHeader.new(payload, BlockHeader::Flags::FREE, tlab.value.freelists[class_index])
        tlab.value.freelists[class_index] = pointer
      end
      with_alloc_lock do
        @free_bytes += payload.to_u64
      end
    end

    # Flush TLAB freelists back to global (call under STW / before sweep / destroy).
    # Walks each chain and splices only FREE nodes (skips USED mid-alloc claims).
    protected def flush_all_tlabs : Nil
      return unless @tlabs_booted && @tlab_enabled
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
  end
end
