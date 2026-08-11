# Keep the EC Monitor out of the stopped world.
#
# `Heap#stop_world` does not signal-suspend the Monitor (SYSMON) — the recorded
# reason is that resume races left it in `sigsuspend` forever — and instead
# assumed it would cooperate by blocking in `allocate` / `lock_read`. Measured,
# it does not: through a 4 s stop the Monitor woke ~100 times a second, and it ran
# `StackPool#collect` — `Crystal::System::Fiber.free_stack`, i.e. munmap — *inside*
# the stop, while the collector was in its thread-stacks phase.
# `bench/log/linux/2026-08-11-sysmon-runs-during-stw/FINDINGS.md`.
#
# An entry check alone is not enough: it stops the Monitor *starting* work during
# a stop, but work already in flight when the world stops keeps running (the
# observed `collect_stacks` took 250 µs). So this is a handshake, and both halves
# are needed:
#
#   Monitor:  busy = 1 ; if stopped { busy = 0 ; wait until !stopped ; retry }
#   stop_world: stopped = 1 ; wait until busy == 0
#
# Both sides store before they load, which is the one shape where a relaxed
# ordering would let both proceed, so every access here is sequentially
# consistent. Liveness comes from the Monitor backing off — it clears `busy`
# before waiting, so it can never hold the collector while waiting for it.
#
# `GCRY_MONITOR_GATE=0` turns it off for A/B. Off is the old behaviour, i.e. the
# Monitor runs inside the stopped world.

module Gcry
  module MonitorGate
    @@enabled = true
    @@stopped = Atomic(Int32).new(0)
    @@busy = Atomic(Int32).new(0)

    # Times stop_world had to wait for work the Monitor had already started, and
    # the worst one. This is the pause the handshake *adds*, so it must not be a
    # number anyone has to guess at.
    @@stw_waits = 0_u64
    @@stw_wait_ns = 0_u64
    @@stw_wait_max_ns = 0_u64
    # Times the Monitor was held off at the gate.
    @@monitor_blocks = 0_u64

    def self.enabled? : Bool
      @@enabled
    end

    def self.enabled=(value : Bool) : Bool
      @@enabled = value
    end

    def self.stw_waits : UInt64
      @@stw_waits
    end

    def self.stw_wait_ns : UInt64
      @@stw_wait_ns
    end

    def self.stw_wait_max_ns : UInt64
      @@stw_wait_max_ns
    end

    def self.monitor_blocks : UInt64
      @@monitor_blocks
    end

    # Collector side. Call *before* touching anything the Monitor could be
    # mutating, and pair with `open`.
    def self.close : Nil
      return unless @@enabled
      @@stopped.set(1)

      return if @@busy.get == 0

      # The Monitor was already inside its work. Wait it out — bounded by that
      # one call, because the handshake keeps it from starting another.
      t0 = now_ns
      while @@busy.get != 0
        Intrinsics.pause
      end
      waited = now_ns - t0
      @@stw_waits += 1
      @@stw_wait_ns += waited
      @@stw_wait_max_ns = waited if waited > @@stw_wait_max_ns
    end

    def self.open : Nil
      @@stopped.set(0)
    end

    # Monitor side.
    def self.enter : Nil
      return unless @@enabled
      loop do
        @@busy.set(1)
        return if @@stopped.get == 0

        # Back off first: holding `busy` while waiting for the world to restart
        # would deadlock against a collector waiting for `busy` to clear.
        @@busy.set(0)
        @@monitor_blocks += 1
        while @@stopped.get != 0
          Intrinsics.pause
        end
      end
    end

    def self.leave : Nil
      @@busy.set(0)
    end

    private def self.now_ns : UInt64
      ts = uninitialized LibC::Timespec
      LibC.clock_gettime(LibC::CLOCK_MONOTONIC, pointerof(ts))
      ts.tv_sec.to_u64 * 1_000_000_000_u64 + ts.tv_nsec.to_u64
    end
  end
end

# The three things `Monitor#run_loop` calls every ~10 ms. Each is wrapped rather
# than the loop itself: `run_loop` never returns, so there is no point at which a
# wrapper around it could check anything. No compiler fork — reopening the class
# and calling `previous_def` is ordinary Crystal, verified to take effect.
# Only for the process GC: a library heap never stops the world, so there is
# nothing to shut the Monitor out of and no reason to reach into the stdlib.
{% if flag?(:gc_none) && @top_level.has_constant?("Fiber") && Fiber.has_constant?("ExecutionContext") && Fiber::ExecutionContext.has_constant?("Monitor") %}
  class Fiber::ExecutionContext::Monitor
    private def transfer_schedulers_blocked_on_syscall
      Gcry::MonitorGate.enter
      begin
        previous_def
      ensure
        Gcry::MonitorGate.leave
      end
    end

    private def increase_parallelism(now)
      Gcry::MonitorGate.enter
      begin
        previous_def
      ensure
        Gcry::MonitorGate.leave
      end
    end

    private def collect_stacks(now)
      Gcry::MonitorGate.enter
      begin
        previous_def
      ensure
        Gcry::MonitorGate.leave
      end
    end
  end
{% end %}
