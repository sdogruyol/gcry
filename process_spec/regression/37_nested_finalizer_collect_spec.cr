require "../../src/gcry"
require "spec"

# A finalizer that calls `GC.collect` runs no other finalizer inside that
# collection: the thread's outer `run_pending` drains the queue. Since
# 2026-10-06 `run_pending` takes one node off the queue at a time, so the
# collection a finalizer started ended in a second `run_pending`, which ran
# the next queued finalizer one level deeper, and so on: nesting as deep as
# the queue was long. 200 such objects nested 199 deep; 5 000 overflowed the
# stack on Windows. Boehm bounds the same recursion per thread
# (`GC_check_finalizer_nested`).
private module NestedCollectLog
  @@depth = 0
  @@max_depth = 0
  @@ran = 0

  def self.ran : Int32
    @@ran
  end

  def self.max_depth : Int32
    @@max_depth
  end

  def self.enter : Nil
    @@depth += 1
    @@max_depth = @@depth if @@depth > @@max_depth
  end

  def self.leave : Nil
    @@depth -= 1
    @@ran += 1
  end
end

private class NestedCollectFinalizable
  def finalize
    NestedCollectLog.enter
    GC.collect
    NestedCollectLog.leave
  end
end

private NESTED_COLLECT_COUNT = 2_000

@[NoInline]
private def nested_collect_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

# Built on a fiber of its own, as in `26_pending_finalizer_root_spec`, so no
# stale word on the example's stack keeps one of them.
private def nested_collect_build : Nil
  done = Channel(Nil).new
  spawn do
    NESTED_COLLECT_COUNT.times { NestedCollectFinalizable.new }
    nested_collect_scrub
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

describe "Regression: a finalizer that collects" do
  # In a process of its own: before the fix the deep end of the nesting was a
  # stack overflow, which would take the whole suite down.
  it "does not run the queued finalizers nested inside its collection" do
    captured = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!, ["-e", "nested-finalizer-collect child"],
      env: {"GCRY_NESTED_FINALIZER_CHILD" => "1"}, output: captured, error: captured)
    fail captured.to_s unless status.success?
    captured.to_s.should contain("1 examples, 0 failures")
  end

  # The run, by the example above in a fresh process; a no-op anywhere else.
  it "nested-finalizer-collect child" do
    next unless ENV["GCRY_NESTED_FINALIZER_CHILD"]? == "1"
    nested_collect_build
    5.times { GC.collect }
    10.times do
      break if NestedCollectLog.ran >= NESTED_COLLECT_COUNT
      GC.collect
    end
    NestedCollectLog.max_depth.should eq(1)
    # A stale word can still hold one or two of them conservatively (one of
    # 2 000 on darwin CI); the nesting depth above is what the fix is about.
    NestedCollectLog.ran.should be >= NESTED_COLLECT_COUNT - 8
  end
end
