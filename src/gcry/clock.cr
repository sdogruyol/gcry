# The monotonic clock reading, for code that must not allocate.
#
# `Time.monotonic` is deprecated in favour of `Time.instant`, and `Time::Instant`
# is deliberately opaque — the only value it yields is a `Time::Span` between two
# readings. Everything here wants a bare nanosecond count it can subtract, store
# in a `UInt64` counter, or write into a trace line from inside the stopped
# world, so it reads the clock directly instead.
#
# Four copies of these three lines had accumulated (`Collector`, `MonitorGate`,
# `StwWatchdog`, and the trace emitter) before this existed. Same reason
# `RawOut` exists.
module Gcry
  module Clock
    # CLOCK_MONOTONIC: never goes backwards, but does not count time the system
    # spent suspended. Callers that subtract two readings should still saturate
    # rather than trust the order — a checked `UInt64` subtract raises on a
    # backward jump, seen in Linux CI at_exit after STW.
    @[AlwaysInline]
    def self.monotonic_ns : UInt64
      ts = uninitialized LibC::Timespec
      LibC.clock_gettime(LibC::CLOCK_MONOTONIC, pointerof(ts))
      ts.tv_sec.to_u64 * 1_000_000_000_u64 + ts.tv_nsec.to_u64
    end
  end
end
