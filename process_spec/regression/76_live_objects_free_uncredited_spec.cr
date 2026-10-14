require "../../src/gcry"
require "spec"

# A `free` lost its `live_objects` decrement whenever the heap-wide counter
# stood below the number of blocks actually allocated, which it does as a
# matter of course: an allocation on the hit path is counted in its thread's
# cursor set and reaches `@live_objects` only when the set is credited (a
# refill, a stop, a reader), while a `free` subtracts at once. The
# subtraction saturated at zero, so a decrement that arrived before the
# increments it was paired with was dropped for good, and the counter stayed
# that many above the walk. A credit before the subtraction covered one
# thread; with two, both read the counter at one, both skipped the credit,
# and the second subtraction found zero.
#
# `make counter-loss` found it once its comparison was made only at quiescent
# points: 40 threads freeing a quarter of what they allocate left the counter
# 3 to 7 above the walk after six rounds, exactly as many as the number of
# subtractions that had saturated.
#
# A library heap, so nothing but this file allocates on it, and no collection,
# so nothing credits the sets between the frees. Every thread allocates a batch
# on the hit path, frees it, and keeps a few blocks at the end: the counter
# must then read exactly the blocks still held. Each thread has a size class
# of its own, because a bitmap free takes its class's lock and threads sharing
# one class leave it one at a time, which is often enough to keep their
# subtractions from meeting: with every thread on 48 bytes the spec failed
# before the fix in 6 of 10 runs on 2 CPUs. With a class each it failed 10 of
# 10 on 2, 4 and 12 CPUs, losing 21 to 68, 120 to 210 and 569 to 796
# decrements; on one CPU 0 of 10. After the fix, 0 of 10 on each.

private UNCREDITED_THREADS =   8
private UNCREDITED_ROUNDS  = 400
private UNCREDITED_BATCH   = 128
private UNCREDITED_KEEP    =  16

describe "Regression: a free never loses its live_objects decrement" do
  it "with threads freeing what they allocated on the hit path" do
    heap = Gcry::Heap.new
    heap.nursery_enabled = false
    heap.gc_threshold = UInt64::MAX
    begin
      go = Atomic(Int32).new(0)
      threads = Array(Thread).new(UNCREDITED_THREADS) do |t|
        Thread.new do
          size = 16 * (t + 1)
          batch = Pointer(Void*).malloc(UNCREDITED_BATCH)
          until go.get == 1
            Thread.yield
          end
          UNCREDITED_ROUNDS.times do
            UNCREDITED_BATCH.times { |i| batch[i] = heap.malloc(size) }
            UNCREDITED_BATCH.times { |i| heap.free(batch[i]) }
          end
          UNCREDITED_KEEP.times { |i| batch[i] = heap.malloc(size) }
        end
      end
      go.set(1)
      threads.each(&.join)

      heap.live_objects.should eq(UNCREDITED_THREADS * UNCREDITED_KEEP)
    ensure
      heap.destroy
    end
  end
end
