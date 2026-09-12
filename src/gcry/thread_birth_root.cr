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
# argument the hook is handed. Root it there, release it when the thread turns
# up on Crystal's list, and step 3 cannot happen.
#
# What it does not close, stated because the census will keep reporting it: the
# interval *inside* `pthread_create`, before it returns. Covering that needs a
# trampoline on the new thread, which was tried for the staging record and
# crashed 8 runs in 10.
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
    #     Fiber.inactive(fiber)
    #     detach { system_close }       # still dereferencing `self`
    #
    # and gcry does not scan a dying thread's stack, because a thread off the
    # list is a thread it cannot see. So between those lines the `Thread` is
    # unreachable, gets swept, and the thread keeps using it. The dying-type
    # audit names it exactly: *"192 bytes, type_id 171, unmarked and about to
    # be swept; on Crystal's thread list: no — it has either not published
    # yet or exited"*, followed by a SIGSEGV on gcry's freed-block poison.
    #
    # That window was latent while `GC.pthread_detach` was a bare passthrough
    # — the dying thread crossed it in a few instructions. Giving the hook
    # any work at all turned it into 6 crashes in 40 runs of 960 short-lived
    # threads, against 0 in 40 before. The window was always there; the hook
    # only made it wide enough to hit.
    #
    # So the root now spans the whole life: armed at `pthread_create`,
    # released a collection after the thread's death is observed, or at once
    # when glibc hands its handle to somebody else. The table therefore has
    # to hold every live thread rather than every unpublished one.
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

    @@ids = uninitialized StaticArray(UInt64, SLOTS)
    @@objects = uninitialized StaticArray(UInt64, SLOTS)
    @@used = uninitialized StaticArray(Bool, SLOTS)
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
    # The end of a thread is observable: Crystal calls `GC.pthread_detach`
    # from the dying thread's own `ensure`, and `GC.pthread_join` from a
    # joiner. Those hooks mark the slot here, and the collector drops the
    # root one collection later.
    #
    # Marking from the dying thread is safe for one reason and it is worth
    # stating, because the first version did not believe it and paid for the
    # disbelief. The worry was that a mark could land on a slot `arm` had
    # already reused for a different birth — glibc recycles `pthread_t` — and
    # unroot a thread that is still being born. It cannot: both hooks mark
    # **before** calling the real `pthread_detach` / `pthread_join`, and a
    # handle is not reusable until that call has returned. So the mark is
    # strictly ordered before any `arm` that could see the same handle.
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

    # The collection a slot's thread was seen to end at, or 0 while it lives.
    # A root is dropped one whole collection later: the dying thread is still
    # running when it detaches — `Thread#start` has already removed it from
    # Crystal's list, so nothing scans the stack it is finishing on, and that
    # stack holds the very `Thread` being unrooted. One collection of grace
    # costs a bounded number of slots and removes the window.
    @@dead_at = uninitialized StaticArray(UInt64, SLOTS)
    @@released_dead = uninitialized UInt64
    # Slots released because glibc handed their handle to a new thread.
    @@reclaimed = uninitialized UInt64
    # `GCRY_THREAD_BIRTH_DEATHS=0`: ignore thread deaths and handle reuse, so
    # a root is released only when `stop_world` finds its thread on Crystal's
    # list — the policy before 2026-09-12, which leaked one root per
    # short-lived thread. The control arm of `make thread-birth-root`.
    @@track_deaths = uninitialized Bool

    # Called once from `GC.init`, on the main thread, before any thread exists.
    # `uninitialized` and cleared here for the same reason as the staging table:
    # a class variable with an initializer is set up lazily behind a guard, and
    # an early access from a thread that has not finished starting hung the
    # first process that created one.
    def self.init : Nil
      i = 0
      while i < SLOTS
        @@ids[i] = 0_u64
        @@objects[i] = 0_u64
        @@used[i] = false
        @@dead_at[i] = 0_u64
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

    # From `GC.pthread_create`, immediately after it returns. *object* is the
    # `arg` Crystal passed, which for a `Thread` is the object itself.
    def self.arm(id : UInt64, object : Void*) : Nil
      return unless @@enabled
      return if id == 0 || object.null?
      heap = Gcry.default_heap?
      return unless heap
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
      if @@track_deaths && (stale = reclaim_handle(id))
        heap.delete_root(stale)
      end
      i = 0
      while i < SLOTS
        unless @@used[i]
          @@ids[i] = id
          @@objects[i] = object.address ^ TABLE_MASK
          @@used[i] = true
          @@dead_at[i] = 0_u64
          @@armed &+= 1
          @@outstanding += 1
          # The twin walks the same table and offers nothing.
          heap.add_root(object) unless @@noroot
          return
        end
        i += 1
      end
      # No slot. The root is taken anyway and there is nothing left that can
      # release it, because `release` matches on a record that was never
      # written — so this leaks one `Thread` object and the graph it holds.
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
      @@overflows &+= 1
      return if @@noroot || @@overflow_unrooted
      @@outstanding += 1
      heap.add_root(object)
    end

    # From `stop_world`'s pre-suspend walk of Crystal's list: this thread has
    # published itself, so the list is its root from here on.
    #
    # Returns the pointer to un-root, and does **not** un-root it here. The
    # caller is inside `stop_world`, which runs under `@roots_lock` — taken by
    # `stop_world_quiescing_roots` and held across the whole stop — and that
    # lock is a non-reentrant spinlock. The first version called
    # `heap.delete_root` from here and deadlocked the collector on the first run
    # of `make thread-birth-root`: `GC.collect` never returned.
    def self.release(id : UInt64) : Void*?
      return nil if id == 0
      i = 0
      while i < SLOTS
        if @@used[i] && @@ids[i] == id
          object = @@objects[i] ^ TABLE_MASK
          @@used[i] = false
          @@ids[i] = 0_u64
          @@objects[i] = 0_u64
          @@released &+= 1
          @@outstanding -= 1
          return nil if @@noroot || object == TABLE_MASK || object == 0
          return Pointer(Void).new(object)
        end
        i += 1
      end
      nil
    end

    # From `GC.pthread_detach` / `GC.pthread_join`, **before** either makes
    # its real libc call: this handle's thread has ended. Runs on the dying
    # thread or a joiner, so it must be wait-free and must not allocate.
    #
    # The mark is only that: a stamp. The root is dropped by the collector a
    # collection later, because a detaching thread is still running — on a
    # stack nothing scans, since `Thread#start` removed it from Crystal's
    # list one line earlier — and that stack holds the object being unrooted.
    def self.note_death(id : UInt64) : Nil
      return if id == 0 || !@@enabled || !@@track_deaths
      heap = Gcry.default_heap?
      return unless heap
      # Never 0: that is the "alive" value, and a death seen before the first
      # collection must still be seen as a death.
      at = heap.collections &+ 1
      i = 0
      while i < SLOTS
        if @@used[i] && @@ids[i] == id && @@dead_at[i] == 0
          @@dead_at[i] = at
          @@deaths_seen &+= 1
          return
        end
        i += 1
      end
      # No slot: the birth overflowed the table, or the handle was already
      # reclaimed by a later `arm`. Both are accounted for elsewhere.
      @@deaths_unmatched &+= 1
    end

    # Release the slot the handle's previous owner held, returning its object
    # so the caller can un-root it. A handle glibc has handed out again is
    # proof its previous owner is gone, so this needs no grace. Runs on a
    # creating thread, which already writes this table.
    private def self.reclaim_handle(id : UInt64) : Void*?
      j = 0
      while j < SLOTS
        if @@used[j] && @@ids[j] == id
          object = @@objects[j] ^ TABLE_MASK
          @@used[j] = false
          @@ids[j] = 0_u64
          @@objects[j] = 0_u64
          @@dead_at[j] = 0_u64
          @@released &+= 1
          @@reclaimed &+= 1
          @@outstanding -= 1
          return nil if @@noroot || object == TABLE_MASK || object == 0
          return Pointer(Void).new(object)
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
    # that was in flight when the thread detached — a detaching thread is
    # still running, on a stack nothing scans, holding the object being
    # unrooted.
    def self.release_dead(collection : UInt64, & : Void* ->) : Nil
      return unless @@track_deaths
      j = 0
      while j < SLOTS
        at = @@dead_at[j]
        if @@used[j] && at != 0 && collection > at
          object = @@objects[j] ^ TABLE_MASK
          @@used[j] = false
          @@ids[j] = 0_u64
          @@objects[j] = 0_u64
          @@dead_at[j] = 0_u64
          @@released &+= 1
          @@released_dead &+= 1
          @@outstanding -= 1
          yield Pointer(Void).new(object) unless @@noroot || object == TABLE_MASK || object == 0
        end
        j += 1
      end
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
