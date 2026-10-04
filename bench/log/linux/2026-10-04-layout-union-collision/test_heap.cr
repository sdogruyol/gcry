require "json"
require "../../../../../src/gcry"

Gcry::Layout.clear
Gcry::Layout.enabled = true
Gcry::Layout.register(Array(JSON::Any))
tid = Array(JSON::Any).crystal_instance_type_id
entry = Gcry::Layout.entry_for(tid).not_nil!
puts "Array(JSON::Any) instance=#{instance_sizeof(Array(JSON::Any))} alloc_size=#{entry.alloc_size} scan=#{entry.scan_offsets.to_a} noscan=#{entry.noscan_offsets.to_a} sizeof(JSON::Any)=#{sizeof(JSON::Any)}"

# What a real two-element buffer holds: union tag of element 0 at +0.
arr = [JSON::Any.new([] of JSON::Any), JSON::Any.new("x")]
buf = arr.to_unsafe.as(Int32*)
puts "real buffer tag[0]=#{buf.value} (Array(JSON::Any) id=#{tid}) tag[1]=#{(buf + 4).value} (String id=#{String.crystal_instance_type_id})"

heap = Gcry::Heap.new
heap.gc_threshold = UInt64::MAX
heap.layout_precise = true
size = sizeof(JSON::Any) * 2
child0 = heap.malloc(48)
child1 = heap.malloc(48)
b = heap.malloc(size.to_i32).as(UInt8*)
b.clear(size)
b.as(Int32*).value = tid
Pointer(Void*).new(b.address + 8).value = child0
(b + 16).as(Int32*).value = String.crystal_instance_type_id
Pointer(Void*).new(b.address + 24).value = child1
heap.add_root(b.as(Void*))
heap.collect(scan_stack: false)
puts "block payload=#{heap.block_payload(heap.find_block(b.as(Void*)).not_nil!)} child0 live=#{heap.live?(child0)} child1 live=#{heap.live?(child1)}"
heap.destroy
