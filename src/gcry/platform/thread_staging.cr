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
    STAGED_SLOTS = 64

    @@staged = uninitialized StaticArray(UInt64, STAGED_SLOTS)
    @@staged_used = uninitialized StaticArray(Bool, STAGED_SLOTS)
    # Birth order, so "oldest" is a fact rather than a slot index. Slots are
    # reused out of order, so position says nothing.
    @@staged_seq = uninitialized StaticArray(UInt64, STAGED_SLOTS)
    @@staged_next_seq = uninitialized UInt64
    @@staged_count = uninitialized Int32
    @@staged_overflows = uninitialized UInt64
    @@staged_evictions = uninitialized UInt64
    @@staged_no_evict = uninitialized Bool
    @@staged_total = uninitialized UInt64

    # Called once from `GC.init`, on the main thread, before any thread exists.
    def self.init_staging : Nil
      i = 0
      while i < STAGED_SLOTS
        @@staged[i] = 0_u64
        @@staged_used[i] = false
        @@staged_seq[i] = 0_u64
        i += 1
      end
      @@staged_next_seq = 0_u64
      @@staged_count = 0
      @@staged_overflows = 0_u64
      @@staged_evictions = 0_u64
      @@staged_no_evict = false
      @@staged_total = 0_u64
    end

    # From the creating thread, right after `pthread_create` returns.
    def self.stage_thread(id : UInt64) : Nil
      return if id == 0
      i = free_slot
      if i < 0
        # Full. Almost always because entries are sitting here for threads that
        # published long ago and nothing has looked since the last collection,
        # so look now.
        @@staged_overflows &+= 1
        drain_published
        i = free_slot
      end

      if i < 0
        return if @@staged_no_evict
        i = oldest_slot
        return if i < 0
        # Evicting keeps the count: one record replaces another.
        @@staged_evictions &+= 1
      else
        @@staged_count += 1
      end

      @@staged[i] = id
      @@staged_seq[i] = (@@staged_next_seq &+= 1)
      @@staged_used[i] = true
      @@staged_total &+= 1
    end

    private def self.free_slot : Int32
      i = 0
      while i < STAGED_SLOTS
        return i unless @@staged_used[i]
        i += 1
      end
      -1
    end

    private def self.oldest_slot : Int32
      best = -1
      best_seq = 0_u64
      i = 0
      while i < STAGED_SLOTS
        if @@staged_used[i] && (best < 0 || @@staged_seq[i] < best_seq)
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
      i = 0
      while i < STAGED_SLOTS
        if @@staged_used[i] && (id = @@staged[i]) != 0
          published = false
          Thread.unsafe_each do |thread|
            published = true if thread.to_unsafe.unsafe_as(UInt64) == id
          end
          if published
            @@staged_used[i] = false
            @@staged[i] = 0_u64
            @@staged_seq[i] = 0_u64
            @@staged_count -= 1
          end
        end
        i += 1
      end
    end

    # Research only: restore the behaviour a full table used to have — refuse
    # the birth being handed in, which is the newest one.
    def self.staged_no_evict=(value : Bool) : Bool
      @@staged_no_evict = value
    end

    # Called once the thread is in Crystal's list — the ordinary path covers it
    # from there.
    def self.unstage_thread(id : UInt64) : Nil
      i = 0
      while i < STAGED_SLOTS
        if @@staged_used[i] && @@staged[i] == id
          @@staged_used[i] = false
          @@staged[i] = 0_u64
          @@staged_seq[i] = 0_u64
          @@staged_count -= 1
          return
        end
        i += 1
      end
    end

    def self.each_staged(& : UInt64 ->) : Nil
      i = 0
      while i < STAGED_SLOTS
        yield @@staged[i] if @@staged_used[i] && @@staged[i] != 0
        i += 1
      end
    end

    # Threads started but not yet seen in Crystal's list.
    def self.staged_count : Int32
      n = @@staged_count
      n < 0 ? 0 : n
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
