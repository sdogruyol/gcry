# EXPERIMENT — root every block for the collection that follows its birth.
#
# `bench/log/linux/2026-08-16-uaf-mark-complete/FINDINGS.md` bounded the
# fiber-creation use-after-free from both sides: the block is freed **by the
# sweep**, and at that sweep **no marked object pointed at it**
# (`GCRY_MARK_AUDIT=1`, zero missed edges in 15 runs). The live deque points at
# it only afterwards. The only ordering that fits is that the block died in the
# window between being handed out and being stored into an object — while it was
# live in a register or a stack slot and nowhere else.
#
# `GCRY_BIRTH_GRACE=1` closes exactly that window and nothing else: every
# pointer `allocate` returns is recorded, marked as an explicit root by the next
# collection, and dropped when that collection ends. A block therefore survives
# the first collection after its birth whether or not any root points at it.
#
# It is a **measurement, not a fix**. If the crash rate goes to zero the defect
# is ambient-root coverage of the allocating thread and the fix belongs in root
# discipline; if it does not, the block is dying for a reason that has nothing
# to do with reachability at all, and the allocator's own state is next. Either
# answer is worth the arm; neither justifies shipping this on.
#
# The ring is fixed-size and **counts what it drops**. The 2026-08-15 grace-list
# experiment had to rule out "the list simply overflowed" after the fact, at 512
# and 65 536 slots; this reports overflows instead, so a null result cannot be
# explained away by a silent cap.

module Gcry
  class Heap
    # `GCRY_BIRTH_GRACE=1`. See src/gcry/birth_grace.cr.
    getter? birth_grace : Bool = false

    BIRTH_GRACE_SLOTS = 1_u32 << 20

    @birth_slots : Void** = Pointer(Void*).null
    @birth_index = Atomic(UInt32).new(0_u32)
    getter birth_grace_overflows : UInt64 = 0_u64
    getter birth_grace_rooted : UInt64 = 0_u64
    getter birth_grace_saved : UInt64 = 0_u64

    # libc malloc, not the gcry heap: this runs inside `allocate`, and a ring
    # that allocates from the heap it is instrumenting would recurse.
    def birth_grace=(on : Bool) : Bool
      if on && @birth_slots.null?
        bytes = LibC::SizeT.new(BIRTH_GRACE_SLOTS.to_u64 * sizeof(Void*))
        slots = LibC.malloc(bytes)
        raise OutOfMemoryError.new("birth grace ring") if slots.null?
        @birth_slots = slots.as(Void**)
      end
      @birth_grace = on
    end

    # On the allocation hot path when armed. One atomic increment and one store;
    # the ring is never read outside a collection.
    @[AlwaysInline]
    protected def note_birth(user : Void*) : Nil
      return if user.null? || @birth_slots.null?
      i = @birth_index.add(1_u32)
      if i >= BIRTH_GRACE_SLOTS
        @birth_grace_overflows &+= 1
        return
      end
      @birth_slots[i] = user
    end

    # Called with the world stopped and **after** `mark_loop`, so a newborn
    # block the mark did not reach is distinguishable from one it did. Those are
    # the blocks this experiment exists to name: the collector was about to take
    # them, and nothing in the heap, the root set or a scanned stack said no.
    protected def mark_birth_grace_roots : Nil
      return if @birth_slots.null?
      n = @birth_index.get
      n = BIRTH_GRACE_SLOTS if n > BIRTH_GRACE_SLOTS
      saved = 0_u64
      i = 0_u32
      while i < n
        ptr = @birth_slots[i]
        i &+= 1
        next if ptr.null?
        header = find_block(ptr)
        next unless header
        next if BlockHeader.free?(header)
        unless heap_marked?(header)
          saved &+= 1
          if saved <= BIRTH_GRACE_REPORT_LIMIT
            report_birth_save(header, ptr)
            locate_birth_holder(ptr)
            locate_birth_register(ptr)
            probe_root_acceptance(ptr)
          end
        end
        mark_explicit_root(ptr)
      end
      @birth_grace_rooted &+= n.to_u64
      @birth_grace_saved &+= saved
    end

    BIRTH_GRACE_REPORT_LIMIT = 2

    # Where does the pointer to a block the mark could not reach actually live?
    #
    # This is the question the grace's own result opened. Something holds the
    # newborn `Fiber` — the mutator is mid-`Fiber#initialize` — so either the
    # value is on a fiber stack at an address the collector's scan window does
    # not cover, or it is only in a suspended thread's registers, or it is
    # nowhere gcry can see. Those are three different defects, and the collector
    # knows which while the world is still stopped.
    #
    # Reuses the collector's own `fiber_stack_scan_top`, so the verdict is
    # measured against the window the mark actually used this collection rather
    # than against a re-derivation of it.
    private def locate_birth_holder(user : Void*) : Nil
      addr = user.address
      stw_multi = @world_stopped && multi_mutator_threads?
      current = Fiber.current
      found = 0
      Fiber.unsafe_each do |fiber|
        break if found >= BIRTH_GRACE_REPORT_LIMIT
        stack = fiber.@stack
        base = stack.pointer.address
        bottom = stack.bottom.address
        next unless base != 0 && bottom > base
        guard = base &+ Roots::PAGE_SIZE
        next unless guard < bottom
        scan_top = fiber_stack_scan_top(fiber, guard, stw_multi)

        # Skip the collector's own frames on the fiber it was entered from:
        # this search's parameters live there, and finding itself would report
        # a holder that exists only because the search ran. Measured — before
        # this exclusion every hit was at the same slot, 1520 bytes above the
        # scan window's low bound, i.e. inside the collector's call chain.
        slot = guard
        if fiber == current && @collect_entry_sp > slot
          slot = @collect_entry_sp
        end
        while slot < bottom
          # Whole stack, not the scanned window — the point is to find hits the
          # window excludes. Pages below the low-water mark are untouched and
          # read as zero, so a blind walk is safe here in a way it is not in a
          # signal handler.
          if Pointer(UInt64).new(slot).value == addr
            report_birth_holder(fiber, slot, scan_top, bottom, fiber.running?,
              fiber == current, stw_multi)
            found += 1
            break
          end
          slot &+= sizeof(UInt64).to_u64
        end
      end
      return if found > 0

      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len,
        "gcry: birth grace — no live mutator frame holds it, so the value is in a register, spilled " \
        "into the collector's own frames, or in memory gcry does not scan\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # Not on a stack and not refused by a predicate leaves one place: a
    # suspended thread's registers. Those are scanned (v0.19.0 closed the two
    # platforms that returned nothing), so if the value is there and the block
    # is still unmarked, the register scan is the coverage gap — and if it is
    # *not* there either, the value is somewhere gcry has never looked.
    private def locate_birth_register(user : Void*) : Nil
      addr = user.address
      threads = 0_u64
      gregs = 0_u64
      hits = 0_u64
      Thread.unsafe_each do |thread|
        threads &+= 1
        Platform.each_thread_greg(thread.to_unsafe) do |value|
          gregs &+= 1
          hits &+= 1 if value.address == addr
        end
      end
      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: birth grace —   registers: ")
      len = RawOut.append_u64(buf.to_unsafe, len, hits)
      len = RawOut.append(buf.to_unsafe, len, " hit(s) across ")
      len = RawOut.append_u64(buf.to_unsafe, len, gregs)
      len = RawOut.append(buf.to_unsafe, len, " captured GP registers of ")
      len = RawOut.append_u64(buf.to_unsafe, len, threads)
      len = RawOut.append(buf.to_unsafe, len, " thread(s)")
      len = RawOut.append(buf.to_unsafe, len, gregs == 0 ? " — nothing was captured at all, so no thread's registers were scanned this collection\n" : (hits == 0 ? " — not in any register either\n" : " — the value is in a register\n"))
      RawOut.flush(buf.to_unsafe, len)
    end

    # Would the mark have taken this address if a stack scan had handed it over?
    #
    # The stack archaeology cannot separate "the slot was never read" from "it
    # was read and refused", because a value the mutator held in a callee-saved
    # register is spilled into the collector's *own* frames — the same region
    # this search occupies. So ask the mark instead: run its ambient-root
    # acceptance on the address and see whether the block ends up marked. This
    # is the collector's real predicate, not a re-derivation of it.
    private def probe_root_acceptance(user : Void*) : Nil
      header = find_block(user)
      return unless header
      accepted = false
      unless heap_marked?(header)
        mark_root_candidate(user, source: RootSource::Stack)
        accepted = heap_marked?(header)
      end
      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: birth grace —   mark_root_candidate ")
      len = RawOut.append(buf.to_unsafe, len, accepted ? "ACCEPTS this address, so nothing ever handed it over — a scan-coverage gap\n" : "REFUSES this address, so a root predicate rejected it — a filter, not coverage\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    private def report_birth_holder(fiber : Fiber, slot : UInt64, scan_top : UInt64,
                                    bottom : UInt64, running : Bool,
                                    is_current : Bool, stw_multi : Bool) : Nil
      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: birth grace —   held by fiber 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, fiber.object_id)
      len = RawOut.append(buf.to_unsafe, len, running ? " (running" : " (parked")
      len = RawOut.append(buf.to_unsafe, len, is_current ? ", CURRENT" : "")
      len = RawOut.append(buf.to_unsafe, len, stw_multi ? ", stw_multi)" : ", single)")
      len = RawOut.append(buf.to_unsafe, len, " at slot 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, slot)
      len = RawOut.append(buf.to_unsafe, len, ", the mark scanned [0x")
      len = RawOut.append_hex(buf.to_unsafe, len, scan_top)
      len = RawOut.append(buf.to_unsafe, len, ", 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, bottom)
      len = RawOut.append(buf.to_unsafe, len, ") — ")
      mut_lo = Roots.last_mutator_low
      mut_hi = Roots.last_mutator_high
      verdict = if is_current
                  if mut_lo == 0
                    "the CURRENT fiber, and scan_mutator did not run this collection at all\n"
                  elsif slot >= mut_lo && slot < mut_hi
                    "the CURRENT fiber, and the slot IS inside scan_mutator's window — read and rejected\n"
                  else
                    "the CURRENT fiber, and the slot is OUTSIDE scan_mutator's window — never read\n"
                  end
                elsif running && !stw_multi
                  "a running fiber outside multi-mutator STW, which scan_all_fiber_roots skips entirely\n"
                elsif slot < scan_top
                  "BELOW the window, so this slot was never read\n"
                else
                  "inside the window, so the slot was read and the value rejected\n"
                end
      len = RawOut.append(buf.to_unsafe, len, verdict)
      RawOut.flush(buf.to_unsafe, len)
      if is_current
        len = 0
        len = RawOut.append(buf.to_unsafe, len, "gcry: birth grace —   scan_mutator window [0x")
        len = RawOut.append_hex(buf.to_unsafe, len, mut_lo)
        len = RawOut.append(buf.to_unsafe, len, ", 0x")
        len = RawOut.append_hex(buf.to_unsafe, len, mut_hi)
        len = RawOut.append(buf.to_unsafe, len, "), slot 0x")
        len = RawOut.append_hex(buf.to_unsafe, len, slot)
        len = RawOut.append(buf.to_unsafe, len, "\n")
        RawOut.flush(buf.to_unsafe, len)
      end
    end

    private def report_birth_save(header : BlockHeader*, user : Void*) : Nil
      buf = uninitialized UInt8[512]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: birth grace — block 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, user.address)
      len = RawOut.append(buf.to_unsafe, len, " size ")
      len = RawOut.append_u64(buf.to_unsafe, len, header.value.size.to_u64)
      len = RawOut.append(buf.to_unsafe, len, " first word 0x")
      len = RawOut.append_hex(buf.to_unsafe, len,
        header.value.size >= 8 ? user.as(UInt64*).value : 0_u64)
      len = RawOut.append(buf.to_unsafe, len,
        " was born this cycle and the mark did not reach it — the sweep would have taken it. collection ")
      len = RawOut.append_u64(buf.to_unsafe, len, @collections)
      len = RawOut.append(buf.to_unsafe, len, "\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # The grace is one collection long: whatever was born before this collection
    # has now been seen by it, and if nothing else points at those blocks the
    # *next* collection is entitled to take them.
    protected def reset_birth_grace : Nil
      return if @birth_slots.null?
      @birth_index.set(0_u32)
    end
  end
end
