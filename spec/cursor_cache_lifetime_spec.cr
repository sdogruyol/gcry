require "./spec_helper"

# The worker has finished with A before it is destroyed, but its thread-local
# cache still remembers A's cursor set. Allocating from B must not read that
# freed set. ASan makes the stale read observable even if libc retains its page.
describe "cursor cache lifetime across heaps" do
  it "allocates from another heap after a peer destroys the cached heap" do
    a = Gcry::Heap.new
    b = Gcry::Heap.new
    [a, b].each do |heap|
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
    end
    ready = Atomic(Bool).new(false)
    proceed = Atomic(Bool).new(false)
    worker = Thread.new do
      a.malloc(48)
      ready.set(true)
      until proceed.get
        Thread.yield
      end
      ptr = b.malloc(48)
      ptr.as(UInt64*).value = 0x1234_u64
      ptr.as(UInt64*).value.should eq(0x1234_u64)
    end
    begin
      until ready.get
        Thread.yield
      end
      a.destroy
      proceed.set(true)
      worker.join
    ensure
      a.destroy
      b.destroy
    end
  end
end
