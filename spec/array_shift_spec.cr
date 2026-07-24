require "./spec_helper"

# Array#shift advances @buffer into the allocation. Base-pointer-only on *heap*
# marks freed the buffer and dangling String elements (CI stress SIGSEGV).
it "Array(String) shift + collect keeps elements with base-only ambient roots" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    heap.allow_interior_pointers = false
    heap.layout_precise = false
    heap.type_id_gate = false

    keep = [] of String
    20.times { |i| keep << ("x" * (32 + i % 16)) }
    10.times { keep.shift }

    heap.add_root(Pointer(Void).new(keep.object_id))
    heap.collect(scan_stack: false)

    sum = 0
    keep.each { |s| sum += s.bytesize }
    sum.should be > 0
    keep.size.should eq(10)
  ensure
    heap.destroy
  end
end
