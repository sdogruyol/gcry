require "./spec_helper"

class Gcry::Heap
  property cursor_metadata_allocations_before_failure_for_spec : Int32? = nil

  private def alloc_cursor_set : CursorSet*
    if remaining = @cursor_metadata_allocations_before_failure_for_spec
      return Pointer(CursorSet).null if remaining == 0
      @cursor_metadata_allocations_before_failure_for_spec = remaining - 1
    end
    previous_def
  end
end

describe "cursor metadata allocation failure" do
  it "raises outside the class lock and can allocate after recovery" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.cursor_metadata_allocations_before_failure_for_spec = 0
      expect_raises(Gcry::OutOfMemoryError) { heap.malloc(48) }
      heap.cursor_metadata_allocations_before_failure_for_spec = nil
      allocation = heap.malloc(48)
      heap.live?(allocation).should be_true
      allocation.as(UInt8*).to_slice(48).all?(&.zero?).should be_true
    ensure
      heap.destroy
    end
  end

  it "uses the locked fallback when only the shared cursor set can be allocated" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.cursor_metadata_allocations_before_failure_for_spec = 1
      allocations = Array(Void*).new(300) { heap.malloc(48) }
      allocations.uniq.size.should eq(300)
      heap.cursor_set_count.should eq(0)
      heap.cursor_hit_allocations.should eq(0)
      heap.collect(scan_stack: false, roots: allocations)
      allocations.each { |allocation| heap.live?(allocation).should be_true }
    ensure
      heap.destroy
    end
  end
end
