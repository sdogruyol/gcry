require "./spec_helper"

describe "Gcry::Heap fiber roots" do
  it "keeps objects reachable only from a pushed stack range" do
    heap = Gcry::Heap.new
    begin
      # Simulated fiber stack: a small buffer holding a heap pointer.
      stack = LibC.malloc(64).as(UInt8*)
      begin
        stack.clear(64)
        obj = heap.malloc(32)
        stack.as(Void**).value = obj

        heap.before_collect do
          heap.push_stack(stack.as(Void*), (stack + 64).as(Void*))
        end

        heap.collect(scan_stack: false)
        heap.live?(obj).should be_true
      ensure
        LibC.free(stack.as(Void*))
      end
    ensure
      heap.destroy
    end
  end

  it "reclaims objects not present on any pushed stack" do
    heap = Gcry::Heap.new
    begin
      stack = LibC.malloc(64).as(UInt8*)
      begin
        stack.clear(64)
        keep = heap.malloc(32)
        drop = heap.malloc(32)
        stack.as(Void**).value = keep

        heap.before_collect do
          heap.push_stack(stack.as(Void*), (stack + 64).as(Void*))
        end

        heap.collect(scan_stack: false)
        heap.live?(keep).should be_true
        heap.live?(drop).should be_false
      ensure
        LibC.free(stack.as(Void*))
      end
    ensure
      heap.destroy
    end
  end

  it "raises when push_stack is called outside collect" do
    heap = Gcry::Heap.new
    begin
      expect_raises(Exception, /push_stack outside/) do
        heap.push_stack(Pointer(Void).null, Pointer(Void).null)
      end
    ensure
      heap.destroy
    end
  end
end

describe "Gcry::Heap finalizers" do
  it "runs finalizers for reclaimed objects after collect" do
    heap = Gcry::Heap.new
    begin
      finalized = [] of Void*
      obj = heap.malloc(16)
      heap.add_finalizer(obj) { |ptr| finalized << ptr }

      heap.collect(scan_stack: false)
      heap.live?(obj).should be_false
      finalized.should eq([obj])
    ensure
      heap.destroy
    end
  end

  it "runs finalizers on explicit free" do
    heap = Gcry::Heap.new
    begin
      finalized = [] of Void*
      obj = heap.malloc(16)
      heap.add_finalizer(obj) { |ptr| finalized << ptr }
      heap.free(obj)
      heap.finalizer_entry_count.should eq(0)
      # Pending finalizers run at the next collect (same as GC path).
      heap.collect(scan_stack: false)
      finalized.should eq([obj])
    ensure
      heap.destroy
    end
  end

  it "explicit free of a plain object does not drop unrelated finalizers" do
    heap = Gcry::Heap.new
    begin
      keep = [] of Void*
      64.times do
        obj = heap.malloc(16)
        heap.add_finalizer(obj) { }
        heap.add_root(obj)
        keep << obj
      end
      heap.finalizer_entry_count.should eq(64)

      plain = heap.malloc(32)
      32.times { |i| plain.as(UInt8*)[i] = 1_u8 }
      heap.free(plain)

      heap.finalizer_entry_count.should eq(64)
    ensure
      heap.destroy
    end
  end
end

describe "Gcry::Heap disappearing links" do
  it "clears a weak link when the referent is collected" do
    heap = Gcry::Heap.new
    begin
      obj = heap.malloc(16)
      slot = Pointer(Void).null
      slot_ptr = pointerof(slot)
      slot = obj
      heap.register_disappearing_link(slot_ptr, obj)

      heap.collect(scan_stack: false)
      heap.live?(obj).should be_false
      slot.should eq(Pointer(Void).null)
    ensure
      heap.destroy
    end
  end

  it "leaves the link intact while the referent lives" do
    heap = Gcry::Heap.new
    begin
      obj = heap.malloc(16)
      slot = obj
      heap.register_disappearing_link(pointerof(slot), obj)
      heap.add_root(obj)

      heap.collect(scan_stack: false)
      heap.live?(obj).should be_true
      slot.should eq(obj)
    ensure
      heap.destroy
    end
  end
end
