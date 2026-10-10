# The `Thread` object between `pthread_create` and its own first push.
#
# The second use-after-free, named on 2026-08-20
# (`bench/log/linux/2026-08-20-dying-thread-holder/FINDINGS.md`): gcry read a
# `Thread`'s `@system_handle` out of a block it had already reclaimed. The chain
# is short and every link of it was measured —
#
#   1. `pthread_create` returns. The new thread has not yet pushed itself onto
#      `Thread.threads`, because Crystal publishes a thread only from inside its
#      own `start`.
#   2. A collection begins. `stop_world`'s pre-stop wait spins for the staged
#      thread, it does not publish in time, and the wait **gives up** — it drops
#      the record and stops the world anyway. In the catch: `5 on Crystal's
#      list … the kernel says 6`.
#   3. The `Thread` object is off the list, so the static root that is
#      `Thread.threads` does not cover it. Its only holder is the new thread's
#      own stack, which gcry has no bounds for and never scans. The mark cannot
#      reach it; the sweep frees it.
#   4. The thread publishes. The **next** `stop_world` walks the list, reads
#      `@system_handle` out of the freed block and hands it to
#      `pthread_getattr_np`. That is the SIGSEGV seen since 2026-08-16, and the
#      `+0x418` into `struct pthread` that never varied.
#
# The fix does not touch the stopped world at all, and that is the point: two
# earlier attempts at this defect changed collector behaviour and broke it. It
# needs no wait, no timeout, and no bounds for a stack nobody can safely ask
# about — because **the object is already in gcry's hands**. Crystal calls
# `GC.pthread_create(..., arg: self.as(Void*))`, so the `Thread` is the very
# argument the hook is handed. Root it there, and step 3 cannot happen. The
# root then lasts the thread's whole life — the *death* window is the mirror
# of this one — and ends only on proof that the thread is done with the
# object; see `SLOTS` and "Ending a birth root".
#
# What it does not close, stated because the census will keep reporting it: the
# interval *inside* `pthread_create`, before it returns. The `Thread` is held
# there by the creating thread's own frame, which is scanned; covering the
# rest needs a trampoline on the new thread, which was tried for the staging
# record and crashed 8 runs in 10.
#
# `GCRY_THREAD_BIRTH_ROOT=0` turns it off. `GCRY_THREAD_BIRTH_NOROOT=1` is the
# twin: it records exactly the same births and roots nothing, so a run that
# survives cannot be credited to the bookkeeping.
# `GCRY_THREAD_BIRTH_OVERFLOW_UNROOTED=1` is research only and restores the one
# case this file used to get wrong — see `SLOTS`.

module Gcry
  module ThreadBirthRoot
    # One slot per **live** thread, not per thread being born.
    #
    # It was per-birth until 2026-09-12, released as soon as `stop_world`'s
    # walk found the thread on Crystal's list, on the reasoning that the list
    # is its root from then on. The list stops being its root before the
    # thread stops running: `Thread#start`'s `ensure` does
    #
    #     Thread.threads.delete(self)   # off the list — nothing scans it now
    #     Fiber.inactive(fiber)         # waits on the fiber list's mutex
    #     detach { system_close }       # still dereferencing `self`
    #
    # and gcry does not scan a dying thread's stack, because a thread off the
    # list is a thread it cannot see. The middle line is where the window is
    # widest: every stop holds the fiber list's mutex from before the first
    # suspend to after the last resume (`lock_fiber_list_for_stop`), so a
    # thread that left the list just before a stop sits in `Fiber.inactive`
    # through the whole collection and then reads `@detached` and
    # `@system_handle` out of its `Thread`. Nothing else holds a `Thread`
    # nobody kept: the main `Fiber` does not point back at it. So the root
    # spans the whole life — armed at `pthread_create` and ended only by
    # proof that the thread is done with the object (see "Ending a birth
    # root" below). `make thread-death-window` parks threads exactly there
    # and collects: none lost, against all of them with the root off.
    #
    # The table **grows**: slots come in segments of `SLOTS`, and a birth that
    # finds every slot live maps another segment and takes a slot there, so
    # there is a slot for every live thread however many there are — Boehm's
    # thread table is unbounded too. Until 2026-10-06 the table was these 256
    # slots and nothing else, and every live thread past them took the
    # overflow path, which roots and can never release: 300 threads alive at
    # once overflowed 46 times, and all 46 roots were still held after every
    # thread had been joined and six collections had run
    # (`process_spec/regression/35_thread_birth_table_growth_spec.cr`).
    #
    # Overflow still **costs no root**: a birth that finds no slot because a
    # segment could not be mapped is rooted anyway and never released (see
    # `arm`). What a slot buys is whether that root is temporary or
    # permanent, which is a memory question; an unrooted birth is the
    # use-after-free question.
    #
    # Segments are mapped from the OS (`Gcry.os_map`), never from the heap
    # this table roots into: `arm` runs right after `pthread_create`, with
    # the collector free to stop the world around it. They are only ever
    # appended, by compare-and-swap on the last link, and never unmapped, so
    # every walk — the collector's inside the stopped world included — can
    # follow the links without a lock and never meets freed memory. The cost
    # is the peak thread count's segments, held for the life of the process.
    SLOTS = 256

    # The recorded address is stored **masked**. Until 2026-10-06 this table
    # was a class variable, i.e. static memory that the conservative root scan
    # reads, so a plain address in it was a root — which made the twin arm
    # (`GCRY_THREAD_BIRTH_NOROOT=1`) keep alive exactly what it claims to leave
    # alone, and left the shipped arm unable to say whether the survival came
    # from `add_root` or from the bookkeeping. Caught by the twin on aarch64
    # CI, where it survived; it had passed locally on x86_64. The segments are
    # anonymous mappings now, which no platform's static scan reads, and the
    # mask stays so that remains true of the table whatever a scan reads.
    TABLE_MASK = 0x5A5A_A5A5_5A5A_A5A5_u64

    # A slot's state, claimed and released by compare-and-swap.
    #
    # Until 2026-10-05 a slot was a plain `Bool`, tested and then set. Every
    # thread that calls `Thread.new` writes this table, and two creators that
    # both saw the same slot free both wrote it: the record ended with one
    # birth's handle and possibly the **other's** object. A lost record is a
    # root nothing releases; a crossed one is worse — the first death releases
    # the root of a thread that is still running, and that thread's death
    # window is then covered by nothing. Eight threads arming 24 births each
    # at once lost or crossed **12%** of them (1 047–1 309 of 9 600 per run).
    #
    # `BUSY` belongs to exactly one thread, which writes the record and only
    # then publishes `LIVE`; every release takes `LIVE` -> `BUSY` first, so a
    # record is never read half-written and never released twice. A birth
    # holds its slot `BUSY` from before `pthread_create` to the end of `arm`
    # (see "A birth that ends first").
    FREE = 0_u32
    BUSY = 1_u32
    LIVE = 2_u32

    # A `dead_at` value with this bit set is a join in flight, not a death:
    # see `joining`. The low bits are the slot's generation at the time, so a
    # slot reclaimed and re-armed meanwhile cannot be stamped by mistake.
    JOINING = 1_u64 << 63

    # The `dead_at` of a slot whose creator is inside `arm`: a thread that
    # ends now cannot stamp its own record and waits for it instead (see "A
    # birth that ends first"). The `JOINING` bit is set, so `release_dead`
    # passes it by, and no join mark (`JOINING | gen`, gen 32 bits) equals it.
    ARMING = UInt64::MAX

    # One slot is `SLOT_WORDS` words in its segment: the state and the
    # generation as two `UInt32`s in word 0, then the handle, the masked
    # object, the death stamp (`W_DEAD_AT`: the collection the thread was seen
    # to end at, 0 while it lives, or `JOINING | gen` while a joiner waits for
    # it), and on Windows gcry's own wait handle (see `release_exited`). A
    # segment is one link word — the next segment's address, 0 at the tail —
    # and then `SLOTS` slots. Fresh mappings read zero, which is `FREE`,
    # generation 0, no death and no next segment. The generation moves on
    # every release (`vacate`) and never while a birth holds the slot, so a
    # `BUSY` slot and its generation name one claim (`await_claim`).
    {% if flag?(:win32) %}
      SLOT_WORDS = 5
    {% else %}
      SLOT_WORDS = 4
    {% end %}
    W_ID      = 1
    W_OBJECT  = 2
    W_DEAD_AT = 3
    W_WAIT    = 4

    # The first segment's address, 0 when even that one could not be mapped.
    @@head = uninitialized UInt64
    @@segments = uninitialized Int32
    @@nogrow = uninitialized Bool
    @@enabled = uninitialized Bool
    @@noroot = uninitialized Bool
    @@overflow_unrooted = uninitialized Bool
    @@armed = uninitialized UInt64
    @@released = uninitialized UInt64
    @@overflows = uninitialized UInt64
    @@outstanding = uninitialized Int32
    # Research only: see `test_hold_birth`. 0 off, 1 armed for the next
    # birth, 2 holding one.
    @@test_hold = uninitialized Int32

    # ── Ending a birth root ─────────────────────────────────────────────────
    #
    # Until 2026-09-12 a root was released only when `stop_world`'s walk found
    # its thread on Crystal's list. A thread that published *and exited*
    # between two collections is never on that list when the walk runs, so its
    # root was never released — and once 64 of those had accumulated, every
    # further birth took the overflow path, which roots and can never release.
    # Measured on 3 203 short-lived threads: `released` 6, `overflows` 3 133,
    # `outstanding` **3 197**. That is 3 197 `Thread` objects and everything
    # they transitively hold, pinned for the life of the process.
    #
    # What ends a root now is proof, never a delay:
    #
    #   * **Detach** — Crystal calls `GC.pthread_detach` from the dying
    #     thread's own `ensure`, as the last thing `Thread#start` does with
    #     `self`: the handle is read to make the call, and nothing after it
    #     touches the object. `note_death` stamps the slot there.
    #   * **Join** — `GC.pthread_join` returns only once the thread has fully
    #     exited. `joining` stamps the slot *after* the real join, so a
    #     joined thread's root outlives the thread itself rather than leaning
    #     on the joiner's frame to hold the object for the rest of its life.
    #   * **Handle reuse** — glibc hands a `pthread_t` out again only once its
    #     thread has exited and been detached or joined, so `arm` reclaiming
    #     a recycled handle's slot is proof too.
    #   * **Windows** — Crystal closes its handle without calling into the GC,
    #     so gcry keeps one of its own and releases when it is signalled: the
    #     thread has terminated (`release_exited`).
    #
    # The collector drops a stamped root one collection later
    # (`release_dead`), which costs a bounded number of slots and is not
    # what makes it correct.
    #
    # Marking from the dying thread is safe for one reason and it is worth
    # stating, because the first version did not believe it and paid for the
    # disbelief. The worry was that a mark could land on a slot `arm` had
    # already reused for a different birth — glibc recycles `pthread_t` — and
    # unroot a thread that is still being born. It cannot: `note_death` runs
    # **before** the real `pthread_detach`, and a handle is not reusable until
    # that call has returned. `joining` stamps after the real join, when the
    # handle *is* reusable, and so stamps by compare-and-swap against the
    # generation it recorded before the join: a slot reclaimed and re-armed in
    # between has a fresh generation and a zero stamp, and is left alone.
    #
    # The first version routed marks through a lock-free ring the collector
    # drained, precisely to avoid that reuse. It introduced a worse race of
    # its own: `drain_deaths` reset the producer index to 0 while a producer
    # could be holding a claimed slot, so a store landing after the reset was
    # read as a *fresh* notice and marked whichever thread then held that id
    # — a live one. `make thread-birth-root --churn` crashed in
    # `Thread::LinkedList#push` with `pthread_mutex_unlock: Invalid
    # argument`, which is what a `Thread` freed while it is starting looks
    # like. Direct marking has no such window and is less code.
    @@deaths_seen = uninitialized UInt64
    @@deaths_unmatched = uninitialized UInt64

    @@released_dead = uninitialized UInt64
    # Slots released because glibc handed their handle to a new thread.
    @@reclaimed = uninitialized UInt64
    # `GCRY_THREAD_BIRTH_DEATHS=0`: ignore thread deaths and handle reuse, so
    # a root is never released — the leak the policy before 2026-09-12 had.
    # The control arm of `make thread-birth-root`.
    @@track_deaths = uninitialized Bool

    # Called once from `GC.init`, on the main thread, before any thread exists.
    # `uninitialized` and cleared here for the same reason as the staging table:
    # a class variable with an initializer is set up lazily behind a guard, and
    # an early access from a thread that has not finished starting hung the
    # first process that created one.
    def self.init : Nil
      @@segments = 0
      @@nogrow = false
      @@head = map_segment
      @@segments = 1 if @@head != 0
      @@deaths_seen = 0_u64
      @@deaths_unmatched = 0_u64
      @@released_dead = 0_u64
      @@reclaimed = 0_u64
      @@track_deaths = true
      @@enabled = true
      @@noroot = false
      @@overflow_unrooted = false
      @@armed = 0_u64
      @@released = 0_u64
      @@overflows = 0_u64
      @@outstanding = 0
      @@test_hold = 0
    end

    def self.enabled=(value : Bool) : Bool
      @@enabled = value
    end

    def self.track_deaths=(value : Bool) : Bool
      @@track_deaths = value
    end

    # Research only: never map a segment past the first, so the table is the
    # fixed `SLOTS` it was until 2026-10-06 and a birth past that many live
    # threads takes the overflow path. `make thread-birth-root`'s burst arms
    # use it to reach that path.
    def self.nogrow=(value : Bool) : Bool
      @@nogrow = value
    end

    # Slots across every mapped segment.
    def self.capacity : Int32
      Atomic::Ops.load(pointerof(@@segments), LLVM::AtomicOrdering::Monotonic, false) * SLOTS
    end

    def self.noroot=(value : Bool) : Bool
      @@noroot = value
    end

    # Research only: on overflow, do what this path did before — count it and
    # root nothing. It exists so the gate can show the block that a full table
    # used to leave uncovered actually dying.
    def self.overflow_unrooted=(value : Bool) : Bool
      @@overflow_unrooted = value
    end

    def self.armed : UInt64
      @@armed
    end

    def self.released : UInt64
      @@released
    end

    def self.overflows : UInt64
      @@overflows
    end

    # Births rooted and not yet released. Non-zero at exit is either a thread
    # that never published, or a birth that overflowed the table — in both cases
    # the root is held for the life of the process, which is the lesser harm and
    # is countable.
    def self.outstanding : Int32
      n = @@outstanding
      n < 0 ? 0 : n
    end

    # ── A birth that ends first ─────────────────────────────────────────────
    #
    # Until 2026-10-10 a birth's slot was claimed in `arm`, after
    # `pthread_create` had returned, and nothing stopped the new thread from
    # ending before that. Its `note_death` then found no slot, counted itself
    # unmatched and detached — and a detached, exited thread's handle is
    # glibc's to hand out again. A second creator given the same `pthread_t`
    # armed it for *its* thread, and when the first creator reached `arm`,
    # `reclaim_handle` took that slot as a recycled handle's and un-rooted a
    # thread that was still running, whose death window was then covered by
    # nothing. With one creator held before `arm` and the second thread parked
    # in its death window, that `Thread` was swept 6 runs of 6 (0 of 6 without
    # the hold; `process_spec/regression/52_birth_root_arm_race_spec.cr`), and
    # plain churn of 8–16 creators crossed 1–7 of ~4 800 births with no help.
    # The same order leaked: the late `arm` recorded a thread that was already
    # gone, and nothing would ever release it — 8 creators × 400
    # `Thread.new {}` ended with `deaths_unmatched` at 15–471 and 4–33 slots
    # outstanding. With the claim below: 0 unmatched, and nothing outstanding
    # past the threads still alive.
    #
    # So a birth claims its slot **before** the call (`claim`), with its
    # object, and holds it `BUSY` until `arm` has filled and published it. A
    # thread that ends before that stamps the claim itself, found by its own
    # `Thread` (`stamp_own`), and goes; `arm` sees the stamp, publishes the
    # record dead, and — because the handle may already belong to a running
    # thread — reclaims only a record whose death is stamped
    # (`reclaim_handle`), which a running thread's never is. `arm` marks its
    # start (`ARMING`), so a death from then on finds no claim to stamp and
    # waits for the record instead, as does a join or a detach from another
    # thread, which have no object to look for.
    #
    # The first two fixes made such a death wait. On 2026-10-10 it waited for
    # every birth in flight; then only when its own record was not published
    # yet. That is rare on Linux and, by the numbers, common on macOS, where
    # the thread can end before its creator's `arm`: the last run before
    # either fix counted 10 deaths unmatched per 960, but each of those
    # started a chain of early deaths that each matched the previous one's
    # late record, and its reclaims hid how long the chain was. A thread made
    # to wait had not exited when the next birth asked for a handle, so that
    # birth could not take over its handle and reclaim its slot, and the slot
    # waited for `release_dead`'s two collections instead. `make
    # thread-birth-root --churn` went over its bound of 17 on 2 of 3 macOS
    # x86_64 runs (44, 37) and on arm64 (22), against 6 before. With a creator
    # held between `pthread_create` and `arm` for 50 µs on Linux, which makes
    # nearly every death early: 950–954 of 960 deaths waited; now none wait
    # and 955–957 stamp their claim. The arm's end-of-run `outstanding` on
    # Linux, 25 runs each: mean 5.0 / 6.7 / 5.1 on all, two and three CPUs,
    # against 6.0 / 8.0 / 7.5 before either fix.
    #
    # The wait that is left is per slot: each `BUSY` slot until its claim
    # ends — the rest of an `arm`, and any stop that freezes its creator
    # meanwhile. A count of births in flight, waited down to zero, has no
    # bound: creators that overlap hold it above zero for as long as they
    # keep creating.
    #
    # It cannot deadlock. The waiter holds nothing: a dying thread has left
    # `Thread.threads` and `Fiber.inactive`, and `Thread#detach` / `#join`
    # guard the call with an atomic swap, not a lock. A creator inside its
    # window waits on nothing in this table, only on `pthread_create`, the
    # lock-free staging table and `@roots_lock`; the stop that holds that lock
    # waits only for threads on Crystal's list, which a dying thread is not
    # and a joiner answers from inside the spin. A creator frozen by a stop
    # mid-window holds its waiters for that stop. A `fork` that leaves a
    # claim behind is undone in the child (`after_fork_child`).

    # From `GC.pthread_create`, **before** the real call: a slot for the birth,
    # `BUSY` until `arm` publishes it or `abandon` gives it back. Null when
    # there is nothing to record or no slot could be had; `arm` then takes the
    # overflow path. The object is recorded already, so the thread can find
    # this record if it ends before `arm` (`note_death`).
    def self.claim(object : Void*) : UInt64*
      return Pointer(UInt64).null unless @@enabled && !object.null? && Gcry.default_heap?
      loop do
        each_slot do |slot|
          if state(slot) == FREE && transition(slot, FREE, BUSY)
            slot[W_ID] = 0_u64
            slot[W_OBJECT] = object.address ^ TABLE_MASK
            Atomic::Ops.store(slot + W_DEAD_AT, 0_u64, LLVM::AtomicOrdering::Release, false)
            return slot
          end
        end
        # Every slot was live when walked: add a segment and walk again. A
        # creator that raced this one to a full table appends its own segment
        # behind it, so both find a free slot on the next walk.
        break unless grow
      end
      Pointer(UInt64).null
    end

    # The real call failed: there is no thread, and every death and join
    # would otherwise wait on this slot for good.
    def self.abandon(slot : UInt64*) : Nil
      return if slot.null?
      slot[W_OBJECT] = 0_u64
      publish(slot, FREE)
    end

    # From `GC.pthread_create` / `GC.beginthreadex` (and their C entry points),
    # immediately after it returns. *object* is the `arg` Crystal passed, which
    # for a `Thread` is the object itself. *wait* is gcry's own handle on the
    # thread on Windows, owned by this table from here on, and 0 elsewhere.
    # *slot* is the birth's `claim`: POSIX claims before the real call; Windows
    # arms before the thread can run (it is created suspended) and claims here.
    def self.arm(id : UInt64, object : Void*, wait : UInt64 = 0_u64, slot : UInt64* = claim(object)) : Nil
      heap = Gcry.default_heap?
      unless heap && @@enabled && id != 0 && !object.null?
        abandon(slot)
        close_wait(wait)
        return
      end
      # Did the thread end before this? It stamps its own record if so
      # (`note_death`), and from here on it cannot: it waits for `LIVE`.
      ended = false
      unless slot.null?
        _, armed = Atomic::Ops.cmpxchg(slot + W_DEAD_AT, 0_u64, ARMING,
          LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::Acquire)
        ended = !armed
      end
      # A handle glibc has handed out again is proof its previous owner is
      # fully gone — `pthread_t` is not reusable until the thread has exited
      # and been detached or joined. So the old thread's slot needs no grace:
      # reclaim it here, on the creating thread, before publishing the new one.
      #
      # The first version only *cancelled* the pending death notice, on the
      # grounds that it could not be allowed to land on the new birth. It
      # could not — but discarding it also discarded the old thread's
      # release, and in a churn workload almost every handle is recycled:
      # 1 487 of 3 203 births still overflowed the table. Reclaiming keeps
      # both properties.
      #
      # Only a birth that holds a slot may. One without was invisible to
      # `note_death`, so its thread may have ended and its handle gone to a
      # thread that is running now: that is the slot this would find. A
      # thread that has already ended, likewise, may have let its handle go
      # to a running thread, so its birth reclaims only a record whose death
      # is stamped — which a running thread's never is.
      #
      # Not on Windows: a `HANDLE` value is free for reuse as soon as it is
      # closed, and Crystal closes it while the thread may still be running.
      {% unless flag?(:win32) %}
        if @@track_deaths && !slot.null? && (stale = reclaim_handle(id, ended))
          heap.delete_root(stale)
        end
      {% end %}
      if slot.null?
        # No slot, and no segment could be mapped (or
        # `GCRY_THREAD_BIRTH_NOGROW=1` holds the table at one). The root is
        # taken anyway and there is nothing left that can release it, because
        # nothing records it — so this leaks one `Thread` object and the graph
        # it holds.
        #
        # That is the deliberate side of the trade. The alternative is what
        # this path used to do: count the overflow and return without rooting,
        # which leaves the birth covered by nothing at all — exactly the window
        # this file exists to close, silently reopened by a table size. A leak
        # is a memory bug; an unrooted birth is the use-after-free.
        #
        # `outstanding` counts it, because the root really is outstanding.
        # `GCRY_THREAD_BIRTH_OVERFLOW_UNROOTED=1` restores the old behaviour,
        # and is how `make thread-birth-root` shows the block dying.
        close_wait(wait)
        count(pointerof(@@overflows))
        return if @@noroot || @@overflow_unrooted
        count_outstanding(1)
        heap.add_root(object)
        return
      end
      # Rooted **before** the slot is published, so no release can hand
      # back an object whose root is not in the set yet.
      # The twin walks the same table and offers nothing.
      begin
        heap.add_root(object) unless @@noroot
      rescue ex
        # Out of memory for the root's node. Not left `BUSY` behind.
        abandon(slot)
        close_wait(wait)
        raise ex
      end
      slot[W_ID] = id
      slot[W_OBJECT] = object.address ^ TABLE_MASK
      # A thread that ended first keeps its stamp: its record is published
      # dead, and `release_dead` ends it like any other.
      Atomic::Ops.store(slot + W_DEAD_AT, 0_u64, LLVM::AtomicOrdering::Release, false) unless ended
      {% if flag?(:win32) %}
        slot[W_WAIT] = wait
      {% end %}
      count(pointerof(@@armed))
      count_outstanding(1)
      publish(slot, LIVE)
    end

    # From `GC.pthread_detach`, on the dying thread, **before** the real
    # libc call: this handle's thread is done with its `Thread`. Must not
    # allocate. *object* is the dying thread's own `Thread` when it detaches
    # itself, which lets it find its record before `arm` has published it;
    # without it, a death that finds no published record waits for one
    # (`stamp_own`).
    def self.note_death(id : UInt64, object : Void* = Pointer(Void).null) : Nil
      return if id == 0 || !@@enabled || !@@track_deaths
      heap = Gcry.default_heap?
      return unless heap
      # Never 0: that is the "alive" value, and a death seen before the first
      # collection must still be seen as a death.
      if stamp_own(id, object) { |slot| stamp(slot, 0_u64, heap.collections &+ 1) }
        count(pointerof(@@deaths_seen))
      else
        # No slot: the birth overflowed the table, or gcry never recorded it
        # (born with the birth root off, or not through `GC.pthread_create`).
        count(pointerof(@@deaths_unmatched))
      end
    end

    # From `GC.pthread_join`: *join* is the real call, and the slot is
    # stamped only once it has returned 0 — the thread has exited, so its
    # root ends after the thread rather than at the call.
    #
    # Until 2026-10-05 the join was stamped before the call, like a detach. A
    # joiner can wait for a long time, so a thread still running user code
    # could lose its root two collections into the wait and spend its death
    # window held only by the joiner's frame.
    #
    # A joiner can hold the handle before the creator has armed it — the new
    # thread stores it in its `Thread` itself (`Thread.thread_proc`), and can
    # do so before `pthread_create` returns — so it waits for that record as
    # a death does.
    def self.joining(id : UInt64, & : -> Int32) : Int32
      slot = Pointer(UInt64).null
      mark = 0_u64
      if id != 0 && @@enabled && @@track_deaths
        stamp_own(id) do |s|
          pending = JOINING | generation(s)
          if stamp(s, 0_u64, pending)
            slot = s
            mark = pending
          end
          !slot.null?
        end
        count(pointerof(@@deaths_unmatched)) if slot.null?
      end
      ret = yield
      unless slot.null?
        if ret == 0
          heap = Gcry.default_heap?
          at = heap ? heap.collections &+ 1 : 1_u64
          # Fails only if a new birth already reclaimed the slot, which
          # released this root itself.
          count(pointerof(@@deaths_seen)) if stamp(slot, mark, at)
        else
          # Not joined, so not known to be over.
          stamp(slot, mark, 0_u64)
        end
      end
      ret
    end

    # Stamp the record of *id*'s own birth with the block, which says whether
    # its stamp landed. False when there is none.
    #
    # First the published records, without waiting. A published, unstamped
    # record of *id* can only be this thread's: every earlier owner of the
    # handle let it go through `GC.pthread_detach` or `GC.pthread_join`, and
    # both stamp before the handle is free. Published means `arm` is over,
    # reclaim included.
    #
    # Then, given the thread's own *object*, its claim: a record still
    # `BUSY`, with no handle yet and this object. Stamped there, it tells
    # `arm` the thread is over (see "A birth that ends first"), and the
    # thread goes without waiting. That fails only while `arm` is under way
    # (`ARMING`), or without an object — a join, or a detach from another
    # thread — and only then are the births in flight waited out, one claim
    # per slot (`await_claim`), until this thread's record is published.
    private def self.stamp_own(id : UInt64, object : Void* = Pointer(Void).null, & : UInt64* -> Bool) : Bool
      each_slot do |slot|
        return true if state(slot) == LIVE && slot[W_ID] == id && yield slot
      end
      unless object.null?
        masked = object.address ^ TABLE_MASK
        each_slot do |slot|
          return true if state(slot) == BUSY && slot[W_ID] == 0 && slot[W_OBJECT] == masked && yield slot
        end
      end
      each_slot do |slot|
        await_claim(slot)
        return true if state(slot) == LIVE && slot[W_ID] == id && yield slot
      end
      false
    end

    # Wait out the birth holding *slot*, if one is (see "A birth that ends
    # first"): until the slot is not `BUSY`, or until its generation moves —
    # then the `BUSY` seen was a release, and what holds the slot now is a
    # birth that began after this thread was looking. One claim at most,
    # never "until nothing is being born".
    private def self.await_claim(slot : UInt64*) : Nil
      return unless state(slot) == BUSY
      gen = generation(slot)
      spins = 0
      while state(slot) == BUSY && generation(slot) == gen
        spins += 1
        if spins & 63 == 0
          Thread.yield
        else
          Intrinsics.pause
        end
      end
    end

    # Child after `fork`: only the forking thread exists, so a slot another
    # thread held `BUSY` — a birth between its claim and its `arm`, or a
    # release under way — has nobody left to finish it, and a death or join
    # in the child that waited on it would wait for good (`await_claim`). Given
    # back. `LIVE` slots stay: their roots hold the parent's unlisted
    # `Thread` objects (src/gcry/platform/linux_fork.cr).
    def self.after_fork_child : Nil
      Atomic::Ops.store(pointerof(@@test_hold), 0, LLVM::AtomicOrdering::Release, false)
      each_slot do |slot|
        publish(slot, FREE) if state(slot) == BUSY
      end
    end

    # Research only, for `process_spec/regression/52_birth_root_arm_race_spec.cr`:
    # hold the next birth's creator between `pthread_create` returning and
    # `arm` (`test_hold_point`) until `test_release_birth`. That race needs a
    # creator parked there while its thread ends and another birth is handed
    # the handle, and nothing else can park one on demand: the interval takes
    # no lock and makes no call that can be held from outside. Costs every
    # birth one load.
    def self.test_hold_birth : Nil
      Atomic::Ops.store(pointerof(@@test_hold), 1, LLVM::AtomicOrdering::SequentiallyConsistent, false)
    end

    # A creator is parked at `test_hold_point`.
    def self.test_birth_held? : Bool
      Atomic::Ops.load(pointerof(@@test_hold), LLVM::AtomicOrdering::Acquire, false) == 2
    end

    # Lets a parked creator go, or disarms a hold nobody reached.
    def self.test_release_birth : Nil
      Atomic::Ops.store(pointerof(@@test_hold), 0, LLVM::AtomicOrdering::SequentiallyConsistent, false)
    end

    # From `GC.pthread_create`, between the real call and `arm`.
    @[AlwaysInline]
    def self.test_hold_point : Nil
      return if Atomic::Ops.load(pointerof(@@test_hold), LLVM::AtomicOrdering::Monotonic, false) == 0
      _, held = Atomic::Ops.cmpxchg(pointerof(@@test_hold), 1, 2,
        LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::Monotonic)
      return unless held
      while Atomic::Ops.load(pointerof(@@test_hold), LLVM::AtomicOrdering::Acquire, false) == 2
        Thread.yield
      end
    end

    # Release the slot the handle's previous owner held, returning its object
    # so the caller can un-root it. A handle glibc has handed out again is
    # proof its previous owner is gone, so this needs no grace. Runs on a
    # creating thread. *stamped_only* when the birth's own thread had ended
    # before `arm`: the handle may be another running thread's by now, so
    # only a record whose death is stamped — done with its object — is taken.
    private def self.reclaim_handle(id : UInt64, stamped_only : Bool = false) : Void*?
      each_slot do |slot|
        next unless state(slot) == LIVE && slot[W_ID] == id
        if stamped_only
          at = Atomic::Ops.load(slot + W_DEAD_AT, LLVM::AtomicOrdering::Acquire, false)
          next if at == 0 || (at & JOINING) != 0
        end
        if transition(slot, LIVE, BUSY)
          object = vacate(slot)
          count(pointerof(@@reclaimed))
          return object
        end
      end
      nil
    end

    # Release what has been dead long enough. Called from `stop_world` with
    # `@roots_lock` held, so the block hands each pointer straight to
    # `@roots`.
    #
    # `collection > at` rather than `>=`: a thread marked during the stop
    # that is about to run must survive it. `note_death` stamps
    # `collections + 1`, so the earliest release is the stop after the one
    # that was in flight when the thread detached.
    def self.release_dead(collection : UInt64, & : Void* ->) : Nil
      return unless @@track_deaths
      each_slot do |slot|
        at = Atomic::Ops.load(slot + W_DEAD_AT, LLVM::AtomicOrdering::Acquire, false)
        if at != 0 && (at & JOINING) == 0 && collection > at &&
           state(slot) == LIVE && transition(slot, LIVE, BUSY)
          count(pointerof(@@released_dead))
          if object = vacate(slot)
            yield object
          end
        end
      end
    end

    {% if flag?(:win32) %}
      # Release every slot whose thread has terminated. Called from
      # `stop_world` with `@roots_lock` held, like `release_dead`.
      #
      # Until 2026-10-05 Windows released a birth root when the stop found
      # the thread on Crystal's list — the policy Linux dropped on 2026-09-12
      # for opening the death window. Crystal's Windows `Thread` closes its
      # handle with `CloseHandle` and joins with `WaitForSingleObject`
      # directly, never through the GC, so there was no death to observe.
      # gcry's own duplicate of the handle is that observation: it is
      # signalled once the thread has terminated, and Crystal closing its
      # copy does not close this one.
      def self.release_exited(& : Void* ->) : Nil
        return unless @@track_deaths
        each_slot do |slot|
          if state(slot) == LIVE && (h = slot[W_WAIT]) != 0 &&
             LibC.WaitForSingleObject(Pointer(Void).new(h), 0) == LibC::WAIT_OBJECT_0 &&
             transition(slot, LIVE, BUSY)
            count(pointerof(@@released_dead))
            if object = vacate(slot)
              yield object
            end
          end
        end
      end
    {% end %}

    # Clear a slot this thread holds `BUSY` and give it back. Returns the
    # object to un-root, or nil when there is none to give back.
    private def self.vacate(slot : UInt64*) : Void*?
      object = slot[W_OBJECT] ^ TABLE_MASK
      slot[W_ID] = 0_u64
      slot[W_OBJECT] = 0_u64
      slot[W_DEAD_AT] = 0_u64
      {% if flag?(:win32) %}
        close_wait(slot[W_WAIT])
        slot[W_WAIT] = 0_u64
      {% end %}
      Atomic::Ops.store(slot.as(UInt32*) + 1, generation(slot) &+ 1, LLVM::AtomicOrdering::Release, false)
      count(pointerof(@@released))
      count_outstanding(-1)
      publish(slot, FREE)
      return nil if @@noroot || object == TABLE_MASK || object == 0
      Pointer(Void).new(object)
    end

    private def self.close_wait(wait : UInt64) : Nil
      {% if flag?(:win32) %}
        LibC.CloseHandle(Pointer(Void).new(wait)) if wait != 0
      {% end %}
    end

    private def self.segment_bytes : UInt64
      8_u64 + SLOTS.to_u64 * SLOT_WORDS.to_u64 * 8_u64
    end

    # A zeroed segment from the OS, or 0 when the mapping failed.
    private def self.map_segment : UInt64
      ptr = Gcry.os_map(segment_bytes)
      Gcry.mmap_failed?(ptr) ? 0_u64 : ptr.address
    end

    # Appends one segment at the tail. False under `GCRY_THREAD_BIRTH_NOGROW=1`
    # once the first exists, or when the OS refuses the mapping.
    private def self.grow : Bool
      return false if @@nogrow && @@head != 0
      seg = map_segment
      return false if seg == 0
      # `@@head` is the link before the first segment, so an empty table and
      # a full one append the same way.
      link = pointerof(@@head)
      loop do
        old, ok = Atomic::Ops.cmpxchg(link, 0_u64, seg,
          LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::Acquire)
        break if ok
        link = Pointer(UInt64).new(old)
      end
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Add, pointerof(@@segments), 1, LLVM::AtomicOrdering::Monotonic, false)
      true
    end

    # Every slot of every segment, in order. Links are read with acquire, so
    # a segment appended while this walks is either seen whole or not at all.
    private def self.each_slot(& : UInt64* ->) : Nil
      seg = Atomic::Ops.load(pointerof(@@head), LLVM::AtomicOrdering::Acquire, false)
      while seg != 0
        slot = Pointer(UInt64).new(seg) + 1
        i = 0
        while i < SLOTS
          yield slot
          slot += SLOT_WORDS
          i += 1
        end
        seg = Atomic::Ops.load(Pointer(UInt64).new(seg), LLVM::AtomicOrdering::Acquire, false)
      end
    end

    @[AlwaysInline]
    private def self.state(slot : UInt64*) : UInt32
      Atomic::Ops.load(slot.as(UInt32*), LLVM::AtomicOrdering::Acquire, false)
    end

    # Read while another thread may hold the slot `BUSY` (`await_claim`),
    # so it is written atomically too (`vacate`).
    @[AlwaysInline]
    private def self.generation(slot : UInt64*) : UInt32
      Atomic::Ops.load(slot.as(UInt32*) + 1, LLVM::AtomicOrdering::Acquire, false)
    end

    @[AlwaysInline]
    private def self.transition(slot : UInt64*, from : UInt32, to : UInt32) : Bool
      _, ok = Atomic::Ops.cmpxchg(slot.as(UInt32*), from, to,
        LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::Monotonic)
      ok
    end

    @[AlwaysInline]
    private def self.publish(slot : UInt64*, value : UInt32) : Nil
      Atomic::Ops.store(slot.as(UInt32*), value, LLVM::AtomicOrdering::Release, false)
    end

    @[AlwaysInline]
    private def self.stamp(slot : UInt64*, from : UInt64, to : UInt64) : Bool
      _, ok = Atomic::Ops.cmpxchg(slot + W_DEAD_AT, from, to,
        LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::Monotonic)
      ok
    end

    # The counters are written by every creating thread, every dying thread
    # and the collector; plain `+=` lost updates once creators ran
    # concurrently.
    @[AlwaysInline]
    private def self.count(counter : UInt64*) : Nil
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Add, counter, 1_u64, LLVM::AtomicOrdering::Monotonic, false)
    end

    @[AlwaysInline]
    private def self.count_outstanding(delta : Int32) : Nil
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Add, pointerof(@@outstanding), delta, LLVM::AtomicOrdering::Monotonic, false)
    end

    # Deaths the hooks matched to a slot, and deaths that found none — an
    # overflowed birth, or one gcry never recorded; until 2026-10-10 also a
    # thread that ended before its creator's `arm` (see "A birth that ends
    # first"). `released_dead` plus `reclaimed` against `armed` is the
    # reading that says whether short-lived threads still accumulate roots.
    def self.deaths_seen : UInt64
      @@deaths_seen
    end

    def self.deaths_unmatched : UInt64
      @@deaths_unmatched
    end

    def self.released_dead : UInt64
      @@released_dead
    end

    def self.reclaimed : UInt64
      @@reclaimed
    end
  end
end
