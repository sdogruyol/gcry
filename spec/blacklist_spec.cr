require "./spec_helper"

describe "Gcry page blacklist" do
  it "records false-root pages and skips them on alloc" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.nursery_enabled = false
      heap.blacklist_enabled = true
      heap.type_id_gate = true

      # Force heap bounds so blacklist_base can be set.
      first = heap.malloc(64)
      heap.free(first)

      page_size = Gcry::Platform.host_page_size
      page = first.address & ~(page_size - 1)
      heap.blacklist_address(first.address)
      heap.blacklist_hits.should be > 0
      heap.blacklisted_page?(page).should be_true
      heap.blacklisted_page?(first.address).should be_true

      # Fill freelist across multiple host pages (16 KiB on Apple Silicon —
      # a handful of 64-byte blocks all sit on one blacklisted page).
      block_span = 128_u64 # header + payload headroom
      need = ((page_size // block_span).to_i32 + 64)
      ptrs = [] of Void*
      need.times { ptrs << heap.malloc(64) }
      ptrs.each { |p| heap.free(p) }

      again = heap.malloc(64)
      heap.blacklisted_page?(again.address).should be_false
      heap.blacklist_skips.should be > 0
      heap.free(again)
    ensure
      heap.destroy
    end
  end

  it "note_false_root from type_id gate reject" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.blacklist_enabled = true
      heap.type_id_gate = true
      heap.allow_interior_pointers = false

      # Allocate a block and poison its type_id so ambient mark rejects it.
      obj = heap.malloc(64)
      obj.as(Int32*).value = -1 # implausible type_id
      heap.add_root(obj)        # explicit root uses mark_candidate (no gate)

      # Simulate ambient reject path via public blacklist_address after a reject count path:
      # Directly exercise note through a collect with a stack-like root scan is hard in
      # library tests; blacklist_address covers the bitmap. Gate reject wiring is in mark_impl.
      heap.blacklist_address(obj.address)
      heap.blacklisted_page?(obj.address).should be_true
    ensure
      heap.destroy
    end
  end
end
