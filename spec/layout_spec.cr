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

it "a union buffer whose first tag is a registered type keeps every element" do
  # `[JSON::Any.new(array), JSON::Any.new("x")]`: 32 bytes, the size class of
  # an `Array(JSON::Any)`, starting with that type's id as element 0's tag.
  # Scanned at the Array's offsets, neither element's pointer was read.
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry::Layout.register(Array(JSON::Any))

  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.layout_precise = true

    tid = Array(JSON::Any).crystal_instance_type_id
    size = sizeof(JSON::Any) * 2
    Gcry::Layout.entry_for(tid).not_nil!.alloc_size.should eq(size)

    first = heap.malloc(48)
    second = heap.malloc(48)
    buf = heap.malloc(size).as(UInt8*)
    buf.clear(size)
    buf.as(Int32*).value = tid
    Pointer(Void*).new(buf.address + 8).value = first
    (buf + sizeof(JSON::Any)).as(Int32*).value = String.crystal_instance_type_id
    Pointer(Void*).new(buf.address + sizeof(JSON::Any) + 8).value = second

    heap.add_root(buf.as(Void*))
    heap.collect(scan_stack: false)

    heap.live?(first).should be_true
    heap.live?(second).should be_true
  ensure
    heap.destroy
    Gcry::Layout.clear
  end
end

it "raw-buffer conservative scans are object-base only" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.layout_precise = false

    buf = heap.malloc(64)
    interior = Pointer(Void).new(buf.address + 16)
    # Parent looks like a raw buffer (type_id 0).
    parent = heap.malloc(32)
    parent.as(UInt64*).value = 0_u64
    Pointer(Void*).new(parent.address + 8).value = interior

    heap.add_root(parent)
    heap.collect(scan_stack: false)

    heap.live?(parent).should be_true
    heap.live?(buf).should be_false
  ensure
    heap.destroy
  end
end

it "typed conservative scans still follow interiors" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.layout_precise = false

    buf = heap.malloc(64)
    interior = Pointer(Void).new(buf.address + 16)
    parent = heap.malloc(32)
    parent.as(Int32*).value = 9
    Pointer(Void*).new(parent.address + 8).value = interior

    heap.add_root(parent)
    heap.collect(scan_stack: false)

    heap.live?(parent).should be_true
    heap.live?(buf).should be_true
  ensure
    heap.destroy
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
  entry.hash_size_off.should eq(UInt16.new(offsetof(Hash(String, String), @size)))
  entry.hash_deleted_off.should eq(UInt16.new(offsetof(Hash(String, String), @deleted_count)))
  # @block is Proc? — not a single scan offset
  entry.scan_offsets.size.should eq(0)
ensure
  Gcry::Layout.clear
end

it "hash precise scan keeps the default block's closure alive" do
  # `Hash.new { |h, k| ... }` holds its block in `@block`, a two-word Proc
  # whose second word is the closure. Nothing else in the Hash reaches it.
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry::Layout.register_hash(String, String)

  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.layout_precise = true

    tid = Hash(String, String).crystal_instance_type_id
    closure = heap.malloc(48)
    dead = heap.malloc(48)

    size = instance_sizeof(Hash(String, String))
    obj = heap.malloc(size.to_i32).as(UInt8*)
    obj.clear(size)
    obj.as(Int32*).value = tid
    block_off = offsetof(Hash(String, String), @block).to_u64
    Pointer(Void*).new(obj.address + block_off + sizeof(Void*)).value = closure

    heap.add_root(obj.as(Void*))
    heap.collect(scan_stack: false)

    heap.live?(closure).should be_true
    heap.live?(dead).should be_false
  ensure
    heap.destroy
    Gcry::Layout.clear
  end
end

it "IO::Memory falls back to scan_cap (EncodingOptions is struct|Nil)" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry::Layout.register(IO::Memory)
  entry = Gcry::Layout.entry_for(IO::Memory.crystal_instance_type_id).not_nil!
  # Precise offsets would miss inline EncodingOptions.name : String.
  entry.precise_fields?.should be_false
  entry.scan_cap.should eq(instance_sizeof(IO::Memory).to_u32)
ensure
  Gcry::Layout.clear
end

it "Hash(String, Nil) registers for Set-like maps" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry::Layout.register_hash(String, Nil)
  entry = Gcry::Layout.entry_for(Hash(String, Nil).crystal_instance_type_id).not_nil!
  entry.hash?.should be_true
ensure
  Gcry::Layout.clear
end

it "Array(JSON::Any) buffer is scanned (has_inner_pointers)" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry::Layout.register(Array(JSON::Any))
  entry = Gcry::Layout.entry_for(Array(JSON::Any).crystal_instance_type_id).not_nil!
  entry.scan_offsets.includes?(UInt16.new(offsetof(Array(JSON::Any), @buffer))).should be_true
  entry.noscan_offsets.includes?(UInt16.new(offsetof(Array(JSON::Any), @buffer))).should be_false
ensure
  Gcry::Layout.clear
end

it "register_set installs Hash(T, Nil)" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry.register_set(String)
  entry = Gcry::Layout.entry_for(Hash(String, Nil).crystal_instance_type_id).not_nil!
  entry.hash?.should be_true
ensure
  Gcry::Layout.clear
end

it "register_layouts indexes concrete Reference subclasses" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry.register_layouts
  Gcry::Layout.size.should be > 0
  entry = Gcry::Layout.entry_for(Array(String).crystal_instance_type_id)
  entry.should_not be_nil
ensure
  Gcry::Layout.clear
end

it "@unsafe_layouts blacklist increments for stdlib/runtime prefixes" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  before = Gcry::Layout.unsafe_skips_count
  Gcry.register_layouts
  after = Gcry::Layout.unsafe_skips_count
  # The blacklist should have skipped at least the Crystal::* prefixes visible
  # in the test binary (e.g. Crystal::EventLoop, Crystal::System::*, etc.).
  # The walk also skips abstract/private/generic types — we only assert that
  # the blacklist path was exercised (delta > 0), not an exact count.
  (after - before).should be > 0
ensure
  Gcry::Layout.clear
end

it "register_all_from_reference_subclasses is idempotent for the unsafe-skips counter" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry.register_layouts
  mid = Gcry::Layout.unsafe_skips_count
  mid.should be > 0
  # A second pass on the same cleaned table re-counts (counter is non-saturating
  # observability only). The point is that the counter survives a re-run — useful
  # for benchmarks that re-init layouts.
  Gcry.register_layouts
  (Gcry::Layout.unsafe_skips_count >= mid).should be_true
ensure
  Gcry::Layout.clear
end
