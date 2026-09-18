require "../../src/gcry"
require "spec"

{% if flag?(:win32) && flag?(:gc_none) %}
  # Two properties, and they used to be one.
  #
  # This platform answered a full 64-slot capture table by **refusing the
  # stop**, so 65 threads was both the way to reach the failure path and the
  # reason a process with 65 threads could never collect. The table grows now
  # (`Gcry::StwSlots`), so 65 threads is a success case — and the failure path,
  # which exists for a real bug, needs its own trigger:
  # `GCRY_STW_TEST_FAIL_SUSPEND` / `Gcry::Platform.stw_test_fail_suspend`.
  describe "Windows stop-the-world past the table that shipped" do
    it "stops and collects with more threads than the initial capacity" do
      heap = Gcry.default_heap
      previous_stress = heap.stress_every
      ready = Atomic(Int32).new(0)
      finish = Atomic(Int32).new(0)
      workers = [] of Thread
      heap.disable
      begin
        65.times do
          workers << Thread.new do
            ready.add(1)
            while finish.get == 0
              LibC.Sleep(1)
            end
          end
        end
        until ready.get == workers.size
          Thread.yield
        end
        heap.enable

        before = Gcry::Platform.stw_capture_no_slot
        GC.stop_world
        GC.start_world
        GC.collect
        # Every suspended thread got a slot. Without one it is scanned with no
        # SP clamp and no registers, and `GetThreadContext` is their only copy.
        Gcry::Platform.stw_capture_no_slot.should eq before
        Gcry::Platform.stw_slot_capacity.should be > workers.size
        GC.is_heap_ptr(GC.malloc(32)).should be_true
      ensure
        heap.stress_every = 0
        finish.set(1)
        workers.each(&.join)
        heap.enable
        heap.stress_every = previous_stress
      end
    end

    it "allocates failure exceptions without recursive collection and recovers both entry points" do
      heap = Gcry.default_heap
      previous_stress = heap.stress_every
      previous_suppression = heap.@suppress_collect.get
      direct_error = nil.as(Exception?)
      collect_error = nil.as(Exception?)
      begin
        Gcry::Platform.stw_test_fail_suspend = true
        # Force every exception/backtrace allocation to try collecting. Direct
        # stop_world lacks collect's @collecting guard and needs suppression.
        heap.stress_every = 1
        begin
          GC.stop_world
        rescue ex
          direct_error = ex
        ensure
          heap.stress_every = 0
        end
        heap.stress_every = 1
        begin
          GC.collect
        rescue ex
          collect_error = ex
        ensure
          heap.stress_every = 0
        end
      ensure
        Gcry::Platform.stw_test_fail_suspend = false
        heap.stress_every = previous_stress
      end
      direct_error.should_not be_nil
      collect_error.should_not be_nil
      direct_error.not_nil!.message.not_nil!.should contain "Windows thread suspension"
      collect_error.not_nil!.message.not_nil!.should contain "Windows thread suspension"
      heap.@suppress_collect.get.should eq previous_suppression
      # Both entry points must work once the stop can succeed again, proving
      # Thread.lock, the post-STW state and the owner were all cleaned up.
      GC.stop_world
      GC.start_world
      GC.collect
      GC.is_heap_ptr(GC.malloc(32)).should be_true
    end
  end
{% end %}
