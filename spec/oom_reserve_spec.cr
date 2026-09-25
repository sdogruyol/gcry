require "./spec_helper"

class Gcry::Heap
  # Allocate as a thread inside `oom!` does.
  def as_oom_report_for_spec(&)
    @@oom_depth += 1
    begin
      yield
    ensure
      @@oom_depth -= 1
    end
  end

  def oom_reserve_range_for_spec : Range(UInt64, UInt64)
    @oom_reserve_base...(@oom_reserve_base + @oom_reserve_size)
  end
end

private def reserve_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.bitmap_alloc = true
  heap.nursery_enabled = false
  heap.gc_threshold = UInt64::MAX
  # Empty chunks are unmapped at once: the path a reserve chunk must not take.
  heap.release_empty_chunks = true
  heap.empty_chunk_retain = 0_u64
  heap.setup_oom_reserve(1_u64 << 20)
  heap
end

# More 48-byte blocks than one chunk holds, so the reserve's cursor moves off
# its first chunk and the next sweep finds that chunk empty and unpinned.
REPORT_BLOCKS = 3000

describe "out-of-memory reserve" do
  it "serves reports, keeps its chunks through sweeps and reuses them" do
    heap = reserve_heap
    begin
      range = heap.oom_reserve_range_for_spec
      heap.oom_reserve_bytes.should eq(1_u64 << 20)
      8.times do
        heap.as_oom_report_for_spec do
          REPORT_BLOCKS.times { range.includes?(heap.malloc(48).address).should be_true }
        end
        # Past the one cycle of grace a fully free chunk gets before release.
        3.times { heap.collect(scan_stack: false) }
        # Every chunk laid on the region is still a chunk after the sweep.
        heap.oom_reserve_chunks_used.times do |i|
          probe = Pointer(Void).new(range.begin + i.to_u64 * Gcry::Heap::SMALL_CHUNK_BYTES + 4096)
          heap.chunk_address_of(probe).should_not eq(0_u64)
        end
        # Reports of the same size reuse what the sweep freed: one report's
        # worth (two chunks) plus the chunk the reserve's cursor was pinned on,
        # which is not swept while it stands there. Without reuse the 1 MiB
        # region (8 chunks) runs out within a few rounds and the report fails.
        heap.oom_reserve_chunks_used.should be <= 3
      end
      heap.oom_reserve_allocations.should eq(8_u64 * REPORT_BLOCKS)
    ensure
      heap.destroy
    end
  end

  it "never hands a reserve chunk to an ordinary allocation" do
    heap = reserve_heap
    begin
      range = heap.oom_reserve_range_for_spec
      heap.as_oom_report_for_spec { REPORT_BLOCKS.times { heap.malloc(48) } }
      # The first reserve chunk is empty and off the reserve's cursor now.
      heap.collect(scan_stack: false)
      (REPORT_BLOCKS * 3).times { range.includes?(heap.malloc(48).address).should be_false }
    ensure
      heap.destroy
    end
  end
end
