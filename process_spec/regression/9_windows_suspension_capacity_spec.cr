require "../../src/gcry"
require "spec"

{% if flag?(:win32) && flag?(:gc_none) %}
  describe "Windows suspension failure under process GC" do
    it "allocates failure exceptions without recursive collection and recovers both entry points" do
      heap = Gcry.default_heap
      previous_stress = heap.stress_every
      previous_suppression = heap.@suppress_collect.get
      ready = Atomic(Int32).new(0)
      finish = Atomic(Int32).new(0)
      workers = [] of Thread
      direct_error = nil.as(Exception?)
      collect_error = nil.as(Exception?)
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
        # Force every exception/backtrace allocation to try collecting. Direct
        # stop_world lacks collect's @collecting guard and needs suppression.
        heap.stress_every = 1
        begin
          GC.stop_world
        rescue ex
          direct_error = ex
        ensure
          heap.stress_every = 0
          GC.start_world
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
        heap.stress_every = 0
        finish.set(1)
        workers.each(&.join)
        heap.enable
        heap.stress_every = previous_stress
      end
      direct_error.should_not be_nil
      collect_error.should_not be_nil
      direct_error.not_nil!.message.not_nil!.should contain "Windows thread suspension"
      collect_error.not_nil!.message.not_nil!.should contain "Windows thread suspension"
      heap.@suppress_collect.get.should eq previous_suppression
      # Both suspension and full collection must work once capacity is back
      # below the limit, proving Thread.lock/post-STW/owner cleanup completed.
      GC.stop_world
      GC.start_world
      GC.collect
      GC.is_heap_ptr(GC.malloc(32)).should be_true
    end
  end
{% end %}
