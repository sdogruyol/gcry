require "./spec_helper"

describe "Gcry stress" do
  it "survives an allocation storm with periodic collects" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX # manual collects only
      live = [] of Void*
      5_000.times do |i|
        ptr = (i % 3 == 0) ? heap.malloc_atomic(16 + (i % 200)) : heap.malloc(16 + (i % 200))
        if i % 7 == 0
          live << ptr
          heap.add_root(ptr)
        end
        if i % 100 == 99
          # Drop some roots so collect can reclaim.
          while live.size > 50
            old = live.shift
            heap.delete_root(old)
          end
          heap.collect(scan_stack: false)
        end
      end
      heap.collect(scan_stack: false)
      heap.live_objects.should be > 0
      heap.collections.should be > 0
    ensure
      heap.destroy
    end
  end

  it "survives nested pointer graphs under collect" do
    heap = Gcry::Heap.new
    begin
      nodes = [] of Void*
      200.times do
        node = heap.malloc(32)
        nodes << node
      end
      # Link into a chain: each stores pointer to next.
      (nodes.size - 1).times do |i|
        nodes[i].as(Void**).value = nodes[i + 1]
      end
      heap.add_root(nodes[0])
      20.times { heap.collect(scan_stack: false) }
      nodes.each { |n| heap.live?(n).should be_true }
    ensure
      heap.destroy
    end
  end

  it "runs finalizers that allocate without corrupting the heap" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      finalized = 0
      100.times do
        obj = heap.malloc(24)
        heap.add_finalizer(obj) do |_ptr|
          finalized += 1
          # Allocate from the same heap inside the finalizer.
          tmp = heap.malloc(16)
          heap.free(tmp)
        end
      end
      heap.collect(scan_stack: false)
      finalized.should eq(100)
      heap.live_objects.should eq(0)
    ensure
      heap.destroy
    end
  end

  it "handles many disappearing links" do
    heap = Gcry::Heap.new
    slot_mem = LibC.malloc(100 * sizeof(Void*)).as(Void**)
    begin
      objs = [] of Void*
      100.times do |i|
        obj = heap.malloc(16)
        objs << obj
        slot_mem[i] = obj
        heap.register_disappearing_link(slot_mem + i, obj)
      end
      50.times { |i| heap.add_root(objs[i]) }
      heap.collect(scan_stack: false)
      50.times { |i| slot_mem[i].should eq(objs[i]) }
      50.times { |i| slot_mem[50 + i].should eq(Pointer(Void).null) }
    ensure
      LibC.free(slot_mem.as(Void*))
      heap.destroy
    end
  end

  it "push_stack stress with many fake fiber stacks" do
    heap = Gcry::Heap.new
    stacks = [] of Void*
    begin
      keeps = [] of Void*
      50.times do
        stack = LibC.malloc(256).as(UInt8*)
        stack.clear(256)
        obj = heap.malloc(32)
        stack.as(Void**).value = obj
        stacks << stack.as(Void*)
        keeps << obj
      end

      heap.before_collect do
        stacks.each do |stack|
          heap.push_stack(stack, (stack.as(UInt8*) + 256).as(Void*))
        end
      end

      drop = heap.malloc(32)
      heap.collect(scan_stack: false)
      keeps.each { |o| heap.live?(o).should be_true }
      heap.live?(drop).should be_false
    ensure
      stacks.each { |s| LibC.free(s) }
      heap.destroy
    end
  end
end
