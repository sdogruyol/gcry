# Who still points at the block that was freed?
#
# `GCRY_POISON_TAG=1` answers *which* block a use-after-free read out of: the
# poison carries the freed block's address in its low 48 bits, so the crash
# names it. `bench/log/linux/2026-08-15-nested-spawn-uaf/FINDINGS.md` got that
# far and stopped there — the block is a `Deque(Fiber::Stack)` buffer the deque
# abandoned at a resize, gcry freed it correctly, and *something* still reads
# it. Two interventions take the crash to zero (pre-grow the pool so no buffer
# is ever abandoned; never release the root `Heap#realloc` takes on the old
# block) and a bounded grace on that root does not, so the stale pointer is held
# **indefinitely**. By what, nothing has said.
#
# This asks. `GCRY_POISON_HOLDERS=1` extends the crash report with a search for
# the freed block's address in the three places gcry can walk at fault time:
#
#   1. the explicit root set — the collector's own bookkeeping, and the one that
#      says whether `realloc`'s `delete_root` really did run;
#   2. every live block in the heap — a holder here is an object, and its
#      `type_id` names the type that kept the pointer;
#   3. every fiber stack, plus the faulting thread's own frames.
#
# Whatever holds it is the owner, and the owner decides whether this is gcry's
# to fix or Crystal's. A search that finds **nothing** is a result too, and a
# sharp one: it means the pointer lives in a register, in thread-local storage,
# or in memory gcry never mapped — three places with three different answers.
#
# Constraints are the signal handler's, and they are the same ones
# `src/gcry/segv_report.cr` documents: no allocation, `RawOut` only, no locks
# (the faulting thread may hold `@roots_lock`), never create the heap, and
# bounded output — a crash report that scrolls is a crash report nobody reads.
# Best effort by construction: the heap may be mid-mutation, which is usually
# what a crash means. A fault *inside* this search is caught by `SegvReport`'s
# `@@reported` guard, which is set before any of this runs.
{% skip_file unless flag?(:unix) %}

module Gcry
  module PoisonHolders
    # Print at most this many holders per section, then a count. The count is
    # the part that matters — one holder or four hundred is the difference
    # between a single stale field and a copied buffer.
    MAX_REPORTED = 8

    # Termination bound for the heap walk. A chunk list that a concurrent
    # mutation left circular must not turn the crash report into a hang.
    MAX_BLOCKS = 16_000_000_u64

    # Payload words dumped per reported holder. Four covers a `Deque`'s whole
    # object (`type_id`, three `Int32`, `@buffer`) with a word to spare, and the
    # line still fits `RawOut`'s 480-byte buffer.
    DUMP_WORDS = 4_u64

    @@requested = false

    # The first heap holder found, so the search can be run once more against
    # *it*. Class variables and not a return value because the walk is a chain
    # of yielding methods and a signal handler may not allocate a tuple.
    @@first_holder_base = 0_u64
    @@first_holder_size = 0_u64
    @@record_first = false

    def self.request : Nil
      @@requested = true
    end

    def self.requested? : Bool
      @@requested
    end

    # *user* is the freed block's payload address (what the poison tag carries)
    # and *size* its payload bytes, both as `SegvReport` already read them from
    # the heap's tables. A holder is any word whose value lands anywhere inside
    # `[user, user + size)` — interior and not just equal, because a `Deque`
    # holds `@buffer` at the base while its elements are read at an offset, and
    # reporting only exact matches would miss the second case entirely.
    def self.search(heap : Heap, user : UInt64, size : UInt64) : Nil
      return if user == 0 || size == 0

      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: holders — looking for words pointing into [0x")
      len = RawOut.append_hex(buf.to_unsafe, len, user)
      len = RawOut.append(buf.to_unsafe, len, ", 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, user &+ size)
      len = RawOut.append(buf.to_unsafe, len, "), the range gcry released\n")
      RawOut.flush(buf.to_unsafe, len)

      @@first_holder_base = 0_u64
      @@first_holder_size = 0_u64
      @@record_first = true
      found = search_at(heap, user, size, "holders")
      @@record_first = false

      if found == 0
        len = 0
        len = RawOut.append(buf.to_unsafe, len,
          "gcry: holders — none. Nothing in the root set, in a live block or on a fiber stack points " \
          "into it, so the pointer is in a register, in thread-local storage, or in memory gcry never " \
          "mapped — and those are three different defects\n")
        RawOut.flush(buf.to_unsafe, len)
        return
      end

      # One level up, and this is the question the first level opened rather than
      # closed. The holder found for the fiber-creation UAF is itself a heap
      # block — a `Deque(Fiber::Stack)` that no collection has ever marked — so
      # "who freed the buffer" became "why is its owner not live". Asking the
      # same question of the holder answers it: something points at the holder
      # and the mark missed it, which is gcry's defect; or nothing does, and the
      # holder is genuinely unreachable while still being read, which is the
      # mutator publishing an object the collector cannot see — Crystal's.
      base = @@first_holder_base
      bsize = @@first_holder_size
      return if base == 0 || bsize == 0

      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: owner — and who points at that holder? [0x")
      len = RawOut.append_hex(buf.to_unsafe, len, base)
      len = RawOut.append(buf.to_unsafe, len, ", 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, base &+ bsize)
      len = RawOut.append(buf.to_unsafe, len, ")\n")
      RawOut.flush(buf.to_unsafe, len)

      owners = search_at(heap, base, bsize, "owner")
      return unless owners == 0
      len = 0
      len = RawOut.append(buf.to_unsafe, len,
        "gcry: owner — none. Nothing points at the holder either, so the collector was right to " \
        "consider it garbage and the mutator is reading an object it never published anywhere the " \
        "collector can see\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # One pass of the three walks over `[lo, lo + size)`, tagged so a second
    # pass one level up is distinguishable from the first in the output.
    private def self.search_at(heap : Heap, lo : UInt64, size : UInt64, tag : String) : UInt64
      finish = lo &+ size
      found = 0_u64
      found &+= search_roots(heap, lo, finish, tag)
      found &+= search_heap(heap, lo, finish, tag)
      found &+= search_stacks(heap, lo, finish, tag)
      found
    end

    # The collector's own bookkeeping first: it is the cheapest walk, and it is
    # the one that can say `realloc` released its root rather than leaving the
    # question to be inferred from a crash rate.
    private def self.search_roots(heap : Heap, user : UInt64, finish : UInt64, tag : String) : UInt64
      hits = 0_u64
      total = 0_u64
      heap.unsafe_each_root do |ptr|
        total &+= 1
        a = ptr.address
        hits &+= 1 if a >= user && a < finish
      end

      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: ")
      len = RawOut.append(buf.to_unsafe, len, tag)
      len = RawOut.append(buf.to_unsafe, len, " — explicit roots: ")
      len = RawOut.append_u64(buf.to_unsafe, len, hits)
      len = RawOut.append(buf.to_unsafe, len, " of ")
      len = RawOut.append_u64(buf.to_unsafe, len, total)
      len = RawOut.append(buf.to_unsafe, len, hits == 0 ? " point into it — gcry is not rooting it\n" : " point into it\n")
      RawOut.flush(buf.to_unsafe, len)
      hits
    end

    # Every live block in every chunk. A holder here is an *object*, so its
    # first payload word — Crystal's `type_id` — names the type that kept the
    # pointer, which is the whole point of walking the heap rather than only
    # counting matches.
    #
    # FREE blocks are deliberately not searched. A freed block holding the
    # address is a copy nothing reads; reporting it would fill the report with
    # the poison's own neighbours and bury the one line that matters.
    private def self.search_heap(heap : Heap, user : UInt64, finish : UInt64, tag : String) : UInt64
      hits = 0_u64
      blocks_with_hits = 0_u64
      scanned = 0_u64
      chunks = 0_u64
      reported = 0
      budget_out = false

      heap.each_chunk do |chunk|
        chunks &+= 1
        # Dormant chunks were advised away: every header reads as neither used
        # nor FREE (the same property that made `make invariants` miscount for
        # three releases), so walking them reports noise.
        next if ChunkHeader.dormant?(chunk)

        if ChunkHeader.large?(chunk)
          header = ChunkHeader.data_start(chunk).as(BlockHeader*)
          scanned &+= 1
          next if BlockHeader.free?(header)
          h = scan_block(header, user, finish, tag, reported) { |r| reported = r }
          if h > 0
            hits &+= h
            blocks_with_hits &+= 1
          end
          next
        end

        # `to_i32!` and not `to_i32`: a large chunk carries `UInt32::MAX` here
        # and the checked conversion would raise. The range test below is what
        # actually rejects it — same reason the type_id read above is unsigned.
        class_index = chunk.value.size_class.to_i32!
        next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
        block_bytes = BlockHeader::SIZE.to_u64 + SizeClasses.payload(class_index).to_u64
        next if block_bytes == 0

        cursor = ChunkHeader.data_start(chunk).as(UInt8*)
        limit = ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          if scanned >= MAX_BLOCKS
            budget_out = true
            break
          end
          scanned &+= 1
          header = cursor.as(BlockHeader*)
          unless BlockHeader.free?(header)
            h = scan_block(header, user, finish, tag, reported) { |r| reported = r }
            if h > 0
              hits &+= h
              blocks_with_hits &+= 1
            end
          end
          cursor += block_bytes
        end
        break if budget_out
      end

      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: ")
      len = RawOut.append(buf.to_unsafe, len, tag)
      len = RawOut.append(buf.to_unsafe, len, " — heap: ")
      len = RawOut.append_u64(buf.to_unsafe, len, hits)
      len = RawOut.append(buf.to_unsafe, len, " word(s) in ")
      len = RawOut.append_u64(buf.to_unsafe, len, blocks_with_hits)
      len = RawOut.append(buf.to_unsafe, len, " live block(s), from ")
      len = RawOut.append_u64(buf.to_unsafe, len, scanned)
      len = RawOut.append(buf.to_unsafe, len, " block(s) in ")
      len = RawOut.append_u64(buf.to_unsafe, len, chunks)
      len = RawOut.append(buf.to_unsafe, len, " chunk(s)")
      len = RawOut.append(buf.to_unsafe, len, budget_out ? " — walk cut short at the block budget" : "")
      # Carried for context, not as a liveness test — see the note on `flags` in
      # `scan_block`. `clear_all_marks` bumps this at the start of a collection
      # and `sweep` clears each survivor's gen bits at the end, so outside a
      # collection every live block reads zero and the generation only tells you
      # how many collections the crash is downstream of.
      len = RawOut.append(buf.to_unsafe, len, ". current mark gen ")
      len = RawOut.append_u64(buf.to_unsafe, len, heap.header_mark_gen.to_u64)
      len = RawOut.append(buf.to_unsafe, len, ", collections ")
      len = RawOut.append_u64(buf.to_unsafe, len, heap.collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
      hits
    end

    # Scan one live block's payload. Yields the updated report count so the
    # caller's cap survives across blocks without a class variable.
    private def self.scan_block(header : BlockHeader*, user : UInt64, finish : UInt64, tag : String,
                                reported : Int32, &) : UInt64
      size = header.value.size.to_u64
      return 0_u64 if size < sizeof(UInt64)
      base = BlockHeader.user_from(header).address
      # Never report the block on itself: after the free its payload is poison,
      # not pointers, but a reissued block could legitimately contain its own
      # address and that is not a holder of the *old* object.
      return 0_u64 if base == user

      # Read the type_id word **unsigned**. It is only a type_id when the block
      # holds a Crystal object; every other block starts with whatever the
      # allocator's caller put there, and `Int32#to_u64` on a negative one
      # raises `OverflowError` — inside a signal handler, which turns the crash
      # report into a second crash. Measured on the first real run of this
      # search, on a 3072-byte block that was not an object.
      type_id = size >= 4 ? Pointer(UInt32).new(base).value.to_u64 : 0_u64
      words = size // sizeof(UInt64)
      hits = 0_u64
      i = 0_u64
      while i < words
        w = Pointer(UInt64).new(base &+ i &* sizeof(UInt64)).value
        if w >= user && w < finish
          hits &+= 1
          if reported < MAX_REPORTED
            reported += 1
            buf = uninitialized UInt8[512]
            len = 0
            len = RawOut.append(buf.to_unsafe, len, "gcry: ")
            len = RawOut.append(buf.to_unsafe, len, tag)
            len = RawOut.append(buf.to_unsafe, len, " — heap: block 0x")
            len = RawOut.append_hex(buf.to_unsafe, len, base)
            len = RawOut.append(buf.to_unsafe, len, " size ")
            len = RawOut.append_u64(buf.to_unsafe, len, size)
            len = RawOut.append(buf.to_unsafe, len, " type_id ")
            len = RawOut.append_u64(buf.to_unsafe, len, type_id)
            # Raw flags, and deliberately **no verdict about liveness**. The
            # first version of this printed "UNMARKED" for a zero mark
            # generation and read it as "no collection ever marked this" — which
            # was wrong, and wrong in the direction that invents a defect:
            # `sweep` calls `heap_clear_mark` on **every survivor**, so between
            # collections every live object in the heap has zero gen bits.
            # Measured against a `Keeper` held in a local across three
            # collections: `flags 0x0`, exactly like the holder. The bits that
            # do mean something here are the rest — ATOMIC (0x2) says the
            # collector never scans this block's payload, FINALIZER (0x20),
            # NURSERY (0x10), LARGE (0x8) — so print them and let the reader
            # decode rather than asserting a liveness the header cannot carry
            # outside a collection.
            len = RawOut.append(buf.to_unsafe, len, " flags 0x")
            len = RawOut.append_hex(buf.to_unsafe, len, header.value.flags.to_u64)
            len = RawOut.append(buf.to_unsafe, len,
              (header.value.flags & BlockHeader::Flags::ATOMIC) != 0 ? " ATOMIC(unscanned)" : "")
            len = RawOut.append(buf.to_unsafe, len, " holds it at +")
            len = RawOut.append_u64(buf.to_unsafe, len, i &* sizeof(UInt64))
            len = RawOut.append(buf.to_unsafe, len, " (block+")
            len = RawOut.append_u64(buf.to_unsafe, len, w &- user)
            len = RawOut.append(buf.to_unsafe, len, ")\n")
            RawOut.flush(buf.to_unsafe, len)
            dump_payload(base, size)
            # The first holder is the one the caller runs the search against a
            # second time. Recorded here rather than returned: the walk is a
            # chain of yielding methods and a signal handler may not allocate.
            if @@record_first && @@first_holder_base == 0
              @@first_holder_base = base
              @@first_holder_size = size
            end
          end
        end
        i &+= 1
      end
      yield reported
      hits
    end

    # The holder's first words, verbatim. `type_id` says *what* the holder is;
    # this says what state it was in, and for the fiber-creation UAF that is the
    # whole question — `Deque` is `type_id`, then three `Int32` (`@start`,
    # `@size`, `@capacity`) packed into two words, then `@buffer`. A `@capacity`
    # that matches the *freed* block and one that matches a newer, larger one are
    # different defects: the first is an owner that still believes it owns the
    # buffer, the second is a resize caught between `@capacity = capacity` and
    # the `@buffer` store that follows it — and Crystal's `resize_to_capacity`
    # writes them in exactly that order.
    private def self.dump_payload(base : UInt64, size : UInt64) : Nil
      words = size // sizeof(UInt64)
      words = DUMP_WORDS if words > DUMP_WORDS
      return if words == 0
      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry:   payload")
      i = 0_u64
      while i < words
        len = RawOut.append(buf.to_unsafe, len, " +")
        len = RawOut.append_u64(buf.to_unsafe, len, i &* sizeof(UInt64))
        len = RawOut.append(buf.to_unsafe, len, "=0x")
        len = RawOut.append_hex(buf.to_unsafe, len, Pointer(UInt64).new(base &+ i &* sizeof(UInt64)).value)
        i &+= 1
      end
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # Fiber stacks, and the faulting thread's live frames. A hit here means a
    # frame still holds the pointer, which is a different owner from a field in
    # an object and points at different code.
    #
    # And it asks the question that decides whose defect this is: **would the
    # collector have scanned that slot?** A parked fiber is scanned from its
    # `stack_top` down to `bottom`; a slot at a *lower* address than `stack_top`
    # is below the parked frame and outside the window, so a pointer living
    # there is a root gcry never sees — which is a missed root and gcry's to
    # fix. A slot inside the window is one the collector did see, and then the
    # question is why marking it did not keep the block alive. The report says
    # which, per holder, instead of leaving it to be worked out from addresses.
    #
    # The world is *not* stopped — this runs from a signal handler — so other
    # threads are mutating the stacks being read. Each page is probed with the
    # same `write(2)`/EFAULT test the collector's stack scan uses, so an unmapped
    # guard page is skipped rather than faulted on; a torn read is possible and
    # is the price of asking at all.
    private def self.search_stacks(heap : Heap, user : UInt64, finish : UInt64, tag : String) : UInt64
      sp = Roots.hardware_stack_pointer.address
      hits = 0_u64
      stacks = 0_u64
      reported = 0
      sp_covered = false

      Fiber.unsafe_each do |fiber|
        stack = fiber.@stack
        base = stack.pointer.address
        bottom = stack.bottom.address
        next unless base != 0 && bottom > base

        low = base &+ Roots::PAGE_SIZE
        next unless low < bottom
        # The faulting thread is running on one of these. Below its SP is dead
        # space that the last few calls left behind — including, quite often, a
        # copy of the very pointer that faulted, which would be reported as a
        # holder and is not one.
        if sp >= low && sp < bottom
          low = sp
          sp_covered = true
        end

        stacks &+= 1
        top = fiber.@context.stack_top.address
        h = scan_stack_range(low, bottom, user, finish, tag, fiber.object_id, top,
          fiber.running?, reported) { |r| reported = r }
        hits &+= h
      end

      # The main thread's stack is not a fiber stack when the fault lands on it
      # before any fiber has run, and an EC worker faulting inside libc can sit
      # on its pthread stack too. `stack_bottom` is what the collector scans.
      unless sp_covered
        bottom = heap.stack_bottom.address
        if bottom > sp && (bottom &- sp) <= Roots::MAX_SCAN_BYTES
          stacks &+= 1
          hits &+= scan_stack_range(sp, bottom, user, finish, tag, 0_u64, sp, true, reported) { |r| reported = r }
        end
      end

      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: ")
      len = RawOut.append(buf.to_unsafe, len, tag)
      len = RawOut.append(buf.to_unsafe, len, " — stacks: ")
      len = RawOut.append_u64(buf.to_unsafe, len, hits)
      len = RawOut.append(buf.to_unsafe, len, " word(s) across ")
      len = RawOut.append_u64(buf.to_unsafe, len, stacks)
      len = RawOut.append(buf.to_unsafe, len, " stack(s)\n")
      RawOut.flush(buf.to_unsafe, len)
      hits
    end

    # Word-walks `[low, high)` a readable page at a time. `Roots.scan_range`
    # would be the natural call and is not usable here: it yields the *value* of
    # each word and this report is about the *address* of the slot, which is the
    # only thing that can be compared against the collector's scan window.
    private def self.scan_stack_range(low : UInt64, high : UInt64, user : UInt64, finish : UInt64,
                                      tag : String, fiber_id : UInt64, stack_top : UInt64,
                                      running : Bool, reported : Int32, &) : UInt64
      hits = 0_u64
      word = sizeof(UInt64).to_u64
      lo = (low &+ word &- 1) & ~(word &- 1)
      hi = high & ~(word &- 1)
      return 0_u64 if lo >= hi
      return 0_u64 if (hi &- lo) > Roots::MAX_SCAN_BYTES

      page = lo & ~(Roots::PAGE_SIZE &- 1)
      while page < hi
        unless Roots.page_readable?(page)
          page &+= Roots::PAGE_SIZE
          next
        end
        start = lo > page ? lo : page
        stop = page &+ Roots::PAGE_SIZE
        stop = hi if stop > hi
        cursor = start
        while cursor < stop
          a = Pointer(UInt64).new(cursor).value
          if a >= user && a < finish
            hits &+= 1
            if reported < MAX_REPORTED
              reported += 1
              report_stack_hit(cursor, a, user, tag, fiber_id, stack_top, running)
            end
          end
          cursor &+= word
        end
        page &+= Roots::PAGE_SIZE
      end
      yield reported
      hits
    end

    private def self.report_stack_hit(slot : UInt64, value : UInt64, user : UInt64, tag : String,
                                      fiber_id : UInt64, stack_top : UInt64, running : Bool) : Nil
      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: ")
      len = RawOut.append(buf.to_unsafe, len, tag)
      len = RawOut.append(buf.to_unsafe, len, " — stack: ")
      if fiber_id == 0
        len = RawOut.append(buf.to_unsafe, len, "thread stack")
      else
        len = RawOut.append(buf.to_unsafe, len, "fiber 0x")
        len = RawOut.append_hex(buf.to_unsafe, len, fiber_id)
        len = RawOut.append(buf.to_unsafe, len, running ? " (running)" : " (parked)")
      end
      len = RawOut.append(buf.to_unsafe, len, " slot 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, slot)
      len = RawOut.append(buf.to_unsafe, len, " holds block+")
      len = RawOut.append_u64(buf.to_unsafe, len, value &- user)
      len = RawOut.append(buf.to_unsafe, len, ", stack_top 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, stack_top)
      # The verdict, and the reason this walk reports addresses at all. A parked
      # fiber is scanned `[stack_top, bottom)`; a slot below `stack_top` is dead
      # space to the collector and a live root to whoever wrote it.
      if fiber_id != 0 && !running
        len = RawOut.append(buf.to_unsafe, len, slot < stack_top ? " — BELOW stack_top, so the collector's parked-fiber scan never reads this slot\n" : " — inside the scanned window\n")
      else
        len = RawOut.append(buf.to_unsafe, len, "\n")
      end
      RawOut.flush(buf.to_unsafe, len)
    end
  end
end
