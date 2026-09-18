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
# (`bench/log/linux/2026-09-17-darwin-64-thread-cliff/HALF2-REVERT.md`). This
# module compiles and runs everywhere, so `spec/stw_slots_spec.cr` exercises the
# growth, the claiming and — the part that crashed — a reader running while the
# table grows, on whatever platform the suite happens to run on.
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
#    slots' worth.
# 3. **Grown outside the stop.** Callers size the table before they suspend
#    anyone. `malloc` with the world stopped is the 2026-08-10 six-hour hang.
#
# Ids are stored as `UInt64` and compared by value. That is what
# `pthread_equal` does on both platforms that use this — Darwin's `pthread_t` is
# an opaque pointer, Linux's an `unsigned long` — and Windows' `HANDLE`
# comparison was already a value comparison.
module Gcry::StwSlots
  # Where the table starts, and what `GCRY_STW_FIXED_SLOTS=1` pins it to: the
  # bound that shipped.
  INITIAL_SLOTS = 64

  # Layout of the block, in bytes from its base. Everything up to the two flag
  # arrays is 8-byte wide, so nothing needs padding.
  #
  #   [0]  capacity : Int64
  #   [8]  ids      : UInt64 * cap
  #        sps      : UInt64 * cap
  #        gregs    : UInt64 * cap * greg_words
  #        claimed  : UInt8  * cap
  #        greg_ok  : UInt8  * cap
  HEADER_BYTES = 8

  # `uninitialized`, with a plain `Bool` as the gate, and that is not a style
  # choice. A class variable **with an initializer** is set up lazily behind
  # `Crystal.once`, and the first read of these is inside `GC.init` — Darwin's
  # `install_stw_sp_capture` boots the table there, before `Crystal.main` has
  # set up the once machinery. Written the obvious way, every `-Dgc_none` binary
  # on that platform died at startup before printing anything, which the
  # `crystal` driver reports as "Process terminated because of an invalid memory
  # access" — the message that cost this change two reverts and eight probe
  # rounds (`bench/log/linux/2026-09-17-darwin-64-thread-cliff/HALF2-REVERT.md`).
  # `linux_stw.cr` carries the same rule for the same reason.
  @@table = uninitialized UInt8*
  @@greg_words = uninitialized Int32
  # Slot claims that found the table full: the allocator refused a bigger block,
  # or the table is pinned. Cumulative, and expected to stay zero.
  @@no_slot = uninitialized UInt64
  @@pinned = uninitialized Bool
  # A plain literal, like `linux_stw.cr`'s `@@stw_booted`: nothing above may be
  # read before `configure` has run, and this is what says whether it has.
  @@booted = false

  # *greg_words* is the number of 64-bit words a thread's register row needs,
  # which is a per-platform, per-architecture constant.
  def self.configure(greg_words : Int32) : Nil
    # Defaults first, and every one of them: with `uninitialized` declarations
    # these hold whatever was in that memory until this runs.
    unless @@booted
      @@table = Pointer(UInt8).null
      @@no_slot = 0_u64
      @@pinned = false
      @@booted = true
    end
    @@greg_words = greg_words < 1 ? 1 : greg_words
    reserve(INITIAL_SLOTS)
  end

  def self.configured? : Bool
    @@booted && !@@table.null?
  end

  def self.capacity : Int32
    return 0 unless @@booted
    t = @@table
    t.null? ? 0 : t.as(Int64*).value.to_i32
  end

  def self.no_slot : UInt64
    @@booted ? @@no_slot : 0_u64
  end

  # `GCRY_STW_FIXED_SLOTS=1`. Reading it back is what lets a harness say whether
  # a zero `no_slot` means "covered" or "never grew".
  def self.pinned=(value : Bool) : Bool
    return false unless @@booted
    @@pinned = value
  end

  def self.pinned? : Bool
    @@booted && @@pinned
  end

  # Grows to at least *want* slots, doubling. False when the allocator refuses,
  # leaving the previous table in place — the caller does **not** fail the
  # collection for that. It captures what fits and `no_slot` counts the rest,
  # which is the trade the other direction cost Windows every collection past
  # 64 threads.
  def self.reserve(want : Int32) : Bool
    return false unless @@booted
    return true if @@pinned && configured?
    have = capacity
    return true if want <= have
    return false if @@greg_words == 0

    cap = have < INITIAL_SLOTS ? INITIAL_SLOTS : have
    while cap < want
      cap *= 2
    end

    bytes = block_bytes(cap)
    fresh = LibC.malloc(LibC::SizeT.new(bytes))
    return false if fresh.null?

    base = fresh.as(UInt8*)
    # Zeroed whole: the claim and greg-ok flags must start clear, and a captured
    # word left behind in fresh memory would be scanned as a root.
    base.clear(bytes)
    base.as(Int64*).value = cap.to_i64

    # The predecessor is deliberately not freed — see rule 2 above. Publishing
    # last is rule 1: nothing reads the new block until this store lands, and
    # nothing that has read the old pointer can be hurt by it.
    @@table = base
    true
  end

  # Per-STW. Clears the claims, the SPs and the register rows; the ids are left,
  # because a slot is only ever read through a claimed one.
  def self.clear : Nil
    return unless @@booted
    t = @@table
    return if t.null?
    cap = t.as(Int64*).value.to_i32
    claimed_at(t, cap).clear(cap.to_u64)
    greg_ok_at(t, cap).clear(cap.to_u64)
    sps_at(t, cap).clear(cap.to_u64)
    gregs_at(t, cap).clear(cap.to_u64 * @@greg_words.to_u64)
  end

  # Only the collector calls this, from its own suspend loop, one thread at a
  # time — which is why there is no CAS here. Linux is the platform whose
  # handler claims from every thread at once, and it keeps its own table.
  def self.slot_for(id : UInt64) : Int32
    return -1 unless @@booted
    t = @@table
    return note_no_slot if t.null?
    cap = t.as(Int64*).value.to_i32
    ids = ids_at(t)
    claimed = claimed_at(t, cap)

    i = 0
    while i < cap
      return i if claimed[i] != 0 && ids[i] == id
      i += 1
    end

    i = 0
    while i < cap
      if claimed[i] == 0
        claimed[i] = 1_u8
        ids[i] = id
        sps_at(t, cap)[i] = 0_u64
        greg_ok_at(t, cap)[i] = 0_u8
        return i
      end
      i += 1
    end

    note_no_slot
  end

  def self.record_sp(slot : Int32, sp : UInt64) : Nil
    return unless @@booted
    t = @@table
    return if t.null? || slot < 0
    cap = t.as(Int64*).value.to_i32
    return if slot >= cap
    sps_at(t, cap)[slot] = sp
  end

  # *src* is the raw thread-state buffer; *words* words are copied into the
  # slot's row, capped by the configured width.
  def self.record_gregs(slot : Int32, src : UInt64*, words : Int32) : Nil
    return unless @@booted
    t = @@table
    return if t.null? || slot < 0
    cap = t.as(Int64*).value.to_i32
    return if slot >= cap

    n = words < @@greg_words ? words : @@greg_words
    row = gregs_at(t, cap) + slot.to_u64 * @@greg_words.to_u64
    j = 0
    while j < n
      row[j] = src[j]
      j += 1
    end
    greg_ok_at(t, cap)[slot] = 1_u8
  end

  # The SP captured for *id* this STW, or nil when it has no slot or no SP.
  def self.sp(id : UInt64) : UInt64
    return 0_u64 unless @@booted
    t = @@table
    return 0_u64 if t.null?
    cap = t.as(Int64*).value.to_i32
    ids = ids_at(t)
    claimed = claimed_at(t, cap)
    i = 0
    while i < cap
      return sps_at(t, cap)[i] if claimed[i] != 0 && ids[i] == id
      i += 1
    end
    0_u64
  end

  # Register words captured for *id*. Yields nothing when the slot was never
  # filled this STW: a stale row must not be marked, and an unfilled one must
  # not read as "no roots".
  def self.each_greg(id : UInt64, & : UInt64 ->) : Nil
    return unless @@booted
    t = @@table
    return if t.null?
    cap = t.as(Int64*).value.to_i32
    ids = ids_at(t)
    claimed = claimed_at(t, cap)
    i = 0
    while i < cap
      if claimed[i] != 0 && ids[i] == id
        return if greg_ok_at(t, cap)[i] == 0
        row = gregs_at(t, cap) + i.to_u64 * @@greg_words.to_u64
        j = 0
        while j < @@greg_words
          word = row[j]
          yield word unless word == 0
          j += 1
        end
        return
      end
      i += 1
    end
  end

  # Research only, and the reason `spec/stw_slots_spec.cr` can test the growth
  # at all: forget the table without freeing it, so a fresh `configure` starts
  # from the initial capacity.
  def self.reset_for_test : Nil
    @@table = Pointer(UInt8).null
    @@greg_words = 0
    @@no_slot = 0_u64
    @@pinned = false
    @@booted = true
  end

  private def self.note_no_slot : Int32
    @@no_slot &+= 1
    -1
  end

  private def self.block_bytes(cap : Int32) : UInt64
    c = cap.to_u64
    HEADER_BYTES.to_u64 +
      c * 8 +                       # ids
      c * 8 +                       # sps
      c * @@greg_words.to_u64 * 8 + # gregs
      c +                           # claimed
      c                             # greg_ok
  end

  private def self.ids_at(t : UInt8*) : UInt64*
    (t + HEADER_BYTES).as(UInt64*)
  end

  private def self.sps_at(t : UInt8*, cap : Int32) : UInt64*
    (t + HEADER_BYTES + cap.to_u64 * 8).as(UInt64*)
  end

  private def self.gregs_at(t : UInt8*, cap : Int32) : UInt64*
    (t + HEADER_BYTES + cap.to_u64 * 16).as(UInt64*)
  end

  private def self.claimed_at(t : UInt8*, cap : Int32) : UInt8*
    t + HEADER_BYTES + cap.to_u64 * 16 + cap.to_u64 * @@greg_words.to_u64 * 8
  end

  private def self.greg_ok_at(t : UInt8*, cap : Int32) : UInt8*
    claimed_at(t, cap) + cap.to_u64
  end
end
