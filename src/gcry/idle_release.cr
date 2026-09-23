# Give memory back when the process goes idle. Opt-in:
# `GCRY_IDLE_RELEASE_MS=<ms>`.
#
# Nothing in gcry runs without an allocation to drive it, so a process that
# stops allocating keeps what its last cycle left: the warm budget the sweep
# keeps so the next cycle does not fault its chunks back in, the unmap grace,
# and every object that died since that cycle — marked allocated in `occ`
# until a sweep says otherwise. Measured on Kemal `/json`: 19.9 MB idle against
# 13.3 MB after `/gc-collect` and Boehm's 13.4 MB
# (`bench/log/linux/2026-09-23-idle-rss-grace/FINDINGS.md`).
#
# So once the process has allocated nothing for the configured time, this runs
# one collection that releases, exactly as `GC.collect` does — the idea behind
# Go's forced GC every two minutes and G1's periodic collection (JEP 346). Once
# per idle stretch; the next allocation re-arms it.
#
# It is a **Crystal** thread, not a raw pthread like the STW watchdog, because
# the collection it runs needs one: `stop_world` skips `Thread.current`, the
# root scan reads `Fiber.current`, and on a raw pthread Crystal's
# `Thread.current` *creates* a `Thread` — allocating, and pushing onto the list
# the stop walks, from inside the collector. Collecting from a thread other
# than main is the ordinary path already (any Parallel worker does it). What
# makes this thread different is kept out of the way explicitly:
#
#   * it is not a mutator, so `multi_mutator_threads?` does not count it —
#     otherwise one idle thread would switch a single-threaded program into the
#     multi-mutator sweep, which turns empty-chunk release off;
#   * it has no scheduler or event loop, so its collections leave finalizers
#     queued for the next ordinary collection (`Heap#idle_collect`);
#   * it sleeps in `nanosleep`, not Crystal's `sleep`, for the same reason;
#   * on Linux it is exempt from the suspend signal, like the Monitor: a stop
#     does not wait for a thread that is asleep. Between collections it only
#     reads (`Heap#allocation_activity`), and it waits out another thread's
#     stop before it collects. Darwin suspends it with the rest (Mach
#     `thread_suspend`, no signal round trip to save).
#
# `make idle-release` holds it.

require "./platform/os"
require "./clock"

module Gcry
  module IdleRelease
    @@idle_ns = 0_u64
    @@started = false
    @@thread : Thread? = nil

    def self.idle_ms=(ms : UInt64) : Nil
      @@idle_ns = ms * 1_000_000_u64
    end

    def self.idle_ms : UInt64
      @@idle_ns // 1_000_000_u64
    end

    def self.armed? : Bool
      @@idle_ns > 0
    end

    # Is *thread* the idle collector? For the heuristics that count mutators.
    def self.thread?(thread : Thread) : Bool
      if t = @@thread
        t.same?(thread)
      else
        false
      end
    end

    # Is *fiber* the idle collector's? It runs only its thread's main fiber.
    def self.fiber?(fiber : Fiber) : Bool
      if t = @@thread
        if main = t.@main_fiber
          return main.same?(fiber)
        end
      end
      false
    end

    # A forked child has only the thread that called `fork`; start again at
    # its first collection.
    def self.after_fork_child : Nil
      @@thread = nil
      @@started = false
    end

    # From the end of a collection, on the mutator that ran it: the world is
    # running, the post-STW lock is released and the finalizers have run, so
    # the allocation `Thread.new` does cannot re-enter a cycle this thread is
    # in the middle of. `@@started` first, so a collection that allocation
    # triggers returns here at once.
    def self.ensure_started : Nil
      return unless armed?
      return if @@started
      @@started = true
      # Not `gcry-`: that prefix tells the thread census a thread is one of
      # gcry's raw helpers, outside Crystal's list. This one is on the list.
      @@thread = Thread.new(name: "gc-idle") { loop_forever }
    end

    def self.loop_forever : Nil
      # Poll at a quarter of the idle time, clamped: the collection lands
      # within ~1.25x the configured delay, and an idle process wakes a few
      # times a second at most.
      poll = @@idle_ns // 4
      poll = 10_000_000_u64 if poll < 10_000_000_u64
      poll = 1_000_000_000_u64 if poll > 1_000_000_000_u64
      req = uninitialized Gcry::OS::Timespec
      req.tv_sec = typeof(req.tv_sec).new(poll // 1_000_000_000_u64)
      req.tv_nsec = typeof(req.tv_nsec).new(poll % 1_000_000_000_u64)
      rem = uninitialized Gcry::OS::Timespec

      heap = Gcry.default_heap
      # Includes what cursor sets have allocated but not yet credited, so
      # allocation inside a cursor chunk counts, and writes nothing.
      last_total = heap.allocation_activity
      last_change = Clock.monotonic_ns
      collected = false
      loop do
        Gcry::OS.nanosleep(pointerof(req), pointerof(rem))
        total = heap.allocation_activity
        now = Clock.monotonic_ns
        if total != last_total
          last_total = total
          last_change = now
          collected = false
          next
        end
        next if collected
        next if now - last_change < @@idle_ns
        heap.idle_collect
        collected = true
        # The collection's own bookkeeping is not the mutator waking up.
        last_total = heap.allocation_activity
      end
    end
  end
end
