module Gcry
  # Finalizers and disappearing links (WeakRef support).
  #
  # Entry/link tables live in LibC malloc — NOT on the gcry heap. If they were
  # Crystal Arrays, marking the Heap → Registry → Array buffer would keep every
  # finalizable object alive forever (acik: ~1500 TCPSocket + OpenSSL::Digest
  # + 32 KiB IO buffers; finalizers never ran). Boehm-style: registry is
  # invisible to the marker for Entry.object; after mark we enqueue unmarked
  # finalizables, resurrect them through sweep, then run_pending. Callback
  # closure_data is marked explicitly in collect.
  module Finalizers
    alias Callback = Void* -> Nil

    # One open-addressing slot. `object.null?` is empty; TOMBSTONE is deleted.
    struct IndexSlot
      property object : Void*
      property count : Int32

      def initialize(@object : Void*, @count : Int32)
      end
    end

    struct Entry
      property object : Void*
      property callback : Callback

      def initialize(@object : Void*, @callback : Callback)
      end
    end

    struct Link
      property link : Void**
      property object : Void*

      def initialize(@link : Void**, @object : Void*)
      end
    end

    struct PendingNode
      property next : PendingNode*
      property object : Void*
      property callback : Callback

      def initialize(@object : Void*, @callback : Callback, @next : PendingNode* = Pointer(PendingNode).null)
      end
    end

    class Registry
      # Registration index: object pointer -> number of entries + links naming
      # it. Answers "does this object have any registration?" in O(1).
      #
      # This replaces `BlockHeader::Flags::FINALIZER` / `DISAPPEARING` as the
      # guard on `notice_reclaim`'s linear scan. Those flag bits have to leave
      # the header for Phase 7, and the comment on `notice_reclaim` explains why
      # they cannot simply be dropped: without a guard, every ordinary free
      # scans thousands of unrelated entries, measured at ~15%+ CPU on HTTP
      # apps.
      #
      # It is **not** free. Measured against the flags it replaces: **+4.5 ns
      # per free, +9.5% (t=4.44)** on a free-heavy loop with a 5000-entry table.
      # The flag was a bit in the object's own header, already in cache because
      # the block is being freed; the index is a probe into a separate table and
      # pays a miss. That is the price of getting the bits out of the header,
      # and it is charged on every free, not only on registered objects.
      #
      # It buys back the O(n) scan for objects that *do* have a registration,
      # which the flags never avoided — but registered objects are the rare case,
      # so on balance this is a small regression traded for the header space.
      #
      # Open addressing, power-of-two capacity, linear probe. LibC malloc like
      # the tables beside it, never the gcry heap.
      @index : IndexSlot* = Pointer(IndexSlot).null
      @index_cap = 0
      @index_used = 0

      @entries : Entry* = Pointer(Entry).null
      @entries_size = 0
      @entries_cap = 0
      @links : Link* = Pointer(Link).null
      @links_size = 0
      @links_cap = 0
      @pending : PendingNode* = Pointer(PendingNode).null
      @pending_count = 0
      # LibC table mutate vs MT allocators (preview_mt / EC).
      @lock = Crystal::SpinLock.new

      def clear : Nil
        @lock.lock
        begin
          LibC.free(@index.as(Void*)) unless @index.null?
          @index = Pointer(IndexSlot).null
          @index_cap = 0
          @index_used = 0
          LibC.free(@entries.as(Void*)) unless @entries.null?
          LibC.free(@links.as(Void*)) unless @links.null?
          @entries = Pointer(Entry).null
          @links = Pointer(Link).null
          @entries_size = 0
          @entries_cap = 0
          @links_size = 0
          @links_cap = 0
          free_pending
        ensure
          @lock.unlock
        end
      end

      def add(object : Void*, callback : Callback) : Nil
        return if object.null?
        @lock.lock
        begin
          ensure_entries_cap(@entries_size + 1)
          @entries[@entries_size] = Entry.new(object, callback)
          @entries_size += 1
          index_add(object)
        ensure
          @lock.unlock
        end
      end

      def register_disappearing_link(link : Void**, object : Void*) : Nil
        return if link.null? || object.null?
        @lock.lock
        begin
          ensure_links_cap(@links_size + 1)
          @links[@links_size] = Link.new(link, object)
          @links_size += 1
          index_add(object)
        ensure
          @lock.unlock
        end
      end

      def entry_count : Int32
        @entries_size
      end

      def link_count : Int32
        @links_size
      end

      def entry_object_at(i : Int32) : Void*
        @entries[i].object
      end

      def link_object_at(i : Int32) : Void*
        @links[i].object
      end

      # Queue finalizer at *i* and swap-remove (does not allocate on GC heap).
      # STW collect only — mutators quiesced via lock_for_stw (see collect_stw).
      def queue_and_remove_entry_at(i : Int32) : Nil
        queue_pending(@entries[i])
        swap_remove_entry(i)
      end

      # Clear disappearing link at *i* and swap-remove. STW collect only.
      def clear_and_remove_link_at(i : Int32) : Nil
        @links[i].link.value = Pointer(Void).null
        swap_remove_link(i)
      end

      # Held across stop_world so no mutator is frozen mid-add/notice_reclaim.
      def lock_for_stw : Nil
        @lock.lock
      end

      def unlock_for_stw : Nil
        @lock.unlock
      end

      # Explicit free path: drop registry rows for one object.
      # Common realloc/free of ordinary objects must not scan thousands of
      # unrelated finalizer entries (perf: ~15%+ CPU on HTTP apps).
      def notice_reclaim(object : Void*) : Nil
        return if object.null?
        @lock.lock
        begin
          return if @entries_size == 0 && @links_size == 0

          # Was two header flag bits; now an O(1) index lookup. Phase 7 needs
          # those bits out of the header, and this is strictly better than what
          # it replaces: it also skips the scan for registered objects whose
          # rows sit late in the table. A null index (C allocation failed) makes
          # `index_registered?` return false, so fall through to the scan —
          # slower, never wrong.
          if @index_cap > 0
            return unless index_registered?(object)
          end
          scan_entries = @entries_size > 0
          scan_links = @links_size > 0
          return unless scan_entries || scan_links

          if scan_entries
            i = 0
            while i < @entries_size
              if @entries[i].object == object
                queue_pending(@entries[i])
                swap_remove_entry(i)
              else
                i += 1
              end
            end
          end

          if scan_links
            i = 0
            while i < @links_size
              if @links[i].object == object
                @links[i].link.value = Pointer(Void).null
                swap_remove_link(i)
              else
                i += 1
              end
            end
          end
        ensure
          @lock.unlock
        end
      end

      def run_pending : Nil
        @lock.lock
        node = @pending
        @pending = Pointer(PendingNode).null
        @pending_count = 0
        @lock.unlock
        # Callbacks outside the lock (may re-enter add / allocate).
        while node
          nxt = node.value.next
          callback = node.value.callback
          object = node.value.object
          LibC.free(node.as(Void*))
          Trace.finalizer("run", object)
          callback.call(object)
          node = nxt
        end
      end

      def pending_count : Int32
        @pending_count
      end

      def entry_closure_data_at(i : Int32) : Void*
        @entries[i].callback.closure_data
      end

      # LibC storage — not a GC object; kept for API compat / diagnostics.
      def entries_buffer : Void*
        @entries.as(Void*)
      end

      def links_buffer : Void*
        @links.as(Void*)
      end

      private def ensure_entries_cap(need : Int32) : Nil
        return if need <= @entries_cap
        new_cap = @entries_cap == 0 ? 16 : @entries_cap * 2
        new_cap = need if new_cap < need
        bytes = (new_cap * sizeof(Entry)).to_u64
        ptr = if @entries.null?
                LibC.malloc(LibC::SizeT.new(bytes))
              else
                LibC.realloc(@entries.as(Void*), LibC::SizeT.new(bytes))
              end
        raise OutOfMemoryError.new("finalizer entries realloc failed") if ptr.null?
        @entries = ptr.as(Entry*)
        @entries_cap = new_cap
      end

      private def ensure_links_cap(need : Int32) : Nil
        return if need <= @links_cap
        new_cap = @links_cap == 0 ? 16 : @links_cap * 2
        new_cap = need if new_cap < need
        bytes = (new_cap * sizeof(Link)).to_u64
        ptr = if @links.null?
                LibC.malloc(LibC::SizeT.new(bytes))
              else
                LibC.realloc(@links.as(Void*), LibC::SizeT.new(bytes))
              end
        raise OutOfMemoryError.new("finalizer links realloc failed") if ptr.null?
        @links = ptr.as(Link*)
        @links_cap = new_cap
      end

      # Deleted marker. Address 1 can never be a real object pointer.
      TOMBSTONE = Pointer(Void).new(1_u64)

      private def index_hash(object : Void*) : UInt64
        # Objects are at least 16-byte aligned, so the low bits carry nothing.
        # Fibonacci mix on the shifted pointer spreads them across the table.
        (object.address >> 4) &* 0x9E3779B97F4A7C15_u64
      end

      # Once the index's C allocation has failed, it stays off for the process.
      #
      # Without this the fallback is neither safe nor correct. `index_grow`
      # frees the old table and sets `@index_cap = 0` so `notice_reclaim`
      # scans instead, but the growth attempt is retried on the next
      # registration — and if *that* one succeeds the table is live again with
      # only the rows added since, while `notice_reclaim` starts trusting it
      # (`@index_cap > 0`). Every object registered before the failure then
      # reads unregistered, so its disappearing links are never cleared on
      # `free`/`realloc`: a dangling `WeakRef`. Sticky keeps the answer the
      # comment promises — slow, never wrong.
      @index_disabled = false

      # Spec/research: the state a refused `index_grow` allocation leaves.
      def debug_index_give_up : Nil
        @lock.lock
        begin
          LibC.free(@index.as(Void*)) unless @index.null?
          @index = Pointer(IndexSlot).null
          @index_cap = 0
          @index_used = 0
          @index_disabled = true
        ensure
          @lock.unlock
        end
      end

      def index_cap : Int32
        @index_cap
      end

      # Bump the registration count for *object*, inserting it if absent.
      private def index_add(object : Void*) : Nil
        return if object.null?
        return if @index_disabled
        # Grow at 1/2 load. Tombstones count toward `@index_used`, so a table
        # churned by add/remove rehashes rather than degrading into a full probe.
        index_grow if @index_cap == 0 || (@index_used + 1) * 2 >= @index_cap
        # The grow can have given up (out of C memory), in which case there is
        # no table to probe: `mask` would be `UInt64::MAX` and `@index[i]` a
        # null dereference.
        return if @index_cap == 0
        mask = (@index_cap - 1).to_u64
        i = index_hash(object) & mask
        first_free = -1
        loop do
          slot = @index[i]
          if slot.object == object
            @index[i] = IndexSlot.new(object, slot.count + 1)
            return
          elsif slot.object.null?
            target = first_free >= 0 ? first_free : i.to_i32
            @index[target] = IndexSlot.new(object, 1)
            @index_used += 1 if first_free < 0
            return
          elsif slot.object == TOMBSTONE && first_free < 0
            first_free = i.to_i32
          end
          i = (i &+ 1) & mask
        end
      end

      # Drop one registration for *object*; remove it at zero.
      private def index_remove(object : Void*) : Nil
        return if object.null? || @index_cap == 0
        mask = (@index_cap - 1).to_u64
        i = index_hash(object) & mask
        loop do
          slot = @index[i]
          return if slot.object.null?
          if slot.object == object
            if slot.count > 1
              @index[i] = IndexSlot.new(object, slot.count - 1)
            else
              @index[i] = IndexSlot.new(TOMBSTONE, 0)
            end
            return
          end
          i = (i &+ 1) & mask
        end
      end

      # True iff *object* has at least one entry or link.
      private def index_registered?(object : Void*) : Bool
        return false if @index_cap == 0
        mask = (@index_cap - 1).to_u64
        i = index_hash(object) & mask
        loop do
          slot = @index[i]
          return false if slot.object.null?
          return true if slot.object == object
          i = (i &+ 1) & mask
        end
      end

      private def index_grow : Nil
        old_table = @index
        old_cap = @index_cap
        new_cap = old_cap == 0 ? 64 : old_cap * 2
        bytes = (new_cap * sizeof(IndexSlot)).to_u64
        fresh = LibC.malloc(LibC::SizeT.new(bytes)).as(IndexSlot*)
        # Out of C memory: drop the index entirely rather than half-fill it,
        # and do not try again — see `@index_disabled`. A null index makes
        # `notice_reclaim` fall back to the linear scan, which is slow but
        # correct; a *partial* index is neither.
        if fresh.null?
          LibC.free(old_table.as(Void*)) unless old_table.null?
          @index = Pointer(IndexSlot).null
          @index_cap = 0
          @index_used = 0
          @index_disabled = true
          return
        end
        i = 0
        while i < new_cap
          fresh[i] = IndexSlot.new(Pointer(Void).null, 0)
          i += 1
        end
        @index = fresh
        @index_cap = new_cap
        @index_used = 0
        # Reinsert live rows only, which is what drops accumulated tombstones.
        j = 0
        while j < old_cap
          slot = old_table[j]
          unless slot.object.null? || slot.object == TOMBSTONE
            mask = (new_cap - 1).to_u64
            k = index_hash(slot.object) & mask
            while !@index[k].object.null?
              k = (k &+ 1) & mask
            end
            @index[k] = slot
            @index_used += 1
          end
          j += 1
        end
        LibC.free(old_table.as(Void*)) unless old_table.null?
      end

      private def swap_remove_entry(i : Int32) : Nil
        index_remove(@entries[i].object)
        last = @entries_size - 1
        @entries[i] = @entries[last] if i != last
        @entries_size = last
      end

      private def swap_remove_link(i : Int32) : Nil
        index_remove(@links[i].object)
        last = @links_size - 1
        @links[i] = @links[last] if i != last
        @links_size = last
      end

      private def queue_pending(entry : Entry) : Nil
        node = LibC.malloc(sizeof(PendingNode)).as(PendingNode*)
        raise OutOfMemoryError.new("finalizer pending malloc failed") if node.null?
        node.value = PendingNode.new(entry.object, entry.callback, @pending)
        @pending = node
        @pending_count += 1
      end

      private def free_pending : Nil
        node = @pending
        @pending = Pointer(PendingNode).null
        @pending_count = 0
        while node
          nxt = node.value.next
          LibC.free(node.as(Void*))
          node = nxt
        end
      end
    end
  end
end
