require "./spec_helper"

describe "atomic leaves in the mark queue" do
  it "marks small and large atomic roots without queueing their bodies" do
    [64, 65536].each do |size|
      heap = Gcry::Heap.new
      begin
        heap.nursery_enabled = false
        heap.gc_threshold = UInt64::MAX
        child = heap.malloc(32)
        leaf = heap.malloc_atomic(size)
        leaf.as(Void**).value = child
        queued = false
        heap.before_collect do
          heap.mark_precise_root(leaf)
          queued = !heap.@mark_stack.empty?
        end
        heap.collect(scan_stack: false)
        queued.should be_false
        heap.live?(leaf).should be_true
        heap.live?(child).should be_false
      ensure
        heap.destroy
      end
    end
  end

  it "still queues a pointerful parent and follows its edge" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      child = heap.malloc_atomic(64)
      parent = heap.malloc(32)
      parent.as(Void**).value = child
      queued = false
      heap.before_collect do
        heap.mark_precise_root(parent)
        queued = !heap.@mark_stack.empty?
      end
      heap.collect(scan_stack: false)
      queued.should be_true
      heap.live?(parent).should be_true
      heap.live?(child).should be_true
    ensure
      heap.destroy
    end
  end
end
