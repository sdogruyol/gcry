require "../../src/gcry"
require "spec"

# Once a mutator thread exists, every allocation takes the locked path with
# atomic counters, and blocks handed to different threads never alias. This
# is the regime the single-mutator fast path hands over to, exercised through
# the process `GC` the way an application would.
describe "allocation with several mutator threads" do
  it "hands every thread its own blocks and keeps the counters whole" do
    threads = 4
    per_thread = 20_000
    keep = 256
    fill = Array(UInt64).new(threads) { |t| 0x1111_1111_1111_1111_u64 &* (t.to_u64 + 1) }
    bad = Atomic(Int32).new(0)
    done = Atomic(Int32).new(0)
    workers = Array(Thread).new(threads) do |t|
      Thread.new do
        ring = Array(Void*).new(keep, Pointer(Void).null)
        stamp = fill[t]
        per_thread.times do |i|
          p = GC.malloc(48)
          p.as(UInt64*).value = stamp
          (p.as(UInt64*) + 5).value = stamp
          ring[i % keep] = p
          # A block another thread was also handed shows up as its stamp.
          held = ring[(i + 1) % keep]
          unless held.null?
            bad.add(1) unless held.as(UInt64*).value == stamp && (held.as(UInt64*) + 5).value == stamp
          end
        end
        done.add(1)
      end
    end
    while done.get < threads
      Thread.yield
    end
    workers.each(&.join)
    bad.get.should eq(0)
    Gcry.single_mutator?.should be_false
    heap = Gcry.default_heap.not_nil!
    heap.heap_counters_atomic.should be_true
    # The counters survived four threads: a collection reconciles them
    # against the sweep without the invariant checker objecting.
    GC.collect
    heap.free_bytes.should be <= heap.heap_size
  end
end
