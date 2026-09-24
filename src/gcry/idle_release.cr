# Give memory back when the process goes idle. On by default after two minutes
# without an allocation (Linux, Darwin); `GCRY_IDLE_RELEASE_MS=<ms>` moves it,
# `=0` turns it off.
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
#     `thread_suspend`, no signal round trip to save);
#   * its stack **is** scanned, like every thread's. 0.27.0 skipped it on the
#     grounds that it held no GC reference, and that was false: its own
#     thread-entry frames are on it, and Darwin CI (run `35995083083`) freed a
#     block that eight slots of it still held, then faulted on the poison. On
#     Linux, with no SP recorded, the scan starts at the SP it publishes while
#     parked (`parked_sp`), and covers the whole stack while it is awake.
#
# `make idle-release` holds it.

require "./platform/os"
require "./clock"

module Gcry
  module IdleRelease
    # Go forces a collection after two minutes without one; the same period,
    # measured from the last allocation rather than the last collection.
    DEFAULT_MS = 120_000_u64

    @@idle_ns = 0_u64
    @@started = false
    # This thread's stack pointer while it sleeps, 0 while it runs. On Linux
    # it is exempt from the suspend signal, so no stop records its SP; the
    # scan reads this instead (`Heap#other_thread_scan_sp`). Everything above
    # it — `loop_forever` and Crystal's thread-entry frames — is unchanged
    # for as long as it sleeps. 0 means "not parked": scan the whole stack.
    @@parked_sp = Atomic(UInt64).new(0_u64)

    def self.parked_sp : UInt64
      @@parked_sp.get
    end

    # Research only — `GCRY_IDLE_TEST_HOLD=1`, for `make idle-thread-roots`:
    # the thread allocates one block, fills it, and keeps its address only in
    # a stack slot of its own loop frame. The harness learns the address as
    # `address ^ HOLD_KEY`, which roots nothing, and asks whether collections
    # run from other threads keep the block alive.
    HOLD_KEY     = 0x5a5a_a5a5_c3c3_3c3c_u64
    HOLD_PATTERN = 0x1d1e_1d1e_1d1e_1d1e_u64
    HOLD_WORDS   =                        12
    class_property? test_hold : Bool = false
    @@hold_masked = Atomic(UInt64).new(0_u64)

    def self.hold_masked : UInt64
      @@hold_masked.get
    end

    # Is *fiber* the idle collector's? It runs only its thread's main fiber.
    # For the research skip below only.
    def self.fiber?(fiber : Fiber) : Bool
      if t = @@thread
        if main = t.@main_fiber
          return main.same?(fiber)
        end
      end
      false
    end

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

    # Dead stack zeroed below this thread's SP before every park. A thread's
    # SP is scanned with `suspended_sp_slack` (4 KiB) below it, a margin for
    # threads stopped *asynchronously*; this one parks at a point of its own
    # choosing, so that window is pure residue of its earlier, deeper calls —
    # a collection it ran while being born, one it ran at idle. One stale word
    # there, 2 168 B below the published SP, pinned a dropped 200 MB list at
    # every major in 5 runs of 40 (`make idle-rss-after-burst`); with the
    # thread's scan skipped, or the thread off, 0 of 40. 64 KiB also covers
    # most of what the whole-stack scan reads in the moments it is awake.
    SCRUB_BYTES = 65_536_u64
    # Below the SP captured here, so the `memset` frame the clear itself pushes
    # sits in the gap and is not zeroed under it (as `clear_stack_body`).
    SCRUB_SKIP = 256_u64

    private def self.scrub_dead_stack : Nil
      stack = Fiber.current.@stack
      floor = stack.pointer.address + Platform.host_page_size
      sp = Roots.hardware_stack_pointer.address
      return if sp <= floor + SCRUB_SKIP
      high = sp - SCRUB_SKIP
      low = high > floor + SCRUB_BYTES ? high - SCRUB_BYTES : floor
      return if low >= high
      Pointer(UInt8).new(low).clear(high - low)
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
      # The research hold: one volatile stack slot in this frame, above the SP
      # published while parked, is the block's only reference.
      held = 0_u64
      if @@test_hold
        block = GC.malloc(HOLD_WORDS * 8).as(UInt64*)
        HOLD_WORDS.times { |i| block[i] = HOLD_PATTERN }
        Atomic::Ops.store(pointerof(held), block.address, :monotonic, true)
        @@hold_masked.set(block.address ^ HOLD_KEY)
        block = Pointer(UInt64).null
      end
      loop do
        scrub_dead_stack
        @@parked_sp.set(Roots.hardware_stack_pointer.address)
        Gcry::OS.nanosleep(pointerof(req), pointerof(rem))
        @@parked_sp.set(0_u64)
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
