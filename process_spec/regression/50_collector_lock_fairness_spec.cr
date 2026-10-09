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
# busy threads took the other CPUs. A stop now lets the mutators already
# waiting go first (`Gcry::RootsLock#lock_for_stop`). A FIFO ticket lock did
# that too, and convoyed every slow `realloc` (whose pin takes this lock
# twice) once threads outnumbered CPUs: 16 threads growing arrays on 4 CPUs
# went from about 1.1 s to 41 s. Linux does not reproduce the starvation:
# its stop waits for every thread to acknowledge the resume signal, so a
# resumed waiter is running before the collector can take the lock again;
# `ResumeThread` and `thread_resume` wait for nothing. The last examples pin
# the property that closes it, in code that is the same on every platform,
# and this file runs in the Windows job's process specs as well.

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

# A `Gcry::RootsLock` in a class, so the threads share one lock and not
# copies of a struct.
private class SharedRootsLock
  @lock = Gcry::RootsLock.new

  def lock : Nil
    @lock.lock
  end

  def lock_for_stop : Nil
    @lock.lock_for_stop
  end

  def unlock : Nil
    @lock.unlock
  end

  def waiting : UInt64
    @lock.waiting
  end
end

# Threads that each call `GC.collect` back to back with no gap, as the
# Windows sightings' collector did, and one that adds and removes a root in a
# loop meanwhile, so the roots lock is contended between stops as a thread
# start contends it. Every thread's calls are counted, not one victim's: with
# a lock that does not hand over, whichever thread holds it keeps it, and the
# rest wait out its calls — which thread that is changes from run to run.
# Finite calls, so a regression shows as a count rather than as a hang.
private COLLECTORS = 4
# 30 calls each: a whole `process_spec` heap makes every collection slow, and
# 100 took 25–40 s there (7 min on the aarch64 runner's freelist arm).
private CALLS = 30
# A call waits through the collection in flight when it arrives and the one
# that answers it: 1–2, about 1.1 on average. What the count cannot tell from
# unfairness is a caller the OS leaves off the CPU: a thread frozen by a stop
# before it queues, or on its way out, sees every collection that runs
# meanwhile, and on macOS and Windows a resumed thread is not waited for, so
# back-to-back stops can hold it through several. One call saw 5 on macos
# x86_64 CI (2026-10-08) and 11 on the next run (2026-10-09), which a bound on
# the worst call cannot tell from the defect. The mean over every call can:
# before the fix it was 2.5–2.7 with 12 CPUs and 3.1–3.6 with 2, and after it
# 1.06–1.36, 2 CPUs with four busy loops beside them included; a freeze that
# costs one call 11 moves the mean of 120 by under 0.1.
private MEAN_WAIT_BOUND = 2.0
# The root thread's pairs wait through no collection at all unless frozen. The
# Windows defect kept one out for over 120 s of back-to-back collections; this
# catches that and not a freeze. Mutators going ahead of a stop is the next
# example's.
private ROOT_WAIT_BOUND = 30_u64

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
    # Most collections one thread's call or root pair waited through, and the
    # collectors' total; the last slot is the root thread's.
    worst = Array.new(COLLECTORS + 1, 0_u64)
    waited_total = Array.new(COLLECTORS, 0_u64)
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
          waited_total[i] += waited
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
    mean = waited_total.sum.to_f / (COLLECTORS * CALLS)
    seen = "mean #{mean.round(2)}, worst call per collector #{worst[0, COLLECTORS]}, root thread #{worst[COLLECTORS]}"
    fail "collect waits: #{seen}" unless mean <= MEAN_WAIT_BOUND
    fail "root waits: #{seen}" unless worst[COLLECTORS] <= ROOT_WAIT_BOUND
    (heap.collect_satisfied_by_peer - satisfied_before).should be > 0
  end

  it "lets a mutator already waiting for the roots lock in ahead of the next stop" do
    lock = SharedRootsLock.new
    overtaken = 0
    100.times do
      waiter_entered = Atomic(Int32).new(0)
      lock.lock_for_stop
      waiter = Thread.new do
        lock.lock
        waiter_entered.set(1)
        lock.unlock
      end
      until lock.waiting == 1
        Thread.yield
      end
      # The stop lets go and comes straight back, as a collector looping
      # `GC.collect` does.
      lock.unlock
      lock.lock_for_stop
      overtaken += 1 if waiter_entered.get == 0
      lock.unlock
      waiter.join
    end
    # A plain spin lock let the stop back in first in 81–100 of 100 rounds.
    # The stop defers for a bounded spin only, so a waiter the OS happens to
    # deschedule for longer than that is overtaken; that is rare.
    overtaken.should be <= 5
  end

  # Mutators keep no order among themselves, so a descheduled one holds up
  # no one: with 3 threads per CPU taking and dropping the lock as a slow
  # `realloc`'s pin does, they all finish at the pace of a plain spin lock.
  # The ticket lock that came before took 30–40× as long here.
  it "does not convoy mutators when threads outnumber CPUs" do
    lock = SharedRootsLock.new
    threads = System.cpu_count.to_i * 3
    rounds = 20_000
    shared = Pointer(Int64).malloc(1)
    started = Time.instant
    workers = Array.new(threads) do
      Thread.new do
        rounds.times do
          lock.lock
          shared.value &+= 1
          lock.unlock
        end
      end
    end
    workers.each(&.join)
    shared.value.should eq(threads.to_i64 * rounds)
    (Time.instant - started).should be < 10.seconds
  end
end
