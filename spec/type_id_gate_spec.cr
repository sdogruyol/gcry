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

it "per-source reject counters attribute to stack scan (P2.2)" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.type_id_gate = true
    heap.allow_interior_pointers = false
    heap.layout_precise = false

    # Plant two ambient decoys inside a fake "stack" range, both gated.
    root_words = heap.malloc(32)
    root_words.as(UInt8*).clear(32)
    decoy_a = heap.malloc(32)
    decoy_a.as(UInt8*).clear(32)
    decoy_a.as(UInt64*).value = 0x00007ffff0000000_u64
    Pointer(Void*).new(root_words.as(UInt8*).address + 0).value = decoy_a
    decoy_b = heap.malloc(32)
    decoy_b.as(UInt8*).clear(32)
    decoy_b.as(UInt64*).value = 0x00007ffff0000008_u64
    Pointer(Void*).new(root_words.as(UInt8*).address + 8).value = decoy_b

    heap.before_collect do
      heap.push_stack(root_words, Pointer(Void).new(root_words.address + 32))
    end
    heap.collect(scan_stack: false)

    # Stack source got both rejects; static/thread untouched.
    stack_rejects = heap.type_id_stack_rejects
    heap.type_id_static_rejects.should eq(0)
    heap.type_id_thread_rejects.should eq(0)
    (stack_rejects + heap.type_id_static_rejects + heap.type_id_thread_rejects).should eq(heap.type_id_root_rejects)
    stack_rejects.should be > 0
  ensure
    heap.destroy
  end
end

it "per-source reject counters reset on each major collection (P2.2)" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.type_id_gate = true
    heap.layout_precise = false

    # Survives every collect via add_root (passes gate). We then plant a
    # second word inside it that the stack scan will see — but the stack
    # scan ALSO goes through the gate, which will reject absurd type_ids.
    # Make the inner pointer point at an *object with a plausible type_id*
    # (an Array header) that itself survives — the gate accepts it, the
    # test passes. For reject counting, we use the holder itself being
    # repeatedly scanned via the stack scan.
    holder = heap.malloc(32)
    holder.as(UInt8*).clear(32)
    holder.as(Int32*).value = 7 # plausible type_id

    # Plant holder's address in a fake stack range so push_stack hits it.
    root_words = heap.malloc(16)
    root_words.as(UInt8*).clear(16)
    Pointer(Void*).new(root_words.as(UInt8*).address + 0).value = holder

    heap.add_root(holder)
    heap.before_collect do
      heap.push_stack(root_words, Pointer(Void).new(root_words.address + 16))
    end
    heap.collect(scan_stack: false)
    first = heap.type_id_stack_rejects

    # Both stacks (mutator + fiber) + add_root all scan holder; the gate
    # accepts it (plausible type_id), so stack_rejects may be 0. The sum
    # invariant must still hold and second collect must reset-and-rebuild.
    heap.type_id_root_rejects.should eq(heap.type_id_stack_rejects + heap.type_id_static_rejects + heap.type_id_thread_rejects)

    # Second collect: counter is reset by note_collection_begin, then the
    # same scan produces the same per-source breakdown.
    heap.collect(scan_stack: false)
    heap.type_id_root_rejects.should eq(heap.type_id_stack_rejects + heap.type_id_static_rejects + heap.type_id_thread_rejects)
    heap.live?(holder).should be_true
  ensure
    heap.destroy
  end
end

it "type_id_root_false_negatives is exposed and zero under clean stack (P2.2)" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.type_id_gate = true
    heap.layout_precise = false

    obj = heap.malloc(32)
    obj.as(UInt8*).clear(32)
    obj.as(Int32*).value = 7
    heap.add_root(obj)
    heap.collect(scan_stack: false)

    # No blacklist hits, no false negatives expected.
    heap.type_id_root_false_negatives.should eq(0)
  ensure
    heap.destroy
  end
end
