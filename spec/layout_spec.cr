require "./spec_helper"

it "registers layout offsets for Array(String)" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry::Layout.register(Array(String))
  Gcry::Layout.size.should be > 0
  offs = Gcry::Layout.offsets_for(Array(String).crystal_instance_type_id)
  offs.should_not be_nil
  offs.not_nil!.includes?(UInt16.new(offsetof(Array(String), @buffer))).should be_true
  entry = Gcry::Layout.entry_for(Array(String).crystal_instance_type_id)
  entry.should_not be_nil
  entry.not_nil!.alloc_size.should be > 0
ensure
  Gcry::Layout.clear
end

it "Array(Int32) buffer is noscan" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry::Layout.register(Array(Int32))
  entry = Gcry::Layout.entry_for(Array(Int32).crystal_instance_type_id).not_nil!
  entry.scan_offsets.size.should eq(0)
  entry.noscan_offsets.includes?(UInt16.new(offsetof(Array(Int32), @buffer))).should be_true
ensure
  Gcry::Layout.clear
end

it "precise layout scan follows pointer offsets only" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true

  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.layout_precise = true
    heap.allow_interior_pointers = false

    tid = 4242
    Gcry::Layout.install(tid, [8_u16], 0_u32)

    child = heap.malloc(32)
    dead = heap.malloc(32)
    obj = heap.malloc(64)
    user = obj.as(UInt8*)
    user.as(Int32*).value = tid
    Pointer(Void*).new(user.address + 8).value = child
    Pointer(UInt64).new(user.address + 16).value = dead.address

    heap.add_root(obj)
    heap.collect(scan_stack: false)

    heap.live?(obj).should be_true
    heap.live?(child).should be_true
    heap.live?(dead).should be_false
    heap.layout_precise_scans.should be > 0
  ensure
    heap.destroy
    Gcry::Layout.clear
  end
end

it "size-class mismatch falls back to conservative scan" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true

  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.layout_precise = true
    heap.allow_interior_pointers = false

    tid = 4243
    Gcry::Layout.install(tid, [8_u16], 32_u32)

    child = heap.malloc(32)
    kept = heap.malloc(32)
    obj = heap.malloc(64)
    user = obj.as(UInt8*)
    user.as(Int32*).value = tid
    Pointer(Void*).new(user.address + 8).value = child
    Pointer(UInt64).new(user.address + 16).value = kept.address

    heap.add_root(obj)
    heap.collect(scan_stack: false)

    heap.live?(child).should be_true
    heap.live?(kept).should be_true
    heap.layout_precise_scans.should eq(0)
    heap.layout_conservative_scans.should be > 0
  ensure
    heap.destroy
    Gcry::Layout.clear
  end
end

it "register_hash installs KIND_HASH with noscan entries/indices" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry::Layout.register_hash(String, String)
  entry = Gcry::Layout.entry_for(Hash(String, String).crystal_instance_type_id).not_nil!
  entry.hash?.should be_true
  entry.hash_entry_stride.should eq(sizeof(Hash::Entry(String, String)).to_u16)
  entry.noscan_offsets.includes?(UInt16.new(offsetof(Hash(String, String), @indices))).should be_true
  entry.noscan_offsets.includes?(UInt16.new(offsetof(Hash(String, String), @entries))).should be_true
ensure
  Gcry::Layout.clear
end
