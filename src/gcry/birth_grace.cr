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
          report_birth_save(header, ptr) if saved <= BIRTH_GRACE_REPORT_LIMIT
        end
        mark_explicit_root(ptr)
      end
      @birth_grace_rooted &+= n.to_u64
      @birth_grace_saved &+= saved
    end

    BIRTH_GRACE_REPORT_LIMIT = 2

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
