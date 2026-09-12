# Threads that exist but have not published themselves yet.
#
# gcry learns about threads from Crystal's list, and a thread joins that list
# only from inside its own `start`. Between `pthread_create` and that push it
# runs, allocates, and is neither suspended by `stop_world` nor scanned — a
# window the census measures at roughly one collection in a thousand
# (`bench/log/linux/2026-08-17-thread-birth-window/FINDINGS.md`).
#
# This is gcry's own record of those threads. It is filled from the **creating**
# side, immediately after `pthread_create` returns, and emptied when the thread
# turns up in Crystal's list.
#
# That placement is deliberate and is the second design tried. Recording from
# the new thread instead — a trampoline that stages `pthread_self()` before user
# code, which is what `GC_pthread_create` does for Boehm — covers strictly more
# of the window and was measured to cover it exactly, but it destabilised thread
# startup: 8 of 10 runs crashed against 0 of 10 without it. From the creating
# side there is no new frame on the new thread and no call before its runtime is
# up, at the cost of leaving the interval *inside* `pthread_create` uncovered.
# How much that costs is what the census reports.
#
# **This file only records.** It does not change what `stop_world` suspends or
# what the scan walks: two attempts at this defect have now changed collector
# behaviour and broken it, so the recording half lands alone and is verified
# before anything acts on it.
#
# Every class variable here is `uninitialized` and cleared by `init_staging`, on
# purpose. One with an initializer is set up lazily behind a guard, and an early
# access can land on a thread that has not finished starting — with an
# `Atomic(Int32).new(0)` initializer the first thread-creating process hung.
module Gcry
  module Platform
    # A slot is freed when the thread turns up in Crystal's list, and until
    # 2026-08-22 the only thing that looked was `stop_world`'s walk. So the
    # table did not hold "threads being born at once" — it held **every thread
    # created since the last collection**, and 65 `Thread.new`s with none in
    # between filled it (200 gave 137 overflows). Past that, `stage_thread`
    # dropped the birth it had just been handed: the newest one, i.e. the thread
    # actually inside the window this table exists to see.
    #
    # What that cost is the wait. A thread with no entry is not waited for, so
    # the world stops with it unpublished — neither suspended nor scanned, so
    # anything reachable only from its stack has no root. `ThreadBirthRoot`
    # covers the `Thread` object itself and nothing else the thread has touched.
    #
    # Two changes rather than a bigger table: the full path drains entries whose
    # threads have already published (`drain_published`), which is what the
    # occupancy should have been all along, and if that frees nothing it evicts
    # the **oldest** entry instead of refusing the newest. The oldest is the
    # birth most likely to be over already; the newest is the one in flight.
    # Exactly 64 so occupancy fits one atomic word. See `@@staged_claimed`.
    STAGED_SLOTS = 64

    @@staged = uninitialized StaticArray(UInt64, STAGED_SLOTS)
    # Occupancy as an atomic bitmask, and the count **derived** from it.
    #
    # It was a `Bool` array beside a plain `Int32` counter until 2026-09-12,
    # maintained with `+= 1` / `-= 1`. That was survivable while only the
    # creating threads and the collector touched it; once the
    # `pthread_detach` hook started unstaging from the dying thread as well,
    # the lost updates drifted the counter **up** and it never came back
    # down. `wait_for_staged_threads` loops `while staged_count > 0`, so a
    # counter stuck above zero over a table with nothing in it meant every
    # stop spent its whole spin budget and then its whole yield budget and
    # then reported a timeout: 0 of 60 collections at first, 194 of 240 a
    # little later, 387 of 400 after that — a number that grew with the
    # thread count and looked exactly like a real birth-window problem.
    #
    # A derived count cannot drift. A lost bit is a stale entry, which the
    # next drain clears; a lost counter update is permanent.
    @@staged_claimed = uninitialized Atomic(UInt64)
    # Birth order, so "oldest" is a fact rather than a slot index. Slots are
    # reused out of order, so position says nothing.
    @@staged_seq = uninitialized StaticArray(UInt64, STAGED_SLOTS)
    @@staged_next_seq = uninitialized UInt64
    @@staged_overflows = uninitialized UInt64
    @@staged_evictions = uninitialized UInt64
    @@staged_no_evict = uninitialized Bool
    @@staged_total = uninitialized UInt64

    # Called once from `GC.init`, on the main thread, before any thread exists.
    def self.init_staging : Nil
      i = 0
      while i < STAGED_SLOTS
        @@staged[i] = 0_u64
        @@staged_seq[i] = 0_u64
        i += 1
      end
      @@staged_claimed.set(0_u64)
      @@staged_next_seq = 0_u64
      @@staged_overflows = 0_u64
      @@staged_evictions = 0_u64
      @@staged_no_evict = false
      @@unstage_on_death = false
      @@staged_total = 0_u64
    end

    # From the creating thread, right after `pthread_create` returns.
    def self.stage_thread(id : UInt64) : Nil
      return if id == 0
      i = claim_slot
      if i < 0
        # Full. Almost always because entries are sitting here for threads that
        # published long ago and nothing has looked since the last collection,
        # so look now.
        @@staged_overflows &+= 1
        drain_published
        i = claim_slot
      end

      if i < 0
        return if @@staged_no_evict
        i = oldest_slot
        return if i < 0
        # Evicting reuses a claimed slot: the bit stays set, the record
        # changes.
        @@staged_evictions &+= 1
      end

      @@staged[i] = id
      @@staged_seq[i] = (@@staged_next_seq &+= 1)
      @@staged_total &+= 1
    end

    # Claim a free bit, publishing the slot **before** its id is written. A
    # reader can therefore see a claimed slot holding 0, which every reader
    # here already skips — and releasing clears the id first, so a stale one
    # can never be matched.
    private def self.claim_slot : Int32
      loop do
        claimed = @@staged_claimed.get(:acquire)
        i = 0
        while i < STAGED_SLOTS
          bit = 1_u64 << i
          if (claimed & bit) == 0
            _, won = @@staged_claimed.compare_and_set(claimed, claimed | bit)
            if won
              @@staged[i] = 0_u64
              @@staged_seq[i] = 0_u64
              return i
            end
            break # retry with a fresh mask
          end
          i += 1
        end
        return -1 if i >= STAGED_SLOTS
      end
    end

    private def self.release_slot(i : Int32) : Nil
      @@staged[i] = 0_u64
      @@staged_seq[i] = 0_u64
      Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And,
        pointerof(@@staged_claimed).as(UInt64*), ~(1_u64 << i),
        LLVM::AtomicOrdering::AcquireRelease, false)
    end

    private def self.oldest_slot : Int32
      claimed = @@staged_claimed.get(:acquire)
      best = -1
      best_seq = 0_u64
      i = 0
      while i < STAGED_SLOTS
        if (claimed & (1_u64 << i)) != 0 && @@staged[i] != 0 &&
           (best < 0 || @@staged_seq[i] < best_seq)
          best = i
          best_seq = @@staged_seq[i]
        end
        i += 1
      end
      best
    end

    # Release entries for threads that are already on Crystal's list.
    #
    # `Thread.unsafe_each` without the list mutex, for the same reason
    # `Heap#drain_published_staged` does it: a starting thread publishes by
    # taking that very lock, so waiting on it here would be waiting on the thing
    # being watched. This walk runs on the creating thread and only when the
    # table is full, which on a quiesced program is never.
    private def self.drain_published : Nil
      claimed = @@staged_claimed.get(:acquire)
      i = 0
      while i < STAGED_SLOTS
        if (claimed & (1_u64 << i)) != 0 && (id = @@staged[i]) != 0
          published = false
          Thread.unsafe_each do |thread|
            published = true if thread.to_unsafe.unsafe_as(UInt64) == id
          end
          release_slot(i) if published
        end
        i += 1
      end
    end

    # Research only: restore the behaviour a full table used to have — refuse
    # the birth being handed in, which is the newest one.
    def self.staged_no_evict=(value : Bool) : Bool
      @@staged_no_evict = value
    end

    # Called once the thread is in Crystal's list, or once it has ended — the
    # ordinary path covers the first and nothing needs to cover the second.
    def self.unstage_thread(id : UInt64) : Nil
      return if id == 0
      claimed = @@staged_claimed.get(:acquire)
      i = 0
      while i < STAGED_SLOTS
        if (claimed & (1_u64 << i)) != 0 && @@staged[i] == id
          release_slot(i)
          return
        end
        i += 1
      end
    end

    def self.each_staged(& : UInt64 ->) : Nil
      claimed = @@staged_claimed.get(:acquire)
      i = 0
      while i < STAGED_SLOTS
        if (claimed & (1_u64 << i)) != 0 && (id = @@staged[i]) != 0
          yield id
        end
        i += 1
      end
    end

    # Threads started but not yet seen in Crystal's list. Derived from the
    # occupancy mask and the ids under it: a slot claimed but not yet filled
    # is a birth in flight on another thread, and counting it would make the
    # wait spin for a record that is not there yet.
    def self.staged_count : Int32
      claimed = @@staged_claimed.get(:acquire)
      n = 0
      i = 0
      while i < STAGED_SLOTS
        n += 1 if (claimed & (1_u64 << i)) != 0 && @@staged[i] != 0
        i += 1
      end
      n
    end

    # `GCRY_THREAD_UNSTAGE_ON_DEATH=1` — **a reproducer, not a feature.**
    #
    # Dropping a thread's staging record when it dies is obviously right: a
    # dead thread is not a thread being born, and leaving the record behind
    # makes `wait_for_staged_threads` spend its whole budget on it and then
    # report a timeout. It is also the single change that turned a churn of
    # 960 short-lived threads from 0 crashes in 40 runs into 7.
    #
    # What it removes is an accident. The wait spins 2 000 times before
    # giving up, and those spins sit between a thread calling `detach` and
    # the world stopping around it — which is exactly the window in which
    # `Thread#start`'s `ensure` has already taken the thread off Crystal's
    # list and is still dereferencing it, on a stack gcry does not scan
    # because a thread off the list is one it cannot see. The wait was
    # buying that window time to close. Stop paying, and the collector sweeps
    # something the dying thread still uses: `GCRY_POISON_HOLDERS=1` reports
    # a use-after-free on a 16-byte block with no holder anywhere.
    #
    # A pure delay in the same place does **not** reproduce it (0 of 40 at
    # HEAD with 4 000 `pause` iterations added to `pthread_detach`), so the
    # trigger is the missing wait rather than the timing.
    #
    # So the knob stays off and the defect stays open — but it now has a
    # reproducer that fires in seconds on one box, which is more than the
    # thread family has had since 2026-08-16.
    @@unstage_on_death = uninitialized Bool

    def self.unstage_on_death=(value : Bool) : Bool
      @@unstage_on_death = value
    end

    def self.unstage_on_death(id : UInt64) : Nil
      unstage_thread(id) if @@unstage_on_death
    end

    # Births that found the table full. Not the same as a lost record since
    # 2026-08-22: the full path drains first, and only counts an eviction when
    # that frees nothing.
    def self.staged_overflows : UInt64
      @@staged_overflows
    end

    # Records displaced to make room. This is the number that means a thread was
    # not waited for at the next `stop_world`.
    def self.staged_evictions : UInt64
      @@staged_evictions
    end

    # So a run that stages nothing is distinguishable from one where the hook
    # never ran at all.
    def self.staged_total : UInt64
      @@staged_total
    end
  end
end
