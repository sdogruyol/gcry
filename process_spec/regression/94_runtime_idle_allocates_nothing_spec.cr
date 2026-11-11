require "../../src/gcry"
require "spec"

# The idle collector runs once the allocation count (`Heap#allocation_activity`)
# has stood still for the idle time. On Crystal 1.22 it never ran: the
# Monitor (SYSMON) sleeps through `Thread.sleep`, which 1.22 wraps in
# `GC.syscall`, and `gc/none.cr`'s `GC.syscall` takes its block as a captured
# `&proc` — a 48-byte closure allocated every 10 ms, for good. A program
# spinning without allocating read +4 752 bytes a second on 1.22.2 and 0 on
# 1.21.0, and an idle one got 0 idle collections, where 1.21 gave one
# (`make idle-release` and regression 93 failed on 1.22.2 only). gcry's own
# `GC.syscall` yields (`gc_override.cr`).
#
# The fixed arm spins for 300 ms — thirty Monitor ticks — and makes a
# thousand `GC.syscall` calls, and the count must not move. The control arm
# makes a thousand calls of a captured-block wrapper shaped like
# `gc/none.cr`'s, and the count must move by at least one closure each, or the
# fixed arm passes on an instrument that sees nothing. Each arm a process of
# its own, the idle collector off.

private def c94_captured(&proc : ->) : Nil
  proc.call
end

# `Thread.sleep`'s shape on 1.22: locals the block writes, declared per call,
# so each call allocates their closure.
private def c94_sleep_shaped : Int32
  ret = 0
  c94_captured { ret = 1 }
  ret
end

private def c94_moved(heap : Gcry::Heap, & : ->) : UInt64
  before = heap.allocation_activity
  yield
  heap.allocation_activity &- before
end

describe "Regression: the runtime's own threads allocate nothing while a program does not" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      env = {"GCRY_RUNTIME_IDLE_CHILD" => arm, "GCRY_IDLE_RELEASE_MS" => "0"} of String => String?
      status = Process.run(Process.executable_path.not_nil!, ["-e", "runtime-idle child #{arm}"],
        env: env, output: captured, error: captured)
      fail "child #{status.inspect}:\n#{captured}" unless status.success?
      if arm == "control"
        captured.to_s.should contain("runtime94: control's closures counted")
      else
        captured.to_s.should contain("1 examples, 0 failures")
      end
    end
  end

  it "runtime-idle child fixed" do
    next unless ENV["GCRY_RUNTIME_IDLE_CHILD"]? == "fixed"
    heap = Gcry.default_heap
    # Settle: the first sleep sets up the event loop.
    sleep 20.milliseconds
    spun = c94_moved(heap) do
      t0 = Time.instant
      while Time.instant - t0 < 300.milliseconds
        Intrinsics.pause
      end
    end
    spun.should eq(0)
    x = 0
    calls = c94_moved(heap) do
      {% if GC.class.has_method?("syscall") %}
        1000.times { GC.syscall { x += 1 } }
      {% else %}
        x = 1000
      {% end %}
    end
    x.should eq(1000)
    calls.should eq(0)
  end

  it "runtime-idle child control" do
    next unless ENV["GCRY_RUNTIME_IDLE_CHILD"]? == "control"
    heap = Gcry.default_heap
    sleep 20.milliseconds
    x = 0
    moved = c94_moved(heap) { 1000.times { x += c94_sleep_shaped } }
    x.should eq(1000)
    moved.should be >= 1000_u64 * 16
    STDOUT.puts "runtime94: control's closures counted (#{moved} bytes for 1000 calls)"
    STDOUT.flush
  end
end
