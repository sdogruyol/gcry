require "./spec_helper"

describe Gcry::Invariant do
  it "is disabled by default" do
    # When GCRY_DEBUG_INVARIANTS is not set, the module starts disabled.
    unless ENV["GCRY_DEBUG_INVARIANTS"]? == "1"
      Gcry::Invariant.enabled?.should be_false
    end
  end

  it "can be enabled and disabled" do
    Gcry::Invariant.enable
    Gcry::Invariant.enabled?.should be_true
    Gcry::Invariant.disable
    Gcry::Invariant.enabled?.should be_false
  end

  it "passes check_live_objects on a fresh heap" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        Gcry::Invariant.check_live_objects(heap)
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end

  it "passes after_malloc and after_free on simple alloc/free cycle" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        ptr = heap.malloc(64)
        ptr.should_not be_nil
        heap.free(ptr)
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end

  it "passes after_collect on a heap with live objects" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        ptr = heap.malloc(128)
        ptr.should_not be_nil
        heap.add_root(ptr)
        heap.collect
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end

  it "passes freelist checks after alloc/free cycles" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        ptrs = [] of Void*
        10.times { ptrs << heap.malloc(32) }
        ptrs.each { |p| heap.free(p) }
        Gcry::Invariant.check_all_freelists(heap)
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end

  it "passes hooks (malloc/free/collect) with invariants enabled" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        ptr = heap.malloc(64)
        ptr.should_not be_nil
        heap.free(ptr)

        ptr2 = heap.malloc(256)
        heap.add_root(ptr2)
        heap.collect
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end
end
