require "./spec_helper"

it "root type_id gate rejects ambient buffer; heap scan still marks children" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.type_id_gate = true
    heap.allow_interior_pointers = false
    heap.layout_precise = false

    # Parent with plausible type_id pointing at child buffer (absurd type_id).
    child = heap.malloc(32)
    child.as(UInt8*).clear(32)
    child.as(UInt64*).value = 0x00007ffff0000000_u64

    obj = heap.malloc(32)
    obj.as(UInt8*).clear(32)
    obj.as(Int32*).value = 7
    Pointer(Void*).new(obj.as(UInt8*).address + 8).value = child

    # Ambient root word pointing only at the raw buffer (not a Crystal object).
    root_words = heap.malloc(16)
    root_words.as(UInt8*).clear(16)
    root_words.as(Void**).value = child

    decoy = heap.malloc(32)
    decoy.as(UInt8*).clear(32)
    decoy.as(UInt64*).value = 0x0000555555555400_u64
    # Plant decoy only in the ambient root range (second word).
    Pointer(Void*).new(root_words.as(UInt8*).address + 8).value = decoy

    heap.before_collect do
      # push_stack uses mark_root_candidate (gated).
      heap.push_stack(root_words, Pointer(Void).new(root_words.address + 16))
    end
    heap.add_root(obj)
    heap.collect(scan_stack: false)

    heap.live?(obj).should be_true
    heap.live?(child).should be_true # via heap scan from obj
    heap.live?(decoy).should be_false
    heap.type_id_root_rejects.should be > 0
  ensure
    heap.destroy
  end
end
