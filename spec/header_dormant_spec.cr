require "./spec_helper"

private def header_dormant_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.bitmap_alloc = false
  heap.nursery_enabled = false
  heap.gc_threshold = UInt64::MAX
  heap.release_empty_chunks = true
  # The empty-chunk release is gated on the *process* having one mutator
  # thread: `release_empty_chunks_this_collect?` returns false under
  # `sweep_multi_mutator?` unless one of these knobs is on, and
  # `munmap_empty_chunks_this_collect?` the same. A spec process's thread count
  # is not this example's to control — one thread left running by another
  # example turns the whole release path off, and every assertion here then
  # fails for a reason that has nothing to do with what it tests. Measured
  # 2026-09-17: one extra live thread reproduces the aarch64/kcov failure line
  # byte for byte (`chunks=8 dormant=0 fully_free=1048576 unmapped=0`), and
  # these two restore it exactly. They only affect the multi-mutator branch —
  # single-mutator returns true before reading them — so what this example
  # measures is unchanged.
  heap.parallel_empty_chunk_dormant = true
  heap.parallel_empty_chunk_munmap = true
  heap.empty_chunk_warm_retain = 0_u64
  heap.empty_chunk_retain = 64_u64 * 1024 * 1024
  heap
end

{% if flag?(:gcry_block_headers) %}
  describe "header dormant chunk revival" do
    it "accounts capacity once across repeated dormant cycles" do
      heap = header_dormant_heap
      begin
        first = heap.malloc(48)
        heap.free(first)
        capacity = heap.free_bytes
        mapped = heap.heap_size
        3.times do
          heap.collect(scan_stack: false)
          heap.dormant_chunk_bytes.should eq(mapped)
          again = heap.malloc(48)
          heap.heap_size.should eq(mapped)
          heap.free_bytes.should eq(capacity - 48)
          heap.free(again)
          heap.free_bytes.should eq(capacity)
        end
      ensure
        heap.destroy
      end
    end

    it "counts newly dead capacity before a dormant chunk is revived" do
      heap = header_dormant_heap
      begin
        heap.malloc(48)
        capacity = heap.free_bytes + 48
        heap.collect(scan_stack: false)
        heap.dormant_chunk_bytes.should be > 0
        heap.free_bytes.should eq(capacity)
        heap.malloc(48)
        heap.free_bytes.should eq(capacity - 48)
      ensure
        heap.destroy
      end
    end

    it "clears reused bytes on the metadata page as well as released pages" do
      heap = header_dormant_heap
      begin
        # The first physical page contains chunk metadata, so dormancy cannot
        # discard it. Dirty every block to include the payloads on that page.
        seed = heap.malloc(48)
        count = (heap.free_bytes // 48).to_i + 1
        ptrs = [seed]
        (count - 1).times { ptrs << heap.malloc(48) }
        ptrs.each { |p| p.as(UInt8*).to_slice(48).fill(0xa5_u8) }
        heap.collect(scan_stack: false)
        heap.dormant_chunk_bytes.should be > 0
        count.times do
          p = heap.malloc(48)
          p.as(UInt8*).to_slice(48).all?(&.zero?).should be_true
        end
      ensure
        heap.destroy
      end
    end
  end
{% end %}
