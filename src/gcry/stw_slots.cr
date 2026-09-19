# The stop-the-world capture table: one slot per suspended thread, holding its
# SP and its general-purpose registers until the mark is done with them.
#
# **Why this is not in the platform files.** It used to be, three times over —
# `linux_stw.cr`, `darwin_stw.cr` and `windows_stw.cr` each had the same
# `@@stw_ids` / `@@stw_sps` / `@@stw_gregs` / claim-mask quartet with the same
# 64-slot bound. A first attempt at growing the Darwin and Windows copies
# crashed the Darwin job with an invalid memory access and had to be reverted,
# and the reason it could not be debugged is that the code was reachable only
# from a platform nobody here can run
# (`bench/log/linux/2026-09-17-darwin-64-thread-cliff/HALF2-REVERT.md`). Here it
# compiles and runs everywhere, so `spec/stw_slots_spec.cr` exercises the
# growth, the claiming and the refusals on whatever platform the suite runs on.
#
# **The 64 was the claim mask.** `@@stw_claimed` was an `Atomic(UInt64)`, and a
# `UInt64` cannot address a 65th slot. Past it `slot_for` returned −1 and the
# thread was suspended with no SP clamp and no registers captured. The SP half
# of that is conservative — `scan_pthread_stack` with no SP walks the whole
# stack — but the registers are not: on Darwin `thread_get_state` is their only
# copy, so a reference held only in the 65th thread's registers stopped being a
# root. (Linux is the exception and keeps its own fixed table: its registers
# arrive in a signal `ucontext` that sits on the interrupted thread's own stack,
# which the unclamped walk covers, and its table is claimed from the suspend
# handler on every thread at once.)
#
# **Three rules make it safe to grow under a reader.**
#
# 1. **One allocation, one pointer.** Capacity and every array live in a single
#    `LibC.malloc` block, published by a single store. A reader loads that
#    pointer once and gets a consistent view; it can never pair a new capacity
#    with an old base, which is the tearing the reverted attempt had.
# 2. **Never freed.** Growth leaks its predecessor, so a reader still inside the
#    old block reads valid — if stale — memory instead of faulting. Doubling
#    bounds the leak by the final size: 64 → 128 → 256 sums to less than 512
#    slots' worth. `make stw-slots-grow-race` is the gate for this one.
# 3. **Grown outside the stop.** Callers size the table before they suspend
#    anyone. `malloc` with the world stopped is the 2026-08-10 six-hour hang.
#
# **A `Table` is a value, and the collector owns exactly one.** That is not
# tidiness either. The first version was one module of class variables, and
# `spec/stw_slots_spec.cr` reconfigured it — which on Linux touches nothing,
# because this platform keeps its own table, and on Windows reconfigured the
# table the collector was *using*: 4 register words per slot instead of 80, so
# the next capture dropped 76 of every thread's 80 register roots, and an
# example that fills the table to test the refusal made a real thread's claim
# fail. The suite wedged there and took the job's whole 20-minute budget (run
# `35369782659`, all six Windows jobs). Specs and gates now build their own
# `Table`; the collector's lives in `@@process` and nothing else can reach it.
#
# Ids are stored as `UInt64` and compared by value. That is what
# `pthread_equal` does on both platforms that use this — Darwin's `pthread_t` is
# an opaque pointer, Linux's an `unsigned long` — and Windows' `HANDLE`
# comparison was already a value comparison.
module Gcry::StwSlots
  # Where the table starts, and what `GCRY_STW_FIXED_SLOTS=1` pins it to: the
  # bound that shipped.
  INITIAL_SLOTS = 64

  # Layout of the block, in bytes from its base. Every 8-byte-wide array comes
  # first, so nothing needs padding.
  #
  #   [0]  capacity   : Int64
  #   [8]  ids        : UInt64 * cap
  #        sps        : UInt64 * cap
  #        gregs      : UInt64 * cap * greg_words
  #        served     : UInt64 * cap   — the stop epoch this slot has answered
  #        last_ids   : UInt64 * cap   — the previous stop, retained
  #        last_sps   : UInt64 * cap
  #        claimed    : UInt8  * cap
  #        greg_count : UInt8  * cap   — words captured, not a flag
  #        acked      : UInt8  * cap
  #        last_held  : UInt8  * cap
  HEADER_BYTES = 8

  # A capture table. A `struct` with nothing but scalars and one `malloc`ed
  # block, so the collector's copy can live in a class variable that `GC.init`
  # touches and a spec's copy can live on the stack, with no allocation and no
  # lazy initialization anywhere near either.
  struct Table
    getter greg_words : Int32
    # Slot claims that found the table full: the allocator refused a bigger
    # block, or the table is pinned. Cumulative, and expected to stay zero.
    getter no_slot : UInt64

    def initialize
      @block = Pointer(UInt8).null
      @greg_words = 0
      @no_slot = 0_u64
      @pinned = false
      @free_old = false
    end

    # *greg_words* is the number of 64-bit words a thread's register row needs,
    # which is a per-platform, per-architecture constant.
    def configure(greg_words : Int32) : Nil
      @greg_words = greg_words < 1 ? 1 : greg_words
      reserve(INITIAL_SLOTS)
    end

    def configured? : Bool
      !@block.null?
    end

    def capacity : Int32
      b = @block
      b.null? ? 0 : b.as(Int64*).value.to_i32
    end

    # `GCRY_STW_FIXED_SLOTS=1`. Reading it back is what lets a harness say
    # whether a zero `no_slot` means "covered" or "never grew".
    def pinned=(value : Bool) : Bool
      @pinned = value
    end

    def pinned? : Bool
      @pinned
    end

    # Research only, and the red arm of `make stw-slots-grow-race`: free the
    # predecessor when the table grows. That is rule 2 inverted — a reader that
    # has already loaded the old pointer is then walking freed memory — and it
    # is the one property of this design that no serial test can show.
    def free_old=(on : Bool) : Bool
      @free_old = on
    end

    # Grows to at least *want* slots, doubling. False when the allocator
    # refuses, leaving the previous table in place — the caller does **not**
    # fail the collection for that. It captures what fits and `no_slot` counts
    # the rest, which is the trade the other direction cost Windows every
    # collection past 64 threads.
    def reserve(want : Int32) : Bool
      return true if @pinned && configured?
      have = capacity
      return true if want <= have
      return false if @greg_words == 0

      cap = have < INITIAL_SLOTS ? INITIAL_SLOTS : have
      while cap < want
        cap *= 2
      end

      bytes = block_bytes(cap)
      fresh = LibC.malloc(LibC::SizeT.new(bytes))
      return false if fresh.null?

      base = fresh.as(UInt8*)
      # Zeroed whole: the claim and greg-ok flags must start clear, and a
      # captured word left behind in fresh memory would be scanned as a root.
      base.clear(bytes)
      base.as(Int64*).value = cap.to_i64

      # The predecessor is deliberately not freed — see rule 2 above.
      # Publishing last is rule 1: nothing reads the new block until this store
      # lands, and nothing that has read the old pointer can be hurt by it.
      old = @block
      @block = base
      LibC.free(old.as(Void*)) if @free_old && !old.null?
      true
    end

    # Per-STW. Clears the claims, the SPs and the register rows; the ids are
    # left, because a slot is only ever read through a claimed one.
    def clear : Nil
      b = @block
      return if b.null?
      cap = b.as(Int64*).value.to_i32
      claimed_at(b, cap).clear(cap.to_u64)
      greg_count_at(b, cap).clear(cap.to_u64)
      acked_at(b, cap).clear(cap.to_u64)
      sps_at(b, cap).clear(cap.to_u64)
      served_at(b, cap).clear(cap.to_u64)
      gregs_at(b, cap).clear(cap.to_u64 * @greg_words.to_u64)
    end

    # Clears the stop, keeping a copy of what it read.
    #
    # The live table has to read zero before the next stop claims slots in it,
    # and a release-time diagnostic needs the opposite: a word pointing at a
    # released block matters only if it sits in `[the SP that thread was
    # stopped at, its stack bottom)`, and every other hit is dead stack space
    # the collector is right to ignore. So the ids and SPs are copied into the
    # retained pair first, and `last_sp` answers from there through the
    # post-STW section.
    #
    # The ids are cleared with the claims, not just the claims: the claim is
    # published before the id, so a slot left carrying a stale id is one another
    # thread can match on — which cost a clobbered SP and register row before
    # the stop epoch and a hang after it.
    def retire_stop : Nil
      b = @block
      return if b.null?
      cap = b.as(Int64*).value.to_i32
      ids = ids_at(b)
      sps = sps_at(b, cap)
      claimed = claimed_at(b, cap)
      last_ids = last_ids_at(b, cap)
      last_sps = last_sps_at(b, cap)
      last_held = last_held_at(b, cap)
      i = 0
      while i < cap
        last_ids[i] = ids[i]
        last_sps[i] = sps[i]
        last_held[i] = claimed[i]
        i += 1
      end
      ids.clear(cap.to_u64)
      clear
    end

    # Forgets everything, the retained copy included. For `fork`: the child
    # inherits the parent's claims and `pthread_t` values, and the only thread
    # that could have answered for them does not exist here.
    def forget : Nil
      b = @block
      return if b.null?
      cap = b.as(Int64*).value.to_i32
      ids_at(b).clear(cap.to_u64)
      last_ids_at(b, cap).clear(cap.to_u64)
      last_sps_at(b, cap).clear(cap.to_u64)
      last_held_at(b, cap).clear(cap.to_u64)
      clear
    end

    # Drops this slot's registers without touching its claim: what the
    # collector does when it reserves a slot for a stop, so a thread that is
    # never suspended cannot be scanned from the last stop's reading.
    def clear_gregs(slot : Int32) : Nil
      b = @block
      return if b.null? || slot < 0
      cap = b.as(Int64*).value.to_i32
      return if slot >= cap
      greg_count_at(b, cap)[slot] = 0_u8
    end

    # The SP *id* was stopped at during the most recent retired stop, or 0.
    def last_sp(id : UInt64) : UInt64
      b = @block
      return 0_u64 if b.null?
      cap = b.as(Int64*).value.to_i32
      last_ids = last_ids_at(b, cap)
      last_held = last_held_at(b, cap)
      i = 0
      while i < cap
        return last_sps_at(b, cap)[i] if last_held[i] != 0 && last_ids[i] == id
        i += 1
      end
      0_u64
    end

    # The claim is a CAS, and on one of the three platforms that is not
    # decoration. Darwin and Windows claim only from the collector, one thread
    # at a time; Linux claims from the collector too — `reserve_suspend_slot`,
    # under `Thread.lock`, before the first suspend signal — but its **suspend
    # handler** keeps a fallback claim for a thread that appeared after that
    # loop, and those run on every thread at once. A plain store there gives two
    # threads one slot, which cost a clobbered SP and register row before the
    # stop epoch existed and a hang after it, because the winner's served stamp
    # sat under the loser's index.
    #
    # The id is published **after** the claim, and released slots have their id
    # cleared (`release_slot`), for the same reason in the other direction: a
    # peer scanning for its own id must not match a slot that is claimed and
    # still carries whatever was in it before.
    def slot_for(id : UInt64) : Int32
      b = @block
      return note_no_slot if b.null?
      cap = b.as(Int64*).value.to_i32
      ids = ids_at(b)
      claimed = claimed_at(b, cap)

      i = 0
      while i < cap
        return i if claimed[i] != 0 && ids[i] == id
        i += 1
      end

      i = 0
      while i < cap
        if claimed[i] == 0
          _, won = Atomic::Ops.cmpxchg(claimed + i, 0_u8, 1_u8,
            :sequentially_consistent, :monotonic)
          if won
            ids[i] = id
            reset_slot(b, cap, i)
            return i
          end
          # Someone else took it between the read and the exchange; look again
          # from here rather than trusting the stale scan.
          next
        end
        i += 1
      end

      note_no_slot
    end

    # The slot *id* already holds, or -1. Never claims — this is what a suspend
    # handler and the collector's wait loop use, and neither may grow anything.
    def slot_of(id : UInt64) : Int32
      b = @block
      return -1 if b.null?
      cap = b.as(Int64*).value.to_i32
      ids = ids_at(b)
      claimed = claimed_at(b, cap)
      i = 0
      while i < cap
        return i if claimed[i] != 0 && ids[i] == id
        i += 1
      end
      -1
    end

    # A fresh claim starts with no SP, no registers, no served epoch and no
    # acknowledgement. A slot held over from the last stop would otherwise let
    # its new owner inherit the predecessor's epoch — declining the signal meant
    # for it — or an acknowledgement it never gave.
    private def reset_slot(b : UInt8*, cap : Int32, slot : Int32) : Nil
      sps_at(b, cap)[slot] = 0_u64
      served_at(b, cap)[slot] = 0_u64
      greg_count_at(b, cap)[slot] = 0_u8
      acked_at(b, cap)[slot] = 0_u8
    end

    # Drops the claim **and** the id. Both, always: the claim is published
    # before the id, so a slot that keeps a stale id while unclaimed is a slot
    # another thread can match on.
    def release_slot(slot : Int32) : Nil
      b = @block
      return if b.null? || slot < 0
      cap = b.as(Int64*).value.to_i32
      return if slot >= cap
      ids_at(b)[slot] = 0_u64
      reset_slot(b, cap, slot)
      Atomic::Ops.store(claimed_at(b, cap) + slot, 0_u8, :release, false)
    end

    # ── The stop epoch, per slot (Linux) ─────────────────────────────────────
    #
    # A suspend signal is only honoured for the stop that asked for it, and the
    # state that decides it is per-thread: two threads can be at different
    # points of the same stop. It rides here because this table is already
    # keyed by thread id and already exists before the first signal goes out.
    def served(slot : Int32) : UInt64
      b = @block
      return 0_u64 if b.null? || slot < 0
      cap = b.as(Int64*).value.to_i32
      return 0_u64 if slot >= cap
      served_at(b, cap)[slot]
    end

    def set_served(slot : Int32, epoch : UInt64) : Nil
      b = @block
      return if b.null? || slot < 0
      cap = b.as(Int64*).value.to_i32
      return if slot >= cap
      served_at(b, cap)[slot] = epoch
    end

    # The acknowledgement, and it lives here rather than in `Thread#@suspended`
    # because the handler must not touch Crystal at all: a thread signalled
    # between `Thread.threads.push(self)` and `Thread.current = self` has no
    # TLS, and Crystal's accessor **creates** one — allocating a `Fiber`, a
    # `Thread`, and taking the list mutex the collector holds for the whole
    # stop. One plain byte instead.
    def acked?(slot : Int32) : Bool
      b = @block
      return false if b.null? || slot < 0
      cap = b.as(Int64*).value.to_i32
      return false if slot >= cap
      acked_at(b, cap)[slot] != 0
    end

    def set_acked(slot : Int32, value : Bool) : Nil
      b = @block
      return if b.null? || slot < 0
      cap = b.as(Int64*).value.to_i32
      return if slot >= cap
      acked_at(b, cap)[slot] = value ? 1_u8 : 0_u8
    end

    def record_sp(slot : Int32, sp : UInt64) : Nil
      b = @block
      return if b.null? || slot < 0
      cap = b.as(Int64*).value.to_i32
      return if slot >= cap
      sps_at(b, cap)[slot] = sp
    end

    # *src* is the raw thread-state buffer; *words* words are copied into the
    # slot's row, capped by the configured width.
    def record_gregs(slot : Int32, src : UInt64*, words : Int32) : Nil
      b = @block
      return if b.null? || slot < 0
      cap = b.as(Int64*).value.to_i32
      return if slot >= cap

      n = words < @greg_words ? words : @greg_words
      row = gregs_at(b, cap) + slot.to_u64 * @greg_words.to_u64
      j = 0
      while j < n
        row[j] = src[j]
        j += 1
      end
      # The **count**, not a flag. Linux's `with_thread_gregs` hands the raw row
      # and its length to `StackMaps`, which resolves DWARF register locations
      # by index, so "how many words are real" has to survive the write. A count
      # of zero is the old `greg_ok == 0`.
      greg_count_at(b, cap)[slot] = n > 255 ? 255_u8 : n.to_u8
    end

    # The raw register row for *id* and how many words of it were captured, or
    # nil when this slot holds none. Index-preserving on purpose: a caller
    # resolving a DWARF register number cannot use a filtered view.
    def greg_row(id : UInt64) : Tuple(UInt64*, Int32)?
      b = @block
      return nil if b.null?
      cap = b.as(Int64*).value.to_i32
      slot = slot_of(id)
      return nil if slot < 0
      n = greg_count_at(b, cap)[slot].to_i32
      return nil if n <= 0
      {gregs_at(b, cap) + slot.to_u64 * @greg_words.to_u64, n}
    end

    # The SP captured for *id* this STW, or zero when it has no slot or no SP.
    def sp(id : UInt64) : UInt64
      b = @block
      return 0_u64 if b.null?
      cap = b.as(Int64*).value.to_i32
      ids = ids_at(b)
      claimed = claimed_at(b, cap)
      i = 0
      while i < cap
        return sps_at(b, cap)[i] if claimed[i] != 0 && ids[i] == id
        i += 1
      end
      0_u64
    end

    # Register words captured for *id*. Yields nothing when the slot was never
    # filled this STW: a stale row must not be marked, and an unfilled one must
    # not read as "no roots".
    def each_greg(id : UInt64, & : UInt64 ->) : Nil
      b = @block
      return if b.null?
      cap = b.as(Int64*).value.to_i32
      ids = ids_at(b)
      claimed = claimed_at(b, cap)
      i = 0
      while i < cap
        if claimed[i] != 0 && ids[i] == id
          n = greg_count_at(b, cap)[i].to_i32
          return if n <= 0
          row = gregs_at(b, cap) + i.to_u64 * @greg_words.to_u64
          j = 0
          while j < n
            word = row[j]
            yield word unless word == 0
            j += 1
          end
          return
        end
        i += 1
      end
    end

    private def note_no_slot : Int32
      @no_slot &+= 1
      -1
    end

    private def block_bytes(cap : Int32) : UInt64
      c = cap.to_u64
      HEADER_BYTES.to_u64 +
        c * 8 +                      # ids
        c * 8 +                      # sps
        c * @greg_words.to_u64 * 8 + # gregs
        c * 8 +                      # served
        c * 8 +                      # last_ids
        c * 8 +                      # last_sps
        c +                          # claimed
        c +                          # greg_count
        c +                          # acked
        c                            # last_held
    end

    private def ids_at(b : UInt8*) : UInt64*
      (b + HEADER_BYTES).as(UInt64*)
    end

    private def sps_at(b : UInt8*, cap : Int32) : UInt64*
      (b + HEADER_BYTES + cap.to_u64 * 8).as(UInt64*)
    end

    private def gregs_at(b : UInt8*, cap : Int32) : UInt64*
      (b + HEADER_BYTES + cap.to_u64 * 16).as(UInt64*)
    end

    private def words_end(cap : Int32) : UInt64
      HEADER_BYTES.to_u64 + cap.to_u64 * 16 + cap.to_u64 * @greg_words.to_u64 * 8
    end

    private def served_at(b : UInt8*, cap : Int32) : UInt64*
      (b + words_end(cap)).as(UInt64*)
    end

    private def last_ids_at(b : UInt8*, cap : Int32) : UInt64*
      (b + words_end(cap) + cap.to_u64 * 8).as(UInt64*)
    end

    private def last_sps_at(b : UInt8*, cap : Int32) : UInt64*
      (b + words_end(cap) + cap.to_u64 * 16).as(UInt64*)
    end

    private def claimed_at(b : UInt8*, cap : Int32) : UInt8*
      b + words_end(cap) + cap.to_u64 * 24
    end

    private def greg_count_at(b : UInt8*, cap : Int32) : UInt8*
      claimed_at(b, cap) + cap.to_u64
    end

    private def acked_at(b : UInt8*, cap : Int32) : UInt8*
      claimed_at(b, cap) + cap.to_u64 * 2
    end

    private def last_held_at(b : UInt8*, cap : Int32) : UInt8*
      claimed_at(b, cap) + cap.to_u64 * 3
    end
  end

  # The collector's one table, and `@@booted` is the only thing read before it
  # exists. `uninitialized` with a plain `Bool` gate is not a style choice: a
  # class variable **with an initializer** is set up lazily behind
  # `Crystal.once`, and the first read of this one is inside `GC.init` —
  # Darwin's `install_stw_sp_capture` boots the table there, before
  # `Crystal.main` has set up the once machinery. Written the obvious way,
  # every `-Dgc_none` binary on that platform died at startup before printing
  # anything, which the `crystal` driver reports as "Process terminated because
  # of an invalid memory access" — the message that cost this change two
  # reverts and eight probe rounds. `linux_stw.cr` carries the same rule.
  @@process = uninitialized Table
  @@booted = false

  def self.configure(greg_words : Int32) : Nil
    unless @@booted
      @@process = Table.new
      @@booted = true
    end
    @@process.configure(greg_words)
  end

  def self.configured? : Bool
    @@booted && @@process.configured?
  end

  def self.capacity : Int32
    @@booted ? @@process.capacity : 0
  end

  def self.no_slot : UInt64
    @@booted ? @@process.no_slot : 0_u64
  end

  def self.pinned=(value : Bool) : Bool
    return false unless @@booted
    @@process.pinned = value
  end

  def self.pinned? : Bool
    @@booted && @@process.pinned?
  end

  def self.reserve(want : Int32) : Bool
    return false unless @@booted
    @@process.reserve(want)
  end

  def self.clear : Nil
    @@process.clear if @@booted
  end

  def self.slot_for(id : UInt64) : Int32
    return -1 unless @@booted
    @@process.slot_for(id)
  end

  def self.record_sp(slot : Int32, sp : UInt64) : Nil
    @@process.record_sp(slot, sp) if @@booted
  end

  def self.record_gregs(slot : Int32, src : UInt64*, words : Int32) : Nil
    @@process.record_gregs(slot, src, words) if @@booted
  end

  def self.sp(id : UInt64) : UInt64
    @@booted ? @@process.sp(id) : 0_u64
  end

  def self.each_greg(id : UInt64, & : UInt64 ->) : Nil
    return unless @@booted
    @@process.each_greg(id) { |word| yield word }
  end

  def self.slot_of(id : UInt64) : Int32
    @@booted ? @@process.slot_of(id) : -1
  end

  def self.release_slot(slot : Int32) : Nil
    @@process.release_slot(slot) if @@booted
  end

  def self.served(slot : Int32) : UInt64
    @@booted ? @@process.served(slot) : 0_u64
  end

  def self.set_served(slot : Int32, epoch : UInt64) : Nil
    @@process.set_served(slot, epoch) if @@booted
  end

  def self.acked?(slot : Int32) : Bool
    @@booted && @@process.acked?(slot)
  end

  def self.set_acked(slot : Int32, value : Bool) : Nil
    @@process.set_acked(slot, value) if @@booted
  end

  def self.greg_row(id : UInt64) : Tuple(UInt64*, Int32)?
    @@booted ? @@process.greg_row(id) : nil
  end

  def self.retire_stop : Nil
    @@process.retire_stop if @@booted
  end

  def self.last_sp(id : UInt64) : UInt64
    @@booted ? @@process.last_sp(id) : 0_u64
  end

  def self.forget : Nil
    @@process.forget if @@booted
  end

  def self.clear_gregs(slot : Int32) : Nil
    @@process.clear_gregs(slot) if @@booted
  end
end
