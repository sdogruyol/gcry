require "../../src/gcry"
require "spec"

# A finalizer that suspends its fiber does not stop automatic collection on
# the others. Until 2026-10-10 the guard against a collection inside a
# finalizer was one heap-wide flag, set for the whole of any `run_pending`:
# while one fiber's finalizer waited on a channel, no allocation anywhere
# collected. Measured on master: 2 000 × 1 MiB `Bytes` on the main fiber
# behind such a finalizer made 0 automatic collections and a 2 010 MiB heap;
# without the wait, 85 collections and 27 MiB.
private module ParkedFinalizerLog
  class_property parked = false
  class_property drainer_done = false
  class_getter gate = Channel(Nil).new
end

private class ParkedFinalizerWaiter
  def finalize
    ParkedFinalizerLog.parked = true
    ParkedFinalizerLog.gate.receive
  end
end

# Far past any threshold the process heap adapts to (18's 64 MiB), and
# bounded, so a refused collection costs memory rather than the suite.
private PARKED_FINALIZER_MAX_MIB = 256

@[NoInline]
private def parked_finalizer_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

# Built on a fiber of its own, as in 44, so no stale word on the example's
# stack keeps it.
private def parked_finalizer_build : Nil
  done = Channel(Nil).new
  spawn do
    ParkedFinalizerWaiter.new
    parked_finalizer_scrub
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

describe "Regression: a finalizer parked on another fiber" do
  it "leaves automatic collection to the fibers that are not draining" do
    heap = Gcry.default_heap
    parked_finalizer_build
    spawn do
      # A stale word may keep the waiter through one collection.
      10.times do
        break if ParkedFinalizerLog.parked
        GC.collect
      end
      ParkedFinalizerLog.drainer_done = true
    end
    until ParkedFinalizerLog.parked || ParkedFinalizerLog.drainer_done
      Fiber.yield
    end
    ParkedFinalizerLog.parked.should be_true

    begin
      before = heap.collections
      sink = nil.as(Bytes?)
      PARKED_FINALIZER_MAX_MIB.times do
        sink = Bytes.new(1024 * 1024)
        break if heap.collections > before
      end
      sink.should_not be_nil
      heap.collections.should be > before
    ensure
      # Always released, so a red run fails instead of hanging the suite.
      ParkedFinalizerLog.gate.send(nil)
      until ParkedFinalizerLog.drainer_done
        Fiber.yield
      end
    end
  end
end
