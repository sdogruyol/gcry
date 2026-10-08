require "../../src/gcry"
require "spec"

# Two collector locks were unfair to a waiter under back-to-back collections
# (Windows CI, 2026-09-30; `bench/log/linux/2026-09-30-windows-zero-handle/`).
#
# The collection section was a bare `pthread_mutex_t` — an SRWLock on Windows —
# and neither hands over: a thread looping `GC.collect` dropped it and took it
# back before the waiter it woke had run. Linux shows it too. With 1, 3 or 6
# threads looping `GC.collect`, another thread's 100 calls each waited through
# up to 1 174, 4 727 and 1 383 collections (12.7, 83.4 and 14.8 on average).
# The section now goes to waiters in arrival order, and a call returns once a
# full collection that began after it has finished, whichever thread ran it —
# Boehm's guarantee for `GC_gcollect` — so the calls queued behind one
# collection share the next instead of running one each. The same 100 calls
# then wait through at most 2 collections, 1.01 to 1.03 on average.
#
# `@roots_lock` was a `Crystal::SpinLock`, taken by every stop and by
# `add_root` / `delete_root`. A thread starting a thread spun on it for over
# 120 s on a 4-vCPU Windows runner while another collected back to back and
# busy threads took the other CPUs. It hands out tickets now. Linux does not
# reproduce that one: before the fix, two million add/remove pairs beside a
# thread collecting back to back waited through at most one of its 3 468
# collections each. Its stop waits for every thread to acknowledge the resume
# signal, so a resumed waiter is running before the collector can take the
# lock again; `ResumeThread` and `thread_resume` wait for nothing. The last
# example pins the property that closes it, in code that is the same on every
# platform, and this file runs in the Windows job's process specs as well.

# Collections begun and finished, counted by the hook below. Module state and
# a non-capturing proc: the hook lives on the process heap, which is not in
# the GC heap, so a closure it held would be unrooted.
private module CollectionCount
  @@starts = Atomic(Int64).new(0_i64)
  @@ends = Atomic(Int64).new(0_i64)

  def self.starts : Int64
    @@starts.get
  end

  def self.ends : Int64
    @@ends.get
  end

  def self.note(event : Gcry::Heap::CollectionEvent) : Nil
    case event
    when .start? then @@starts.add(1_i64)
    when .end?   then @@ends.add(1_i64)
    else
    end
  end
end

# A `Gcry::TicketLock` in a class, so the threads share one lock and not
# copies of a struct.
private class SharedTicketLock
  @lock = Gcry::TicketLock.new

  def lock : Nil
    @lock.lock
  end

  def unlock : Nil
    @lock.unlock
  end

  def queued : UInt32
    @lock.queued
  end
end

# Threads that each call `GC.collect` back to back with no gap, as the
# Windows sightings' collector did, and one that adds and removes a root in a
# loop meanwhile, so the roots lock is contended between stops as a thread
# start contends it. Every thread's calls are counted, not one victim's: with
# a lock that does not hand over, whichever thread holds it keeps it, and the
# rest wait out its calls — which thread that is changes from run to run.
# Finite calls, so a regression shows as a count rather than as a hang.
private COLLECTORS =   4
private CALLS      = 100
# A call waits through the collection in flight when it arrives and the one
# that answers it. One more can finish before the caller reads the count, if
# the stop of a collection queued behind it freezes the caller on its way
# out, and once more is only that again. Before the fix: up to all of
# another thread's calls, 100 here.
private WAIT_BOUND = 4

describe "GC.collect and the roots lock with peers collecting back to back" do
  it "answers every call with a collection begun after it, within a bounded wait, sharing collections" do
    heap = Gcry.default_heap
    previous_hook = heap.collection_event_hook
    # Class variables initialise on first read; do that here, not in the hook.
    CollectionCount.starts
    CollectionCount.ends
    heap.collection_event_hook = ->(event : Gcry::Heap::CollectionEvent) { CollectionCount.note(event) }
    satisfied_before = heap.collect_satisfied_by_peer
    unanswered = Atomic(Int32).new(0)
    # Most collections one thread's call or root pair waited through; the
    # last slot is the root thread's.
    worst = Array.new(COLLECTORS + 1, 0_u64)
    ready = Atomic(Int32).new(0)
    done = Atomic(Int32).new(0)
    threads = Array.new(COLLECTORS) do |i|
      Thread.new do
        ready.add(1)
        until ready.get > COLLECTORS
          Thread.yield
        end
        CALLS.times do
          started = CollectionCount.starts
          majors = heap.major_collections
          GC.collect
          # Collections are serialized, so the n-th `End` closes the n-th
          # `Start`: one that began after the call has ended iff this holds.
          unanswered.add(1) unless CollectionCount.ends > started
          waited = heap.major_collections - majors
          worst[i] = waited if waited > worst[i]
        end
        done.add(1)
      end
    end
    threads << Thread.new do
      root = Pointer(Void).malloc(16)
      ready.add(1)
      until done.get == COLLECTORS
        majors = heap.major_collections
        heap.add_root(root)
        heap.delete_root(root)
        waited = heap.major_collections - majors
        worst[COLLECTORS] = waited if waited > worst[COLLECTORS]
      end
    end
    begin
      threads.each(&.join)
    ensure
      heap.collection_event_hook = previous_hook
    end

    unanswered.get.should eq(0)
    worst.max.should be <= WAIT_BOUND
    (heap.collect_satisfied_by_peer - satisfied_before).should be > 0
  end

  it "serves the roots lock in arrival order, so its holder cannot take it back ahead of a waiter" do
    lock = SharedTicketLock.new
    overtaken = 0
    100.times do
      waiter_entered = Atomic(Int32).new(0)
      lock.lock
      waiter = Thread.new do
        lock.lock
        waiter_entered.set(1)
        lock.unlock
      end
      # The waiter has its ticket: two taken, the holder's and its own.
      until lock.queued == 2
        Thread.yield
      end
      lock.unlock
      lock.lock
      overtaken += 1 if waiter_entered.get == 0
      lock.unlock
      waiter.join
    end
    overtaken.should eq(0)
  end
end
