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
    # In the registry's object index, *count* is the number of entry and link
    # rows naming *object* and *row* the newest of its entry rows (-1: none).
    # In its link index, *row* is the location's link row and *count* unused.
    # Two Int32 fill the word one would pad to: 16 bytes either way.
    struct IndexSlot
      property object : Void*
      property count : Int32
      property row : Int32

      def initialize(@object : Void*, @count : Int32 = 0, @row : Int32 = -1)
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

    # `prev_row`/`next_row` chain every row naming the same object, newest
    # first, from the row its object-index slot names: the rows of one object
    # are found without a scan of the table. -1 ends the chain. *slot* is that
    # object-index slot (-1: none was had), so a removal reaches it without a
    # probe; it is meaningless once the index has given up.
    struct Entry
      property object : Void*
      property callback : Callback
      property order : Order
      property? c_abi : Bool
      property prev_row : Int32 = -1
      property next_row : Int32 = -1
      property slot : Int32 = -1

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

    # Pointer -> {count, row}, open addressing, power-of-two capacity, linear
    # probe. LibC memory like the tables beside it, never the gcry heap. The
    # caller holds the registry's lock.
    #
    # A slot keeps its index until the next `grow`, so a caller may hold on to
    # one (`Entry#slot`); `claim` hands over the old -> new map of a grow.
    # Only `claim` allocates. `find`, `[]=` and `release` never do, which is
    # what lets the collector drop rows with the world stopped: a thread
    # frozen inside `malloc` holds its lock.
    struct PointerIndex
      # Deleted marker. Address 1 is never an object or a link location.
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

      # Whether `find` answers. False before the first key and after the
      # table gave up; the caller then scans its rows.
      def available? : Bool
        @cap > 0
      end

      # Whether the table gave up for good (`@disabled`). Unlike
      # `available?`, false before the first key: an empty table that has
      # not given up answers "absent" correctly.
      def disabled? : Bool
        @disabled
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

      def [](i : Int32) : IndexSlot
        @slots[i]
      end

      def []=(i : Int32, slot : IndexSlot) : IndexSlot
        @slots[i] = slot
      end

      # Delete the key in slot *i*.
      def release(i : Int32) : Nil
        @slots[i] = IndexSlot.new(TOMBSTONE)
      end

      # The slot holding *key*, or -1. Only meaningful when `available?`.
      def find(key : Void*) : Int32
        return -1 if key.null? || @cap == 0
        mask = (@cap - 1).to_u64
        i = hash(key) & mask
        loop do
          slot = @slots[i]
          return -1 if slot.object.null?
          return i.to_i32 if slot.object == key
          i = (i &+ 1) & mask
        end
      end

      # The slot holding *key*, inserted as `{count: 0, row: -1}` when it was
      # absent; -1 when there is no table (null key, or the table gave up).
      # A `grow` on the way that moved keys yields, once and before the slot
      # is returned, the map from every old slot to its new one (-1 for an
      # old slot that held none): valid during the block only.
      def claim(key : Void*, & : Int32* ->) : Int32
        return -1 if key.null?
        return -1 if @disabled
        # Grow at 1/2 load. Tombstones count toward `@used`, so a table churned
        # by insert/release rehashes rather than degrading into a full probe.
        if @cap == 0 || (@used + 1) * 2 >= @cap
          grow { |remap| yield remap }
        end
        # The grow can have given up (out of C memory), in which case there is
        # no table to probe: `mask` would be `UInt64::MAX` and `@slots[i]` a
        # null dereference.
        return -1 if @cap == 0
        mask = (@cap - 1).to_u64
        i = hash(key) & mask
        first_free = -1
        loop do
          slot = @slots[i]
          if slot.object == key
            return i.to_i32
          elsif slot.object.null?
            target = first_free >= 0 ? first_free : i.to_i32
            @slots[target] = IndexSlot.new(key)
            @used += 1 if first_free < 0
            return target
          elsif slot.object == TOMBSTONE && first_free < 0
            first_free = i.to_i32
          end
          i = (i &+ 1) & mask
        end
      end

      # `claim` for a table nobody holds slots of.
      def claim(key : Void*) : Int32
        claim(key) { }
      end

      # Keys present. A walk of the whole table — specs only.
      def live_count : Int32
        n = 0
        @cap.times do |i|
          object = @slots[i].object
          n += 1 unless object.null? || object == TOMBSTONE
        end
        n
      end

      private def hash(key : Void*) : UInt64
        # Objects are at least 16-byte aligned, so the low bits carry nothing.
        # Fibonacci mix on the shifted pointer spreads them across the table.
        # Two link locations 8 bytes apart start on one slot and the probe
        # separates them.
        (key.address >> 4) &* 0x9E3779B97F4A7C15_u64
      end

      private def grow(& : Int32* ->) : Nil
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
        # Zero is an empty slot: a null object.
        fresh.clear(new_cap)
        @slots = fresh
        @cap = new_cap
        @used = 0
        return if old_table.null?
        # Reinsert live keys only, which is what drops accumulated tombstones.
        #
        # The old table becomes the old -> new slot map as it is read, in
        # place: entry *j* of the map is the Int32 at byte 4j, inside old slot
        # j/4, which the walk has already copied out (slot 0 is copied before
        # its own write). One dense map lets the caller re-point what holds
        # slots (`Entry#slot`) in a single sequential pass rather than a
        # random walk per moved key, and asks for no memory a failure could
        # refuse.
        remap = old_table.as(Int32*)
        mask = (new_cap - 1).to_u64
        j = 0
        while j < old_cap
          slot = old_table[j]
          if slot.object.null? || slot.object == TOMBSTONE
            remap[j] = -1
          else
            k = hash(slot.object) & mask
            while !@slots[k].object.null?
              k = (k &+ 1) & mask
            end
            @slots[k] = slot
            @used += 1
            remap[j] = k.to_i32
          end
          j += 1
        end
        yield remap
        LibC.free(old_table.as(Void*))
      end
    end

    class Registry
      # Registration index: object pointer -> `{count, row}`, one slot per
      # registered object. *count* is the number of entries + links naming it,
      # answering "does this object have any registration?" in O(1); *row* is
      # the newest of its entry rows, the head of the chain through
      # `Entry#next_row` that holds the rest, or -1.
      #
      # The count replaces `BlockHeader::Flags::FINALIZER` / `DISAPPEARING`
      # as the guard on `notice_reclaim`. Those flag bits have to leave the
      # header for Phase 7, and the comment on `notice_reclaim` explains why
      # they cannot simply be dropped: without a guard, every ordinary free
      # scans thousands of unrelated entries, measured at ~15%+ CPU on HTTP
      # apps. It is **not** free. Measured against the flags it replaces:
      # **+4.5 ns per free, +9.5% (t=4.44)** on a free-heavy loop with a
      # 5000-entry table. The flag was a bit in the object's own header,
      # already in cache because the block is being freed; the index is a
      # probe into a separate table and pays a miss.
      #
      # The head row finds an object's rows without a scan. A single row per
      # object would not do: `add` gives an object as many rows as it is
      # given callbacks (the library heap's `Heap#add_finalizer` keeps them
      # all), and a C or `GC.add_finalizer` registration on such an object
      # has to find and drop every one of them (`replace_c`, `replace`). Those
      # two keep one row per object, Boehm's one finalizer per object. Without
      # it `replace_c` walked every row of the table, under the lock `free`,
      # `add_finalizer` and the collector take: 3.9 µs per
      # `GC_register_finalizer` at 10k registered finalizers, 57.7 µs at 160k,
      # against Boehm's ~15 ns at any count.
      #
      # One table, not a counter and a head map side by side: a second table
      # made 2M `GC.add_finalizer` + collect 37% slower (357 -> 490 ms), every
      # registration and removal paying a miss in each. A registration is one
      # probe, as with the counter alone. A removal is none: each row carries
      # its slot (`Entry#slot`), and writes it, and the slot of the row moved
      # into its place when that row heads its chain.
      #
      # Why carry the slot when a probe would find it in the same cache line:
      # probing instead made the same 2M benchmark 321 ms against 290 (medians
      # of 7) — most likely because the probe's key compare is a branch on the
      # missing load, so the collector's removals stop overlapping misses.
      # The price is at growth, when every row's slot moves: `claim_object`
      # re-points them in one sequential pass through the grow's old -> new
      # map. Walking each moved key's chain instead (rows in hash order, a miss
      # apiece) made fresh registration 78 ns against the counter's 64; the
      # pass makes it ~70.
      #
      # Kept exact through every mutation: `append_entry` links a row in,
      # `swap_remove_entry` unlinks it and re-points the row moved into its
      # place — which every entry removal goes through (`drop_rows`,
      # `notice_reclaim`, the collector's `queue_and_remove_entry_at`) — and
      # `claim_object` re-points every row's slot a growth moves.
      @index = PointerIndex.new
      # Link location -> its row, so a link registered again or unregistered
      # is found without a scan of every `WeakRef`'s row
      # (`register_disappearing_link`, `unregister_disappearing_link`). One
      # row per location — `register_disappearing_link` keeps it so — which is
      # what lets a location map to a single row.
      @link_index = PointerIndex.new

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
          @link_index.clear
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
          append_entry(Entry.new(object, callback), claim_object(object))
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
          if fn.null?
            # A removal inserts nothing, so it only looks.
            previous = drop_rows(object, @index.find(object), keep: false)
          else
            slot = claim_object(object)
            previous = drop_rows(object, slot, keep: true)
            append_entry(Entry.new(object, Callback.new(fn, data), order, c_abi: true), slot)
          end
        ensure
          @lock.unlock
        end
        previous
      end

      # `GC.add_finalizer` for the process GC: *object*'s one finalizer
      # becomes *callback*, as Boehm's `GC_register_finalizer_ignore_self` —
      # which stdlib's `gc/boehm.cr` calls — replaces the one it had. `add`
      # keeps every row it is given, so a Crystal object registered twice (the
      # allocator registers a type with `#finalize`, and its `initialize` may
      # call `GC.add_finalizer(self)` again) had `#finalize` run twice: 2000
      # runs for 1000 objects where Boehm runs 1000
      # (`process_spec/regression/48_add_finalizer_replaces_spec.cr`).
      #
      # One probe for an object that had none, the common case: the slot
      # `claim_object` returns is both the "had one?" answer and where the
      # new row is linked in.
      def replace(object : Void*, callback : Callback) : Nil
        return if object.null?
        @lock.lock
        begin
          slot = claim_object(object)
          drop_rows(object, slot, keep: true)
          append_entry(Entry.new(object, callback), slot)
        ensure
          @lock.unlock
        end
      end

      # Removes every row of *object*, whose `@index` slot is *slot*, and
      # answers the C form of the one with the lowest number — the one a scan
      # of the table meets first — or nulls when it had none. Only `add` gives
      # an object several rows; Boehm's API has one to report. *keep* holds
      # the slot even when its count reaches zero, for the row the caller
      # appends to it next. The caller holds `@lock`.
      private def drop_rows(object : Void*, slot : Int32, keep : Bool) : {Void*, Void*}
        previous = {Pointer(Void).null, Pointer(Void).null}
        return previous if @entries_size == 0
        if slot >= 0
          held = @index[slot]
          head = held.row
          return previous if head < 0
          first = head
          row = head
          while row >= 0
            first = row if row < first
            row = @entries[row].next_row
          end
          previous = c_form(@entries[first])
          @index[slot] = IndexSlot.new(object, held.count + 1, head) if keep
          # Each removal re-points the head; take it until none is left. A
          # released slot is a tombstone, whose row is -1.
          while (row = @index[slot].row) >= 0
            swap_remove_entry(row)
          end
          if keep
            held = @index[slot]
            @index[slot] = IndexSlot.new(object, held.count - 1, held.row)
          end
        elsif @index.disabled?
          # The index gave up its C allocation: scan, slower, never wrong.
          found = false
          i = 0
          while i < @entries_size
            if @entries[i].object == object
              previous = c_form(@entries[i]) unless found
              found = true
              swap_remove_entry(i)
            else
              i += 1
            end
          end
        end
        previous
      end

      # Boehm's `GC_general_register_disappearing_link`: one row per link
      # location. Registering a location again moves its row to *object* and
      # returns false — Boehm's `GC_DUPLICATE`, after which it, too, clears the
      # link when the *new* object dies and not the old one. A null *link* or
      # *object* registers nothing.
      def register_disappearing_link(link : Void**, object : Void*) : Bool
        return true if link.null? || object.null?
        @lock.lock
        begin
          if (i = link_row(link)) >= 0
            old = @links[i].object
            if old != object
              uncount_link(old)
              count_link(object)
              @links[i] = Link.new(link, object)
            end
            return false
          end
          ensure_links_cap(@links_size + 1)
          row = @links_size
          @links[row] = Link.new(link, object)
          @links_size += 1
          slot = @link_index.claim(link.as(Void*))
          @link_index[slot] = IndexSlot.new(link.as(Void*), 0, row) if slot >= 0
          count_link(object)
          true
        ensure
          @lock.unlock
        end
      end

      # Boehm's `GC_unregister_disappearing_link`: drop *link*'s registration,
      # leaving the word at *link* as it is. True if it had one.
      def unregister_disappearing_link(link : Void**) : Bool
        return false if link.null?
        @lock.lock
        begin
          i = link_row(link)
          return false if i < 0
          swap_remove_link(i)
          true
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
          # it replaces: the object's entry rows come off its chain, and its
          # links are scanned for only when it still has a count once those
          # are gone. An index that gave up its C allocation answers nothing,
          # so fall through to the scan — slower, never wrong.
          unless @index.disabled?
            slot = @index.find(object)
            return if slot < 0
            # A released slot is a tombstone, whose row is -1.
            while (row = @index[slot].row) >= 0
              queue_pending(@entries[row])
              swap_remove_entry(row)
            end
            # Released: no link names it either.
            return unless @index[slot].object == object
          end

          if @index.disabled?
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

          i = 0
          while i < @links_size
            if @links[i].object == object
              @links[i].link.value = Pointer(Void).null
              swap_remove_link(i)
            else
              i += 1
            end
          end
        ensure
          @lock.unlock
        end
      end

      # Set while a fiber is in `run_pending`. A finalizer that collects
      # ends that collection in `run_pending` again, which took the next node
      # off the queue and ran it one frame deeper: nesting as deep as the
      # queue was long, a stack overflow at 5 000 (2026-10-07,
      # `process_spec/regression/37_nested_finalizer_collect_spec.cr`). The
      # outer loop drains what the inner collection queues. Boehm bounds the
      # same recursion per thread (`GC_check_finalizer_nested`).
      #
      # Per fiber, not per thread: a finalizer that suspends its fiber left a
      # thread flag set, so every other fiber on that thread skipped the queue
      # (`process_spec/regression/44_finalizer_suspend_drain_spec.cr`), and a
      # fiber resumed on another Parallel thread cleared the first thread's
      # TLS. The thread flag is only for threads with no current fiber.
      @[ThreadLocal]
      @@draining_no_fiber : Bool = false

      # Whether this fiber — this thread, where there is no fiber — is inside
      # `run_pending` already, where another call returns 0 at once.
      def draining? : Bool
        # `Thread.current?`: `Thread.current` allocates on a raw thread.
        if fiber = ::Thread.current?.try(&.@current_fiber)
          fiber.gcry_draining?
        else
          @@draining_no_fiber
        end
      end

      # One node at a time, each taken off the queue only when its finalizer
      # is about to run: until then it is still on `@pending`, which every
      # collection marks from (`each_pending`). A collection that runs while a
      # finalizer does — another thread's — therefore still keeps every object
      # queued behind it, and the one running is on this thread's stack.
      # Returns how many ran; 0 when this fiber is already draining.
      def run_pending : Int32
        return 0 if draining?
        fiber = ::Thread.current?.try(&.@current_fiber)
        if fiber
          fiber.gcry_draining = true
        else
          @@draining_no_fiber = true
        end
        ran = 0
        begin
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
            ran += 1
            Finalizers.invoke(object, callback, c_abi)
          end
        ensure
          if fiber
            fiber.gcry_draining = false
          else
            @@draining_no_fiber = false
          end
        end
        ran
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
          @link_index.give_up
        ensure
          @lock.unlock
        end
      end

      def index_cap : Int32
        @index.cap
      end

      # Spec only: check every index against a brute-force reading of the
      # tables. Nil when they agree, else what disagrees. O(n²); never call it
      # outside a spec.
      def debug_index_error : String?
        @lock.lock
        begin
          chained = 0
          @entries_size.times do |r|
            e = @entries[r]
            unless @index.disabled?
              slot = @index.find(e.object)
              return "row #{r} carries slot #{e.slot}, its object is in #{slot}" if e.slot != slot
              if e.prev_row < 0 && @index[slot].row != r
                return "row #{r} heads its chain, @index says #{@index[slot].row}"
              end
            end
            next unless e.prev_row < 0
            row = r
            prev = -1
            while row >= 0
              return "chain row #{row} out of range" if row >= @entries_size
              return "row #{row} prev #{@entries[row].prev_row}, expected #{prev}" if @entries[row].prev_row != prev
              return "row #{row} chained under another object" if @entries[row].object != e.object
              chained += 1
              return "chain of row #{r} cycles" if chained > @entries_size
              prev = row
              row = @entries[row].next_row
            end
          end
          if @link_index.available?
            @links_size.times do |i|
              slot = @link_index.find(@links[i].link.as(Void*))
              row = slot >= 0 ? @link_index[slot].row : -1
              return "link row #{i} indexed as #{row}" if row != i
            end
            return "@link_index has #{@link_index.live_count} keys, #{@links_size} links" if @link_index.live_count != @links_size
          end
          unless @index.disabled?
            return "#{chained} chained of #{@entries_size} rows" if chained != @entries_size
            distinct = 0
            (@entries_size + @links_size).times do |k|
              object = k < @entries_size ? @entries[k].object : @links[k - @entries_size].object
              # Count each object at its first row only.
              seen = false
              k.times do |j|
                other = j < @entries_size ? @entries[j].object : @links[j - @entries_size].object
                seen = true if other == object
              end
              next if seen
              distinct += 1
              rows = 0
              @entries_size.times { |j| rows += 1 if @entries[j].object == object }
              @links_size.times { |j| rows += 1 if @links[j].object == object }
              slot = @index.find(object)
              count = slot >= 0 ? @index[slot].count : 0
              return "@index counts #{count} rows of #{object}, table has #{rows}" if count != rows
              if slot >= 0 && @index[slot].row >= 0 && @entries[@index[slot].row].object != object
                return "@index heads #{object} with another object's row"
              end
            end
            return "@index has #{@index.live_count} keys, #{distinct} objects" if @index.live_count != distinct
          end
          nil
        ensure
          @lock.unlock
        end
      end

      # *object*'s `@index` slot, inserted when absent; -1 once the index gave
      # up. A growth moves slots: `claim` yields the old -> new slot map, and
      # one sequential pass gives every row its slot's new index.
      private def claim_object(object : Void*) : Int32
        @index.claim(object) do |remap|
          r = 0
          while r < @entries_size
            entry = @entries[r]
            # While the index is on, every row's slot holds its object.
            entry.slot = remap[entry.slot]
            @entries[r] = entry
            r += 1
          end
        end
      end

      # A link row now names *object*.
      private def count_link(object : Void*) : Nil
        slot = claim_object(object)
        return if slot < 0
        held = @index[slot]
        @index[slot] = IndexSlot.new(object, held.count + 1, held.row)
      end

      # A link row no longer names *object*. Allocates nothing.
      private def uncount_link(object : Void*) : Nil
        slot = @index.find(object)
        return if slot < 0
        uncount(slot, @index[slot])
      end

      # One fewer row names the key of *slot*, whose contents are *held*; at
      # none the key goes.
      private def uncount(slot : Int32, held : IndexSlot) : Nil
        if held.count > 1
          @index[slot] = IndexSlot.new(held.object, held.count - 1, held.row)
        else
          @index.release(slot)
        end
      end

      # A new row heads its object's chain, whose `@index` slot is *slot*
      # (-1: the index gave up): it is found first, and linking it in touches
      # no other row's position.
      private def append_entry(entry : Entry, slot : Int32) : Nil
        ensure_entries_cap(@entries_size + 1)
        row = @entries_size
        entry.prev_row = -1
        entry.slot = slot
        if slot >= 0
          held = @index[slot]
          entry.next_row = held.row
          set_prev_row(held.row, row) if held.row >= 0
          @index[slot] = IndexSlot.new(entry.object, held.count + 1, row)
        else
          entry.next_row = -1
        end
        @entries[row] = entry
        @entries_size += 1
      end

      # The row of *link*, or -1. The link index answers without a scan
      # unless it is not available (its C allocation failed).
      private def link_row(link : Void**) : Int32
        return -1 if @links_size == 0
        if @link_index.available?
          slot = @link_index.find(link.as(Void*))
          return slot >= 0 ? @link_index[slot].row : -1
        end
        i = 0
        while i < @links_size
          return i if @links[i].link == link
          i += 1
        end
        -1
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

      # Every entry removal comes here, so this is where `@index` and the
      # chains are kept exact: unlink row *i*, then move the last row into its
      # place and re-point whatever pointed at the last row. Each row carries
      # its slot, so this probes nothing; it writes the removed row's slot,
      # and the moved row's only when that row heads its chain. Allocates
      # nothing — the collector calls it with the world stopped. A given-up
      # index has no slots: rows' are stale then, and go unread.
      private def swap_remove_entry(i : Int32) : Nil
        removed = @entries[i]
        prev = removed.prev_row
        nxt = removed.next_row
        set_next_row(prev, nxt) if prev >= 0
        set_prev_row(nxt, prev) if nxt >= 0
        if (slot = removed.slot) >= 0 && !@index.disabled?
          held = @index[slot]
          uncount(slot, IndexSlot.new(held.object, held.count, prev < 0 ? nxt : held.row))
        end
        last = @entries_size - 1
        if i != last
          # Read after the unlink: the last row may have been *i*'s neighbour.
          moved = @entries[last]
          @entries[i] = moved
          if moved.prev_row >= 0
            set_next_row(moved.prev_row, i)
          elsif (slot = moved.slot) >= 0 && !@index.disabled?
            held = @index[slot]
            @index[slot] = IndexSlot.new(held.object, held.count, i)
          end
          set_prev_row(moved.next_row, i) if moved.next_row >= 0
        end
        @entries_size = last
      end

      # `@entries[row].prev_row = v` would set a field of a copy: `Pointer#[]`
      # returns the struct by value.
      private def set_prev_row(row : Int32, value : Int32) : Nil
        entry = @entries[row]
        entry.prev_row = value
        @entries[row] = entry
      end

      private def set_next_row(row : Int32, value : Int32) : Nil
        entry = @entries[row]
        entry.next_row = value
        @entries[row] = entry
      end

      # A row's finalizer as Boehm reports it, `{fn, cd}`: nulls for a Crystal
      # closure, which has no C form.
      private def c_form(entry : Entry) : {Void*, Void*}
        callback = entry.callback
        if entry.c_abi?
          {callback.pointer, callback.closure_data}
        elsif callback.closure_data.null?
          {callback.pointer, Pointer(Void).null}
        else
          {Pointer(Void).null, Pointer(Void).null}
        end
      end

      # Same for links: drop row *i*'s location, re-point the moved row's.
      private def swap_remove_link(i : Int32) : Nil
        uncount_link(@links[i].object)
        if (slot = @link_index.find(@links[i].link.as(Void*))) >= 0
          @link_index.release(slot)
        end
        last = @links_size - 1
        if i != last
          @links[i] = @links[last]
          if (slot = @link_index.find(@links[i].link.as(Void*))) >= 0
            @link_index[slot] = IndexSlot.new(@links[i].link.as(Void*), 0, i)
          end
        end
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
