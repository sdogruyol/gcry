module Gcry
  # A FIFO spin lock: `lock` takes the next ticket and spins until that ticket
  # is the one being served, so waiters enter in the order they arrived.
  #
  # `Heap`'s `@roots_lock` is one. It was a `Crystal::SpinLock`, which goes to
  # whichever spinner swaps first after a release, and the collector takes it
  # again for every stop within microseconds of restarting the world. A
  # thread looping `GC.collect` next to three busy threads on a 4-vCPU Windows
  # runner kept a thread in `ThreadBirthRoot.arm` -> `delete_root` spinning
  # for over 120 s (`bench/log/linux/2026-09-30-windows-zero-handle/`). With
  # tickets, the next stop queues behind that thread instead.
  #
  # Atomics rather than `Crystal::SpinLock`: that compiles to nothing under
  # `-Dwithout_mt` off Windows, and C threads add roots whatever Crystal's
  # threading flags say (`@@ranges_lock` in c_abi.cr makes the same choice).
  #
  # What a ticket costs that a spin lock did not: a waiter keeps its place
  # while it is not running. `Heap#stop_world_quiescing_roots` explains why a
  # waiter the stop freezes cannot wedge the stop.
  struct TicketLock
    @next = Atomic(UInt32).new(0_u32)
    @serving = Atomic(UInt32).new(0_u32)

    def lock : Nil
      ticket = @next.add(1_u32, :acquire)
      until @serving.get(:acquire) == ticket
        Intrinsics.pause
      end
    end

    def unlock : Nil
      @serving.add(1_u32, :release)
    end

    def sync(&)
      lock
      begin
        yield
      ensure
        unlock
      end
    end

    # Tickets taken and not yet released, the holder's included.
    def queued : UInt32
      @next.get(:acquire) &- @serving.get(:acquire)
    end
  end
end
