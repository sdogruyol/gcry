module Gcry
  # `Heap`'s `@roots_lock`: a test-and-set spin lock that mutators share
  # among themselves as any spin lock does, and that a stop takes only once
  # the mutators already waiting when it arrived have had it.
  #
  # It was a `Crystal::SpinLock`, which goes to whichever spinner swaps first
  # after a release, and the collector takes it again for every stop within
  # microseconds of restarting the world. A thread looping `GC.collect` next
  # to three busy threads on a 4-vCPU Windows runner kept a thread in
  # `ThreadBirthRoot.arm` -> `delete_root` spinning for over 120 s
  # (`bench/log/linux/2026-09-30-windows-zero-handle/`).
  #
  # A FIFO ticket lock (2026-10-08) cured that and broke something else:
  # every slow `realloc` takes this lock twice (its pin), and with threads
  # outnumbering CPUs a descheduled ticket held up every thread behind it —
  # 16 threads growing arrays on 4 CPUs went from about 1.1 s to 41 s, 24 on
  # 12 CPUs from 1.7 s to 26 s. Mutators need no order among themselves; what
  # starved was a mutator behind the collector. So a mutator counts its
  # arrival before it spins and its acquisition after, and `lock_for_stop`
  # snapshots the arrivals and lets that many acquisitions happen before it
  # competes. It yields the CPU while it waits, so a waiter the OS has
  # descheduled gets to run — the Windows case, where a quantum is about
  # 15 ms — and it gives up waiting after `STOP_DEFER_NS`, so mutators
  # cannot hold a collection off.
  #
  # Atomics rather than `Crystal::SpinLock`: that compiles to nothing under
  # `-Dwithout_mt` off Windows, and C threads add roots whatever Crystal's
  # threading flags say (`@@ranges_lock` in c_abi.cr makes the same choice).
  struct RootsLock
    # Longest a stop defers to the mutators that were waiting when it came:
    # several scheduler quanta, far more than a root-list update takes and
    # small next to a collection that a stream of mutators would otherwise
    # hold off for good.
    STOP_DEFER_NS = 50_000_000_u64

    @held = Atomic(Int32).new(0)
    @arrivals = Atomic(UInt64).new(0_u64)
    @acquisitions = Atomic(UInt64).new(0_u64)

    # A mutator: `add_root`, `delete_root`, `clear_roots`.
    def lock : Nil
      @arrivals.add(1_u64, :relaxed)
      acquire
      @acquisitions.add(1_u64, :relaxed)
    end

    # The stop: after the mutators already waiting, within a bound.
    def lock_for_stop : Nil
      target = @arrivals.get(:relaxed)
      if @acquisitions.get(:relaxed) < target
        deadline = Clock.monotonic_ns &+ STOP_DEFER_NS
        spins = 0
        while @acquisitions.get(:relaxed) < target
          spins += 1
          if spins & 63 == 0
            break if Clock.monotonic_ns > deadline
            Thread.yield
          else
            Intrinsics.pause
          end
        end
      end
      acquire
    end

    def unlock : Nil
      @held.set(0, :release)
    end

    def sync(&)
      lock
      begin
        yield
      ensure
        unlock
      end
    end

    # Mutators spinning for the lock now (specs).
    def waiting : UInt64
      @arrivals.get(:relaxed) &- @acquisitions.get(:relaxed)
    end

    private def acquire : Nil
      loop do
        return if @held.get(:relaxed) == 0 && @held.swap(1, :acquire) == 0
        Intrinsics.pause
      end
    end
  end
end
