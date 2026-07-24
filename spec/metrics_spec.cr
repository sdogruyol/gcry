require "./spec_helper"

it "Gcry.metrics exposes pause and generation counters" do
  heap = Gcry::Heap.new
  begin
    heap.gc_threshold = UInt64::MAX
    keep = heap.malloc(32)
    heap.add_root(keep)
    heap.malloc(32)
    heap.collect(scan_stack: false)
    m = Gcry.metrics(heap)
    m.collections.should be > 0
    m.major_collections.should be > 0
    m.heap_size.should be > 0
    m.pause_count.should be > 0
    text = Gcry.prometheus_text(heap)
    text.includes?("gcry_collections_total").should be_true
    text.includes?("gcry_heap_bytes").should be_true
  ensure
    heap.destroy
  end
end
