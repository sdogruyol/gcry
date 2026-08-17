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
    STAGED_SLOTS = 64

    @@staged = uninitialized StaticArray(UInt64, STAGED_SLOTS)
    @@staged_used = uninitialized StaticArray(Bool, STAGED_SLOTS)
    @@staged_count = uninitialized Int32
    @@staged_overflows = uninitialized UInt64
    @@staged_total = uninitialized UInt64

    # Called once from `GC.init`, on the main thread, before any thread exists.
    def self.init_staging : Nil
      i = 0
      while i < STAGED_SLOTS
        @@staged[i] = 0_u64
        @@staged_used[i] = false
        i += 1
      end
      @@staged_count = 0
      @@staged_overflows = 0_u64
      @@staged_total = 0_u64
    end

    # From the creating thread, right after `pthread_create` returns.
    def self.stage_thread(id : UInt64) : Nil
      return if id == 0
      i = 0
      while i < STAGED_SLOTS
        unless @@staged_used[i]
          @@staged[i] = id
          @@staged_used[i] = true
          @@staged_count += 1
          @@staged_total &+= 1
          return
        end
        i += 1
      end
      # Counted rather than dropped silently: "nothing staged" must never be
      # the result of having stopped recording.
      @@staged_overflows &+= 1
    end

    # Called once the thread is in Crystal's list — the ordinary path covers it
    # from there.
    def self.unstage_thread(id : UInt64) : Nil
      i = 0
      while i < STAGED_SLOTS
        if @@staged_used[i] && @@staged[i] == id
          @@staged_used[i] = false
          @@staged[i] = 0_u64
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

    def self.staged_overflows : UInt64
      @@staged_overflows
    end

    # So a run that stages nothing is distinguishable from one where the hook
    # never ran at all.
    def self.staged_total : UInt64
      @@staged_total
    end
  end
end
