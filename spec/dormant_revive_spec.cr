require "./spec_helper"

# Review finding (PR #1): dormant chunks never revived under BITMAP_ALLOC. The
# pool's chunk walk skipped them and the only revive path was freelist-shaped,
# so every refill after a class went dormant mapped a new chunk while the
# dormant ones sat in the VMA forever. This pins the fix: after a class's
# chunks go dormant, allocating again must revive one rather than map another.
describe "bitmap pool revives dormant chunks" do
  it "reuses a dormant chunk instead of mapping a new one" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.release_empty_chunks = true
      heap.empty_chunk_retain = 64_u64 * 1024 * 1024 # keep empties dormant, never munmap

      # Fill more than one chunk of one class, then free everything.
      ptrs = Array(Void*).new(20_000) { heap.malloc(48) }
      ptrs.each { |p| heap.free(p) }
      heap.collect(scan_stack: false, roots: [] of Void*)

      dormant = 0
      heap.each_chunk { |c| dormant += 1 if Gcry::ChunkHeader.dormant?(c) }
      dormant.should be > 0
      dormant_bytes = heap.dormant_chunk_bytes
      dormant_bytes.should be > 0

      chunks_before = 0
      heap.each_chunk { |_| chunks_before += 1 }
      revives_before = heap.bitmap_dormant_revives

      # Allocate again: the pool must revive, not map.
      again = Array(Void*).new(5_000) { heap.malloc(48) }
      chunks_after = 0
      heap.each_chunk { |_| chunks_after += 1 }

      heap.bitmap_dormant_revives.should be > revives_before
      heap.dormant_chunk_bytes.should be < dormant_bytes
      chunks_after.should eq(chunks_before)
      again.size.should eq(5_000)
      # And the revived chunk's memory is usable: write and read back.
      again.each_with_index { |p, i| p.as(UInt64*).value = i.to_u64 }
      again.each_with_index { |p, i| p.as(UInt64*).value.should eq(i.to_u64) }
    ensure
      heap.destroy
    end
  end
end
