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
    m.parallel_mark_workers.should eq(1)
    text = Gcry.prometheus_text(heap)
    text.includes?("gcry_collections_total").should be_true
    text.includes?("gcry_heap_bytes").should be_true
    text.includes?("gcry_parallel_mark_workers").should be_true
    text.includes?("gcry_clear_stack_calls_total").should be_true
    text.includes?("gcry_fiber_scrub_runs_total").should be_true
    json = Gcry::Observability.json_stats(heap)
    json.includes?("phase_mark_ns").should be_true
    json.includes?("parallel_mark_stolen").should be_true
    json.includes?("clear_stack_calls").should be_true
  ensure
    heap.destroy
  end
end
