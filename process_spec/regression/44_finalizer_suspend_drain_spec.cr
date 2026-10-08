require "../../src/gcry"
require "spec"

# A finalizer that suspends its fiber does not stop another fiber on the same
# thread from draining the queue. Until 2026-10-08 the guard against nested
# `run_pending` was a thread-local flag: while the draining fiber waited in a
# finalizer, every other fiber on the thread saw the flag set and skipped the
# queue, so nothing else was finalized and the queued objects stayed rooted.
private module SuspendDrainLog
  class_property ran = 0
  class_property blocked = false
  class_property drainer : Fiber? = nil
  class_getter gate = Channel(Nil).new
end

private class SuspendDrainFinalizable
  def finalize
    # Only the first finalizer the drainer fiber runs waits; any other runs
    # straight through.
    if Fiber.current.same?(SuspendDrainLog.drainer) && !SuspendDrainLog.blocked
      SuspendDrainLog.blocked = true
      SuspendDrainLog.gate.receive
    end
    SuspendDrainLog.ran += 1
  end
end

private SUSPEND_DRAIN_COUNT = 200

@[NoInline]
private def suspend_drain_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

# Built on a fiber of its own, as in `26_pending_finalizer_root_spec`, so no
# stale word on the example's stack keeps one of them.
private def suspend_drain_build : Nil
  done = Channel(Nil).new
  spawn do
    SUSPEND_DRAIN_COUNT.times { SuspendDrainFinalizable.new }
    suspend_drain_scrub
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

describe "Regression: a finalizer that suspends its fiber" do
  it "leaves the rest of the queue to other fibers on the thread" do
    suspend_drain_build
    drainer = spawn { GC.collect }
    SuspendDrainLog.drainer = drainer
    Fiber.yield
    SuspendDrainLog.blocked.should be_true

    5.times { GC.collect }
    # Every one but the waiting finalizer; a stale word can still hold one
    # or two of them conservatively.
    SuspendDrainLog.ran.should be >= SUSPEND_DRAIN_COUNT - 8
    SuspendDrainLog.gate.send(nil)
    Fiber.yield
  end
end
