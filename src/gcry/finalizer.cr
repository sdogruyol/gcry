module Gcry
  # Finalizers and disappearing links (WeakRef support).
  #
  # Entry/link tables live in LibC malloc — NOT on the gcry heap. If they were
  # Crystal Arrays, marking the Heap → Registry → Array buffer would keep every
  # finalizable object alive forever (acik: ~1500 TCPSocket + OpenSSL::Digest
  # + 32 KiB IO buffers; finalizers never ran). Boehm-style: registry is
  # invisible to the marker for Entry.object; after mark we enqueue unmarked
  # finalizables, resurrect them through sweep, then run_pending. Callback
  # closure_data, and every queued object until its finalizer has run, is
  # marked explicitly in collect.
  module Finalizers
    alias Callback = Void* -> Nil

    # How the ordering pass marks from an unreachable finalizable object:
    # Boehm's `fo_mark_proc`, chosen by the call that registered it.
    enum Order : UInt8
      # `GC_register_finalizer_ignore_self`, which is how Crystal's stdlib
      # registers every finalizer (`gc/boehm.cr`), so `GC.add_finalizer` too: a
      # pointer into the object's own block is not followed.
      IgnoreSelf
      # `GC_register_finalizer`: every pointer is followed, its own included,
      # so an object that points at itself reaches itself — a cycle, never
      # finalized (Boehm's `GC_normal_finalize_mark_proc`).
      Normal
    end

    # One open-addressing slot. `object.null?` is empty; TOMBSTONE is deleted.
    struct IndexSlot
      property object : Void*
      property count : Int32

      def initialize(@object : Void*, @count : Int32)
      end
    end

    # How a callback is called. A Crystal one is `callback.call(object)`. A
    # Boehm `GC_finalization_proc` is stored as a `Callback` whose pointer is
    # the C function and whose closure data is the client data, and is called
    # `fn(object, cd)` — so the client data is marked, as Boehm keeps it alive
    # until the finalizer runs, and no closure is allocated for it.
    def self.invoke(object : Void*, callback : Callback, c_abi : Bool) : Nil
      if c_abi
        Proc(Void*, Void*, Nil).new(callback.pointer, Pointer(Void).null).call(object, callback.closure_data)
      else
        callback.call(object)
      end
    end

    struct Entry
      property object : Void*
      property callback : Callback
      property order : Order
      property? c_abi : Bool

      def initialize(@object : Void*, @callback : Callback, @order : Order = Order::IgnoreSelf, @c_abi : Bool = false)
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
      property? c_abi : Bool

      def initialize(@object : Void*, @callback : Callback, @c_abi : Bool, @next : PendingNode* = Pointer(PendingNode).null)
      end
    end

    # Pointer -> number of rows naming it, answering "is this pointer in the
    # table?" in O(1). Open addressing, power-of-two capacity, linear probe.
    # LibC malloc like the tables beside it, never the gcry heap. The caller
    # holds the registry's lock.
    struct PointerIndex
      # Deleted marker. Address 1 can never be a real object pointer.
      TOMBSTONE = Pointer(Void).new(1_u64)

      @slots : IndexSlot* = Pointer(IndexSlot).null
      @cap = 0
      @used = 0

      # Once the table's C allocation has failed, it stays off for the process.
      #
      # Without this the fallback is neither safe nor correct. `grow` frees the
      # old table and sets `@cap = 0` so the caller scans instead, but the
      # growth attempt is retried on the next registration — and if *that* one
      # succeeds the table is live again with only the rows added since, while
      # the caller starts trusting it (`available?`). Every pointer registered
      # before the failure then reads unregistered: for the object index, its
      # disappearing links are never cleared on `free`/`realloc` — a dangling
      # `WeakRef`. Sticky keeps the answer the comment promises — slow, never
      # wrong.
      @disabled = false

      def initialize
      end

      def cap : Int32
        @cap
      end

      # Whether `includes?` answers. False before the first row and after the
      # table gave up; the caller then scans its rows.
      def available? : Bool
        @cap > 0
      end

      def clear : Nil
        LibC.free(@slots.as(Void*)) unless @slots.null?
        @slots = Pointer(IndexSlot).null
        @cap = 0
        @used = 0
      end

      # The state a refused `grow` allocation leaves.
      def give_up : Nil
        clear
        @disabled = true
      end

      # Bump the count for *key*, inserting it if absent.
      def add(key : Void*) : Nil
        return if key.null?
        return if @disabled
        # Grow at 1/2 load. Tombstones count toward `@used`, so a table churned
        # by add/remove rehashes rather than degrading into a full probe.
        grow if @cap == 0 || (@used + 1) * 2 >= @cap
        # The grow can have given up (out of C memory), in which case there is
        # no table to probe: `mask` would be `UInt64::MAX` and `@slots[i]` a
        # null dereference.
        return if @cap == 0
        mask = (@cap - 1).to_u64
        i = hash(key) & mask
        first_free = -1
        loop do
          slot = @slots[i]
          if slot.object == key
            @slots[i] = IndexSlot.new(key, slot.count + 1)
            return
          elsif slot.object.null?
            target = first_free >= 0 ? first_free : i.to_i32
            @slots[target] = IndexSlot.new(key, 1)
            @used += 1 if first_free < 0
            return
          elsif slot.object == TOMBSTONE && first_free < 0
            first_free = i.to_i32
          end
          i = (i &+ 1) & mask
        end
      end

      # Drop one count for *key*; remove it at zero.
      def remove(key : Void*) : Nil
        return if key.null? || @cap == 0
        mask = (@cap - 1).to_u64
        i = hash(key) & mask
        loop do
          slot = @slots[i]
          return if slot.object.null?
          if slot.object == key
            if slot.count > 1
              @slots[i] = IndexSlot.new(key, slot.count - 1)
            else
              @slots[i] = IndexSlot.new(TOMBSTONE, 0)
            end
            return
          end
          i = (i &+ 1) & mask
        end
      end

      # True iff *key* has at least one row. Only meaningful when `available?`.
      def includes?(key : Void*) : Bool
        return false if @cap == 0
        mask = (@cap - 1).to_u64
        i = hash(key) & mask
        loop do
          slot = @slots[i]
          return false if slot.object.null?
          return true if slot.object == key
          i = (i &+ 1) & mask
        end
      end

      private def hash(key : Void*) : UInt64
        # Objects are at least 16-byte aligned, so the low bits carry nothing.
        # Fibonacci mix on the shifted pointer spreads them across the table.
        (key.address >> 4) &* 0x9E3779B97F4A7C15_u64
      end

      private def grow : Nil
        old_table = @slots
        old_cap = @cap
        new_cap = old_cap == 0 ? 64 : old_cap * 2
        bytes = (new_cap * sizeof(IndexSlot)).to_u64
        fresh = LibC.malloc(LibC::SizeT.new(bytes)).as(IndexSlot*)
        # Out of C memory: drop the table entirely rather than half-fill it,
        # and do not try again — see `@disabled`. A missing table makes the
        # caller fall back to its linear scan, which is slow but correct; a
        # *partial* table is neither.
        if fresh.null?
          LibC.free(old_table.as(Void*)) unless old_table.null?
          @slots = Pointer(IndexSlot).null
          @cap = 0
          @used = 0
          @disabled = true
          return
        end
        i = 0
        while i < new_cap
          fresh[i] = IndexSlot.new(Pointer(Void).null, 0)
          i += 1
        end
        @slots = fresh
        @cap = new_cap
        @used = 0
        # Reinsert live rows only, which is what drops accumulated tombstones.
        mask = (new_cap - 1).to_u64
        j = 0
        while j < old_cap
          slot = old_table[j]
          unless slot.object.null? || slot.object == TOMBSTONE
            k = hash(slot.object) & mask
            while !@slots[k].object.null?
              k = (k &+ 1) & mask
            end
            @slots[k] = slot
            @used += 1
          end
          j += 1
        end
        LibC.free(old_table.as(Void*)) unless old_table.null?
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
      @index = PointerIndex.new

      @entries : Entry* = Pointer(Entry).null
      @entries_size = 0
      @entries_cap = 0
      @links : Link* = Pointer(Link).null
      @links_size = 0
      @links_cap = 0
      # Queued finalizers, newest first. Every collection marks each queued
      # object (and so what it reaches) until its finalizer has run — see
      # `each_pending`.
      @pending : PendingNode* = Pointer(PendingNode).null
      @pending_count = 0
      # LibC table mutate vs MT allocators (preview_mt / EC).
      @lock = Crystal::SpinLock.new

      def clear : Nil
        @lock.lock
        begin
          @index.clear
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

      # A Crystal finalizer (`GC.add_finalizer`, `Heap#add_finalizer`). Adds a
      # row; an object given two has both run.
      def add(object : Void*, callback : Callback) : Nil
        return if object.null?
        @lock.lock
        begin
          append_entry(Entry.new(object, callback))
        ensure
          @lock.unlock
        end
      end

      # Boehm's `GC_register_finalizer*`: an object has at most one finalizer.
      # Registering again replaces it, a null *fn* removes it, and the one it
      # had is returned as `{fn, cd}` — nulls when there was none
      # (`GC_register_finalizer_inner`, finalize.c).
      #
      # A row `add` made has no C form unless its callback is a plain function:
      # a Crystal proc that captures nothing is a C function of one argument,
      # and `fn(obj, cd)` calls it with the extra argument ignored on every ABI
      # gcry runs on. A closure is reported as no finalizer, and replaced all
      # the same.
      def replace_c(object : Void*, fn : Void*, data : Void*, order : Order) : {Void*, Void*}
        previous = {Pointer(Void).null, Pointer(Void).null}
        return previous if object.null?
        @lock.lock
        begin
          if @entries_size > 0 && (!@index.available? || @index.includes?(object))
            found = false
            i = 0
            while i < @entries_size
              entry = @entries[i]
              if entry.object == object
                unless found
                  found = true
                  callback = entry.callback
                  if entry.c_abi?
                    previous = {callback.pointer, callback.closure_data}
                  elsif callback.closure_data.null?
                    previous = {callback.pointer, Pointer(Void).null}
                  end
                end
                swap_remove_entry(i)
              else
                i += 1
              end
            end
          end
          append_entry(Entry.new(object, Callback.new(fn, data), order, c_abi: true)) unless fn.null?
        ensure
          @lock.unlock
        end
        previous
      end

      def register_disappearing_link(link : Void**, object : Void*) : Nil
        return if link.null? || object.null?
        @lock.lock
        begin
          ensure_links_cap(@links_size + 1)
          @links[@links_size] = Link.new(link, object)
          @links_size += 1
          @index.add(object)
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

      def entry_order_at(i : Int32) : Order
        @entries[i].order
      end

      def link_object_at(i : Int32) : Void*
        @links[i].object
      end

      # Where link *i* lives: the word that is nulled when its target dies.
      def link_location_at(i : Int32) : Void*
        @links[i].link.as(Void*)
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

      # Drop link *i* without touching its location, which belongs to an
      # object that is about to be reclaimed. STW collect only.
      def remove_link_at(i : Int32) : Nil
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
          # rows sit late in the table. An index that is not available (its C
          # allocation failed) answers nothing, so fall through to the scan —
          # slower, never wrong.
          if @index.available?
            return unless @index.includes?(object)
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

      # One node at a time, each taken off the queue only when its finalizer
      # is about to run: until then it is still on `@pending`, which every
      # collection marks from (`each_pending`). A collection that runs while a
      # finalizer does — another thread's — therefore still keeps every object
      # queued behind it, and the one running is on this thread's stack.
      def run_pending : Nil
        loop do
          @lock.lock
          node = @pending
          unless node.null?
            @pending = node.value.next
            @pending_count -= 1
          end
          @lock.unlock
          break if node.null?
          object = node.value.object
          callback = node.value.callback
          c_abi = node.value.c_abi?
          LibC.free(node.as(Void*))
          # Callbacks outside the lock (may re-enter add / allocate).
          Trace.finalizer("run", object)
          Finalizers.invoke(object, callback, c_abi)
        end
      end

      def pending_count : Int32
        @pending_count
      end

      # Each queued object and its callback's closure data. They are roots: a
      # queued object is still to be passed to its finalizer, which may use
      # what it holds, so a collection before `run_pending` must neither sweep
      # it nor find what it holds unreachable — that would sweep the holder
      # under its own finalizer and queue what it holds ahead of it. Boehm
      # pushes its queue (`finalize_now`) as a root every collection
      # (`GC_push_finalizer_structures`). World stopped; registry quiesced at
      # stop_world.
      def each_pending(& : Void*, Void* ->) : Nil
        node = @pending
        until node.null?
          yield node.value.object, node.value.callback.closure_data
          node = node.value.next
        end
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

      # Spec/research: the state a refused index allocation leaves.
      def debug_index_give_up : Nil
        @lock.lock
        begin
          @index.give_up
        ensure
          @lock.unlock
        end
      end

      def index_cap : Int32
        @index.cap
      end

      private def append_entry(entry : Entry) : Nil
        ensure_entries_cap(@entries_size + 1)
        @entries[@entries_size] = entry
        @entries_size += 1
        @index.add(entry.object)
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

      private def swap_remove_entry(i : Int32) : Nil
        @index.remove(@entries[i].object)
        last = @entries_size - 1
        @entries[i] = @entries[last] if i != last
        @entries_size = last
      end

      private def swap_remove_link(i : Int32) : Nil
        @index.remove(@links[i].object)
        last = @links_size - 1
        @links[i] = @links[last] if i != last
        @links_size = last
      end

      private def queue_pending(entry : Entry) : Nil
        node = LibC.malloc(sizeof(PendingNode)).as(PendingNode*)
        raise OutOfMemoryError.new("finalizer pending malloc failed") if node.null?
        node.value = PendingNode.new(entry.object, entry.callback, entry.c_abi?, @pending)
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
