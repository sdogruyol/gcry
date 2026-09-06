require "./spec_helper"

# Pause after claiming a block, outside the class lock, to let a peer refill
# the same class. This schedules the race without sleeps or production hooks.
class Gcry::Heap
  property after_header_claim_for_spec : Proc(Nil)?

  private def alloc_old_small(payload : UInt32, flags : UInt32, index : Int32, rounded : UInt64)
    result = previous_def
    run_after_header_claim_for_spec
    result
  end

  private def alloc_nursery(payload : UInt32, flags : UInt32, index : Int32, rounded : UInt64)
    result = previous_def
    run_after_header_claim_for_spec
    result
  end

  private def run_after_header_claim_for_spec : Nil
    if action = @after_header_claim_for_spec
      @after_header_claim_for_spec = nil
      action.call
    end
  end
end

{% unless flag?(:gcry_headerless) %}
  describe "header allocation zeroing across a peer refill" do
    [false, true].each do |nursery|
      it "keeps the claimed block's clearing decision (nursery=#{nursery})" do
        heap = Gcry::Heap.new
        begin
          heap.bitmap_alloc = false
          heap.nursery_enabled = nursery
          heap.gc_threshold = UInt64::MAX
          heap.tlab_enabled = false
          dirty = heap.malloc(48)
          dirty.as(UInt8*).to_slice(48).fill(0xa5_u8)
          heap.free(dirty)
          heap.after_header_claim_for_spec = -> {
            # Exhaust this class and map a fresh zeroed chunk on the peer.
            count = (heap.free_bytes // 48).to_i + 1
            Thread.new { count.times { heap.malloc(48) } }.join
            nil
          }
          reused = heap.malloc(48)
          reused.should eq(dirty)
          reused.as(UInt8*).to_slice(48).all?(&.zero?).should be_true
        ensure
          heap.destroy
        end
      end
    end
  end
{% end %}
