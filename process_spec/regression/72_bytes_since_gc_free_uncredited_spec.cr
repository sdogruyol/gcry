require "../../src/gcry"
require "spec"

# A `free` lost its `bytes_since_gc` subtraction whenever the heap-wide
# counter stood below the bytes actually allocated since the last
# collection, which it does as a matter of course: an allocation on the hit
# path is counted in its thread's cursor set and reaches `@bytes_since_gc`
# only when the set is credited (a refill, a stop, a reader), while a `free`
# subtracts at once. The subtraction saturated at zero, so bytes freed before
# the credit for their allocation landed were dropped from the subtraction
# but not from the credit, and the counter stood that much above what was
# allocated and still held: the next collection came that much early.
#
# The same shape as `live_objects` (regression/68), but it needs no second
# thread: the counter starts every cycle at zero, so the first frees after a
# reset meet it there. One thread, a library heap, no collection after the
# reset: it allocates a batch on the hit path and frees it, round after
# round, so it holds nothing at the end and the counter must read
# zero. Before the fix it read 246 272 of the 819 200 bytes allocated and
# freed, 3 of 3 runs; 0 in 3 of 3 after.

private CHURN_ROUNDS = 100
private CHURN_BATCH  = 128
private CHURN_SIZE   =  64

describe "Regression: a free never loses its bytes_since_gc subtraction" do
  it "with a thread freeing what it allocated on the hit path" do
    heap = Gcry::Heap.new
    heap.nursery_enabled = false
    heap.gc_threshold = UInt64::MAX
    begin
      batch = Pointer(Void*).malloc(CHURN_BATCH)
      # The reset the churn starts from, as at every major collection.
      heap.collect(scan_stack: false)
      heap.bytes_since_gc.should eq(0)
      CHURN_ROUNDS.times do
        CHURN_BATCH.times { |i| batch[i] = heap.malloc(CHURN_SIZE) }
        CHURN_BATCH.times { |i| heap.free(batch[i]) }
      end

      heap.bytes_since_gc.should eq(0)
      heap.total_bytes.should eq(CHURN_ROUNDS * CHURN_BATCH * CHURN_SIZE)
    ensure
      heap.destroy
    end
  end
end
