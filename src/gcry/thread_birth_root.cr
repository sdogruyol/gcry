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
    # Overflow still **costs no root**: a birth that finds no slot is rooted
    # anyway and never released (see `arm`). What the size buys is whether
    # that root is temporary or permanent, which is a memory question; an
    # unrooted birth is the use-after-free question.
    SLOTS = 256

    # The recorded address is stored **masked**. This table is a class variable,
    # i.e. static memory that the conservative root scan reads, so a plain
    # address in it is a root — which would make the twin arm
    # (`GCRY_THREAD_BIRTH_NOROOT=1`) keep alive exactly what it claims to leave
    # alone, and would leave the shipped arm unable to say whether the survival
    # came from `add_root` or from the bookkeeping. Caught by the twin on
    # aarch64 CI, where it survived; it had passed locally on x86_64.
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
    # record is never read half-written and never released twice.
    FREE = 0_u32
    BUSY = 1_u32
    LIVE = 2_u32

    # A `dead_at` value with this bit set is a join in flight, not a death:
    # see `joining`. The low bits are the slot's generation at the time, so a
    # slot reclaimed and re-armed meanwhile cannot be stamped by mistake.
    JOINING = 1_u64 << 63

    @@state = uninitialized StaticArray(UInt32, SLOTS)
    # Bumped by every `arm` of the slot.
    @@gen = uninitialized StaticArray(UInt32, SLOTS)
    @@ids = uninitialized StaticArray(UInt64, SLOTS)
    @@objects = uninitialized StaticArray(UInt64, SLOTS)
    {% if flag?(:win32) %}
      # A handle of gcry's own on each thread, so its exit is observable after
      # Crystal has closed the one it keeps. See `release_exited`.
      @@waits = uninitialized StaticArray(UInt64, SLOTS)
    {% end %}
    @@enabled = uninitialized Bool
    @@noroot = uninitialized Bool
    @@overflow_unrooted = uninitialized Bool
    @@armed = uninitialized UInt64
    @@released = uninitialized UInt64
    @@overflows = uninitialized UInt64
    @@outstanding = uninitialized Int32

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

    # The collection a slot's thread was seen to end at, 0 while it lives, or
    # `JOINING | gen` while a joiner waits for it.
    @@dead_at = uninitialized StaticArray(UInt64, SLOTS)
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
      i = 0
      while i < SLOTS
        @@state[i] = FREE
        @@gen[i] = 0_u32
        @@ids[i] = 0_u64
        @@objects[i] = 0_u64
        @@dead_at[i] = 0_u64
        {% if flag?(:win32) %}
          @@waits[i] = 0_u64
        {% end %}
        i += 1
      end
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
    end

    def self.enabled=(value : Bool) : Bool
      @@enabled = value
    end

    def self.track_deaths=(value : Bool) : Bool
      @@track_deaths = value
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

    # From `GC.pthread_create` / `GC.beginthreadex`, immediately after it
    # returns. *object* is the `arg` Crystal passed, which for a `Thread` is
    # the object itself. *wait* is gcry's own handle on the thread on Windows,
    # owned by this table from here on, and 0 elsewhere.
    def self.arm(id : UInt64, object : Void*, wait : UInt64 = 0_u64) : Nil
      heap = Gcry.default_heap?
      unless heap && @@enabled && id != 0 && !object.null?
        close_wait(wait)
        return
      end
      # A handle glibc has handed out again is proof its previous owner is
      # fully gone — `pthread_t` is not reusable until the thread has exited
      # and been detached or joined. So the old thread's slot needs no grace:
      # reclaim it here, on the creating thread, before claiming a new one.
      #
      # The first version only *cancelled* the pending death notice, on the
      # grounds that it could not be allowed to land on the new birth. It
      # could not — but discarding it also discarded the old thread's
      # release, and in a churn workload almost every handle is recycled:
      # 1 487 of 3 203 births still overflowed the table. Reclaiming keeps
      # both properties.
      #
      # Not on Windows: a `HANDLE` value is free for reuse as soon as it is
      # closed, and Crystal closes it while the thread may still be running.
      {% unless flag?(:win32) %}
        if @@track_deaths && (stale = reclaim_handle(id))
          heap.delete_root(stale)
        end
      {% end %}
      i = 0
      while i < SLOTS
        if state(i) == FREE && transition(i, FREE, BUSY)
          @@ids[i] = id
          @@objects[i] = object.address ^ TABLE_MASK
          @@dead_at[i] = 0_u64
          @@gen[i] &+= 1
          {% if flag?(:win32) %}
            @@waits[i] = wait
          {% end %}
          # Rooted **before** the slot is published, so no release can hand
          # back an object whose root is not in the set yet.
          # The twin walks the same table and offers nothing.
          heap.add_root(object) unless @@noroot
          count(pointerof(@@armed))
          count_outstanding(1)
          publish(i, LIVE)
          return
        end
        i += 1
      end
      # No slot. The root is taken anyway and there is nothing left that can
      # release it, because nothing records it — so this leaks one `Thread`
      # object and the graph it holds.
      #
      # That is the deliberate side of the trade. The alternative is what this
      # path used to do: count the overflow and return without rooting, which
      # leaves the birth covered by nothing at all — exactly the window this
      # file exists to close, silently reopened by a table size. A leak is a
      # memory bug; an unrooted birth is the use-after-free.
      #
      # `outstanding` counts it, because the root really is outstanding.
      # `GCRY_THREAD_BIRTH_OVERFLOW_UNROOTED=1` restores the old behaviour, and
      # is how `make thread-birth-root` shows the block dying.
      close_wait(wait)
      count(pointerof(@@overflows))
      return if @@noroot || @@overflow_unrooted
      count_outstanding(1)
      heap.add_root(object)
    end

    # From `GC.pthread_detach`, on the dying thread, **before** the real
    # libc call: this handle's thread is done with its `Thread`. Must be
    # wait-free and must not allocate.
    def self.note_death(id : UInt64) : Nil
      return if id == 0 || !@@enabled || !@@track_deaths
      heap = Gcry.default_heap?
      return unless heap
      # Never 0: that is the "alive" value, and a death seen before the first
      # collection must still be seen as a death.
      at = heap.collections &+ 1
      i = 0
      while i < SLOTS
        if state(i) == LIVE && @@ids[i] == id && stamp(i, 0_u64, at)
          count(pointerof(@@deaths_seen))
          return
        end
        i += 1
      end
      # No slot: the birth overflowed the table, or the handle was already
      # reclaimed by a later `arm`. Both are accounted for elsewhere.
      count(pointerof(@@deaths_unmatched))
    end

    # From `GC.pthread_join`: *join* is the real call, and the slot is
    # stamped only once it has returned 0 — the thread has exited, so its
    # root ends after the thread rather than at the call.
    #
    # Until 2026-10-05 the join was stamped before the call, like a detach. A
    # joiner can wait for a long time, so a thread still running user code
    # could lose its root two collections into the wait and spend its death
    # window held only by the joiner's frame.
    def self.joining(id : UInt64, & : -> Int32) : Int32
      slot = -1
      mark = 0_u64
      if id != 0 && @@enabled && @@track_deaths
        i = 0
        while i < SLOTS
          if state(i) == LIVE && @@ids[i] == id
            pending = JOINING | @@gen[i]
            if stamp(i, 0_u64, pending)
              slot = i
              mark = pending
              break
            end
          end
          i += 1
        end
        count(pointerof(@@deaths_unmatched)) if slot < 0
      end
      ret = yield
      if slot >= 0
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

    # Release the slot the handle's previous owner held, returning its object
    # so the caller can un-root it. A handle glibc has handed out again is
    # proof its previous owner is gone, so this needs no grace. Runs on a
    # creating thread.
    private def self.reclaim_handle(id : UInt64) : Void*?
      j = 0
      while j < SLOTS
        if state(j) == LIVE && @@ids[j] == id && transition(j, LIVE, BUSY)
          object = vacate(j)
          count(pointerof(@@reclaimed))
          return object
        end
        j += 1
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
      j = 0
      while j < SLOTS
        at = Atomic::Ops.load(pointerof(@@dead_at).as(UInt64*) + j, LLVM::AtomicOrdering::Acquire, false)
        if at != 0 && (at & JOINING) == 0 && collection > at &&
           state(j) == LIVE && transition(j, LIVE, BUSY)
          count(pointerof(@@released_dead))
          if object = vacate(j)
            yield object
          end
        end
        j += 1
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
        j = 0
        while j < SLOTS
          if state(j) == LIVE && (h = @@waits[j]) != 0 &&
             LibC.WaitForSingleObject(Pointer(Void).new(h), 0) == LibC::WAIT_OBJECT_0 &&
             transition(j, LIVE, BUSY)
            count(pointerof(@@released_dead))
            if object = vacate(j)
              yield object
            end
          end
          j += 1
        end
      end
    {% end %}

    # Clear a slot this thread holds `BUSY` and give it back. Returns the
    # object to un-root, or nil when there is none to give back.
    private def self.vacate(j : Int32) : Void*?
      object = @@objects[j] ^ TABLE_MASK
      @@ids[j] = 0_u64
      @@objects[j] = 0_u64
      @@dead_at[j] = 0_u64
      {% if flag?(:win32) %}
        close_wait(@@waits[j])
        @@waits[j] = 0_u64
      {% end %}
      count(pointerof(@@released))
      count_outstanding(-1)
      publish(j, FREE)
      return nil if @@noroot || object == TABLE_MASK || object == 0
      Pointer(Void).new(object)
    end

    private def self.close_wait(wait : UInt64) : Nil
      {% if flag?(:win32) %}
        LibC.CloseHandle(Pointer(Void).new(wait)) if wait != 0
      {% end %}
    end

    @[AlwaysInline]
    private def self.state(i : Int32) : UInt32
      Atomic::Ops.load(pointerof(@@state).as(UInt32*) + i, LLVM::AtomicOrdering::Acquire, false)
    end

    @[AlwaysInline]
    private def self.transition(i : Int32, from : UInt32, to : UInt32) : Bool
      _, ok = Atomic::Ops.cmpxchg(pointerof(@@state).as(UInt32*) + i, from, to,
        LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::Monotonic)
      ok
    end

    @[AlwaysInline]
    private def self.publish(i : Int32, value : UInt32) : Nil
      Atomic::Ops.store(pointerof(@@state).as(UInt32*) + i, value, LLVM::AtomicOrdering::Release, false)
    end

    @[AlwaysInline]
    private def self.stamp(i : Int32, from : UInt64, to : UInt64) : Bool
      _, ok = Atomic::Ops.cmpxchg(pointerof(@@dead_at).as(UInt64*) + i, from, to,
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

    # Deaths the hooks matched to a slot, and deaths whose slot was already
    # gone — an overflowed birth, or a handle a later `arm` reclaimed first.
    # `released_dead` plus `reclaimed` against `armed` is the reading that
    # says whether short-lived threads still accumulate roots.
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
