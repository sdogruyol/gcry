require "./spec_helper"

# Record where in the collection `adapt_after_sweep` runs.
class Gcry::Heap
  getter adapt_ran_while_collecting_for_spec : Bool? = nil

  private def adapt_after_sweep : Nil
    @adapt_ran_while_collecting_for_spec = @collecting
    previous_def
  end
end

# The threshold and warm budget are computed from `@size_class_live_bytes`,
# which the sweep that just ran wrote. After `unlock_post_stw` a peer
# collection may begin and write it again before this thread's computation,
# so the computation must happen inside the post-STW section - while
# `@collecting` is still true - not after it.
describe "adapt_after_sweep ordering" do
  it "runs inside the post-STW section of a major collection" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.adaptive_threshold = true
      heap.malloc(48)
      heap.collect(scan_stack: false)
      heap.adapt_ran_while_collecting_for_spec.should be_true
    ensure
      heap.destroy
    end
  end
end
