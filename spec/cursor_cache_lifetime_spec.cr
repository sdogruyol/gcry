require "./spec_helper"

private def cursor_spec_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.bitmap_alloc = true
  heap.nursery_enabled = false
  heap.gc_threshold = UInt64::MAX
  heap
end

# The worker has finished with A before it is destroyed, but its thread-local
# cache still remembers A's cursor set. Allocating from B must not read that
# freed set. ASan makes the stale read observable even if libc retains its page.
describe "cursor cache lifetime across heaps" do
  it "allocates from another heap after a peer destroys the cached heap" do
    a = cursor_spec_heap
    b = cursor_spec_heap
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

  # Darwin's hit path reads the set from the heap's pthread key slot
  # (`Heap#cursor_set_hit`) rather than the `@[ThreadLocal]`, which costs two
  # calls there. Everywhere else it keeps the thread-local.
  it "takes the hit path through the key slot on Darwin only" do
    heap = cursor_spec_heap
    begin
      heap.malloc(48)
      before = heap.cursor_hit_allocations
      100.times { heap.malloc(48) }
      (heap.cursor_hit_allocations - before).should be >= 90_u64
      heap.cursor_set_from_tsd?.should eq({{ flag?(:darwin) }})
    ensure
      heap.destroy
    end
  end

  # `pthread_key_delete` empties the key's slot in every thread, so a heap
  # created after a destroy — which usually gets the same key number back —
  # starts with an empty slot in a thread that had a set under the old key,
  # and that thread's first allocation claims a new set rather than reading
  # the destroyed heap's freed one.
  it "starts a recycled key empty in a thread that used the destroyed heap" do
    a = cursor_spec_heap
    a_done = Atomic(Bool).new(false)
    c_ready = Atomic(Bool).new(false)
    c = Atomic(Gcry::Heap?).new(nil)
    failure = Atomic(Bool).new(false)
    worker = Thread.new do
      a.malloc(48)
      a_done.set(true)
      until c_ready.get
        Thread.yield
      end
      heap = c.get.not_nil!
      before = heap.cursor_hit_allocations
      ptrs = Array(Void*).new(64) { heap.malloc(48) }
      ptrs.each_with_index { |p, i| p.as(UInt64*).value = i.to_u64 }
      ptrs.each_with_index { |p, i| failure.set(true) unless p.as(UInt64*).value == i.to_u64 }
      failure.set(true) unless ptrs.uniq.size == ptrs.size
      # The first allocation claims the set on the locked path; the rest hit.
      failure.set(true) unless heap.cursor_hit_allocations - before >= 63
    end
    begin
      until a_done.get
        Thread.yield
      end
      a.destroy
      c.set(cursor_spec_heap)
      c_ready.set(true)
      worker.join
      failure.get.should be_false
      c.get.not_nil!.cursor_set_from_tsd?.should eq({{ flag?(:darwin) }})
    ensure
      a.destroy
      c.get.try(&.destroy)
    end
  end

  # Several threads on one heap, each through its own slot: every block is
  # distinct and nearly every allocation takes the hit path (a thread's first
  # claims its set, and taking a fresh chunk is the locked path's job).
  it "gives each thread its own set through the hit path" do
    heap = cursor_spec_heap
    threads = 4
    per = 500
    results = Array(Array(UInt64)).new(threads) { [] of UInt64 }
    begin
      before = heap.cursor_hit_allocations
      workers = Array.new(threads) do |t|
        Thread.new do
          per.times { results[t] << heap.malloc(48).address }
        end
      end
      workers.each(&.join)
      all = results.flatten
      all.uniq.size.should eq(threads * per)
      (heap.cursor_hit_allocations - before).should be >= (threads * per * 9 // 10).to_u64
    ensure
      heap.destroy
    end
  end
end
