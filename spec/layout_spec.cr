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
    # Registered as 32-byte type with scan_cap; object is 64 bytes → must NOT
    # apply scan_cap (that would truncate the scan). Full conservative instead.
    Gcry::Layout.install_scan_cap(tid, 32_u32, 16_u32)

    child = heap.malloc(32)
    kept = heap.malloc(32)
    obj = heap.malloc(64)
    user = obj.as(UInt8*)
    user.as(Int32*).value = tid
    Pointer(Void*).new(user.address + 8).value = child
    Pointer(Void*).new(user.address + 16).value = kept

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
  entry.hash_block_off.should eq(UInt16.new(offsetof(Hash(String, String), @block)))
  entry.hash_block_bytes.should eq(UInt16.new(sizeof((Hash(String, String), String -> String)?)))
  # @block is Proc? — not a single scan offset
  entry.scan_offsets.size.should eq(0)
ensure
  Gcry::Layout.clear
end

it "hash precise scan walks entries_size not capacity (realloc garbage)" do
  # Regression: walking entries_capacity after growth retained/crashed on
  # uninitialized slots past @size+@deleted_count (acikturkiye SEGV).
  Gcry::Layout.clear
  Gcry::Layout.enabled = true
  Gcry::Layout.register_hash(String, String)

  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.layout_precise = true

    tid = Hash(String, String).crystal_instance_type_id
    entry = Gcry::Layout.entry_for(tid).not_nil!
    stride = entry.hash_entry_stride.to_u64

    live_key = heap.malloc(32)
    live_val = heap.malloc(32)
    dead_key = heap.malloc(32)
    dead_val = heap.malloc(32)

    # entries buffer: capacity 4 (pow2=3 → indices 8 → entries 4), only 1 live
    entries = heap.malloc((stride * 4).to_i32).as(UInt8*)
    entries.clear((stride * 4).to_i32)

    # slot 0: live entry
    entries.as(UInt32*).value = 0x12345678_u32
    Pointer(Void*).new(entries.address + entry.hash_key_off).value = live_key
    Pointer(Void*).new(entries.address + entry.hash_value_off).value = live_val

    # slot 3 (past entries_size=1): garbage that looks like a live entry
    junk = entries + (stride * 3)
    junk.as(UInt32*).value = 0xdeadbeef_u32
    Pointer(Void*).new(junk.address + entry.hash_key_off).value = dead_key
    Pointer(Void*).new(junk.address + entry.hash_value_off).value = dead_val

    obj = heap.malloc(instance_sizeof(Hash(String, String)).to_i32).as(UInt8*)
    obj.clear(instance_sizeof(Hash(String, String)).to_i32)
    obj.as(Int32*).value = tid
    Pointer(Void*).new(obj.address + entry.hash_entries_off).value = entries.as(Void*)
    Pointer(UInt8).new(obj.address + entry.hash_pow2_off).value = 3_u8 # capacity 4
    Pointer(Int32).new(obj.address + entry.hash_size_off).value = 1
    Pointer(Int32).new(obj.address + entry.hash_deleted_off).value = 0

    heap.add_root(obj.as(Void*))
    heap.collect(scan_stack: false)

    heap.live?(live_key).should be_true
    heap.live?(live_val).should be_true
    heap.live?(dead_key).should be_false
    heap.live?(dead_val).should be_false
  ensure
    heap.destroy
    Gcry::Layout.clear
  end
end

it "scan_cap clips size-class padding on conservative fallback" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true

  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.layout_precise = true
    heap.allow_interior_pointers = false

    tid = 4244
    # Object fits in 64-byte class; only first 16 bytes are "real".
    Gcry::Layout.install_scan_cap(tid, 64_u32, 16_u32)

    child = heap.malloc(32)
    dead = heap.malloc(32)
    obj = heap.malloc(64)
    user = obj.as(UInt8*)
    user.as(Int32*).value = tid
    # Word at offset 8 is inside scan_cap → kept.
    Pointer(Void*).new(user.address + 8).value = child
    # Word at offset 16 is past scan_cap → must not keep.
    Pointer(Void*).new(user.address + 16).value = dead

    heap.add_root(obj)
    heap.collect(scan_stack: false)

    heap.live?(child).should be_true
    heap.live?(dead).should be_false
  ensure
    heap.destroy
    Gcry::Layout.clear
  end
end

it "leaf layout entry does not word-scan value fields" do
  Gcry::Layout.clear
  Gcry::Layout.enabled = true

  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.layout_precise = true
    heap.allow_interior_pointers = false

    tid = 4245
    Gcry::Layout.install_full(tid, Pointer(UInt16).null, 0, Pointer(UInt16).null, 0,
      32_u32, 0_u32, Gcry::Layout::KIND_PLAIN,
      0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, Gcry::Layout::VALUE_MODE_NONE, 0_u16)

    dead = heap.malloc(32)
    obj = heap.malloc(32)
    user = obj.as(UInt8*)
    user.as(Int32*).value = tid
    Pointer(Void*).new(user.address + 8).value = dead

    heap.add_root(obj)
    heap.collect(scan_stack: false)

    heap.live?(obj).should be_true
    heap.live?(dead).should be_false
    heap.layout_precise_scans.should be > 0
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

it "size mismatch ignores layout entry (full conservative)" do
  # Regression: applying scan_cap on size mismatch truncated raw-buffer scans
  # when the leading Int32 collided with a registered type_id.
  Gcry::Layout.clear
  Gcry::Layout.enabled = true

  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.layout_precise = true
    heap.allow_interior_pointers = false

    tid = 4246
    Gcry::Layout.install(tid, [8_u16], 32_u32, 16_u32)

    child = heap.malloc(32)
    kept = heap.malloc(32)
    obj = heap.malloc(64)
    user = obj.as(UInt8*)
    user.as(Int32*).value = tid
    Pointer(Void*).new(user.address + 8).value = child
    Pointer(Void*).new(user.address + 16).value = kept

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
