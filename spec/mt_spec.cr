require "./spec_helper"

describe "Gcry TLAB" do
  it "allocates and frees through TLAB without losing objects" do
    heap = Gcry::Heap.new
    begin
      heap.tlab_enabled = true
      heap.gc_threshold = UInt64::MAX
      heap.nursery_threshold = UInt64::MAX
      heap.nursery_enabled = false

      ptrs = [] of Void*
      200.times { ptrs << heap.malloc(48) }
      heap.tlab_refills.should be > 0
      ptrs.each { |p| heap.is_heap_ptr(p).should be_true }
      ptrs.each { |p| heap.free(p) }
      heap.live_objects.should eq(0)

      again = heap.malloc(48)
      heap.is_heap_ptr(again).should be_true
      heap.free(again)
    ensure
      heap.destroy
    end
  end

  it "flushes TLAB before collect so sweep sees freelist" do
    heap = Gcry::Heap.new
    begin
      heap.tlab_enabled = true
      heap.gc_threshold = UInt64::MAX
      heap.nursery_enabled = false
      keep = heap.malloc(32)
      heap.add_root(keep)
      drop = heap.malloc(32)
      heap.collect(scan_stack: false)
      heap.live?(keep).should be_true
      heap.live?(drop).should be_false
    ensure
      heap.destroy
    end
  end

  it "nursery + TLAB keeps old→young edges" do
    heap = Gcry::Heap.new
    begin
      heap.tlab_enabled = true
      heap.nursery_enabled = true
      heap.gc_threshold = UInt64::MAX
      heap.nursery_threshold = UInt64::MAX
      parent = heap.malloc(16)
      heap.add_root(parent)
      heap.minor_collect(scan_stack: false)
      child = heap.malloc(32)
      parent.as(Void**).value = child
      heap.minor_collect(scan_stack: false)
      heap.live?(child).should be_true
    ensure
      heap.destroy
    end
  end
end

describe "Gcry parallel mark knob" do
  it "accepts parallel_mark_workers and still marks correctly" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      # Library heap: leave stop_the_world off (Boehm + STW Monitor deadlocks in unit tests).
      heap.parallel_mark_workers = 4

      root = heap.malloc(64)
      heap.add_root(root)
      cursor = root
      50.times do
        child = heap.malloc(32)
        cursor.as(Void**).value = child
        cursor = child
      end

      before_stolen = heap.parallel_mark_stolen
      drop = heap.malloc(32)
      heap.collect(scan_stack: false)

      heap.live?(root).should be_true
      heap.live?(cursor).should be_true
      heap.live?(drop).should be_false
      heap.parallel_mark_runs.should be > 0
      (heap.parallel_mark_stolen >= before_stolen).should be_true
    ensure
      heap.destroy
    end
  end

  it "serial mark when workers = 1" do
    heap = Gcry::Heap.new
    begin
      heap.parallel_mark_workers = 1
      heap.gc_threshold = UInt64::MAX
      keep = heap.malloc(16)
      heap.add_root(keep)
      heap.malloc(16)
      heap.collect(scan_stack: false)
      heap.live?(keep).should be_true
      heap.parallel_mark_runs.should eq(0)
    ensure
      heap.destroy
    end
  end
end

describe "Gcry MT alloc storm (TLAB)" do
  it "survives concurrent alloc from multiple threads" do
    heap = Gcry::Heap.new
    begin
      heap.tlab_enabled = true
      heap.gc_threshold = UInt64::MAX
      heap.nursery_enabled = false
      # No stop_the_world in library unit tests (see above).
      # Join OS threads — Channel across Thread/Fiber can hang the scheduler.

      threads = Array(Thread).new(4) do
        Thread.new do
          local = [] of Void*
          100.times do
            local << heap.malloc(64)
            local.shift if local.size > 20
          end
          local.each { |p| heap.free(p) if heap.is_heap_ptr(p) && heap.live?(p) }
        end
      end
      threads.each(&.join)

      # Collect from the main thread after workers finish.
      heap.collect(scan_stack: false)
      heap.tlab_refills.should be > 0
    ensure
      heap.destroy
    end
  end
end
