require "./spec_helper"

# Phase 7.7: a large chunk must report that it contains its own block header.
#
# `scan_object` looks a large object's chunk up by its *header* address, and
# under headerless that header is reserved before `data_start`. When
# `ChunkHeader.contains?` started at `data_start`, the lookup returned nil for
# every large object and `scan_object` silently returned without scanning it —
# so everything a large object referenced was reclaimed. It took the Heap's own
# MarkStack, worker-thread Array and finalizer registry with it, and surfaced as
# `property_test` dying at ~12 000 iterations for every seed. With headers in
# front the header *is* `data_start`, which is why the header build never saw it.
describe "large chunk containment" do
  it "contains its block header, its object, and its last byte — but not the ChunkHeader" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      kept = heap.malloc(200_000)
      seen = 0
      heap.each_chunk do |chunk|
        next unless Gcry::ChunkHeader.large?(chunk)
        seen += 1
        header = Gcry::ChunkHeader.large_header(chunk)
        user = Gcry::ChunkHeader.large_user(chunk)
        finish = chunk.address + chunk.value.mapped_bytes
        Gcry::ChunkHeader.contains?(chunk, header.address).should be_true
        Gcry::ChunkHeader.contains?(chunk, user.address).should be_true
        Gcry::ChunkHeader.contains?(chunk, finish - 1).should be_true
        Gcry::ChunkHeader.contains?(chunk, finish).should be_false
        # The ChunkHeader struct itself is metadata, never a block.
        Gcry::ChunkHeader.contains?(chunk, chunk.address).should be_false
        # And the chunk lookup that scan_object relies on must resolve the header.
        heap.chunk_containing_public?(header.address).should be_true
      end
      seen.should eq(1)
      kept.null?.should be_false
    ensure
      heap.destroy
    end
  end

  it "does not let a small chunk's metadata region resolve" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      p = heap.malloc(48)
      heap.each_chunk do |chunk|
        next if Gcry::ChunkHeader.large?(chunk)
        # Inside the bitmaps, before data_start: must not be "contained".
        Gcry::ChunkHeader.contains?(chunk, chunk.address + Gcry::ChunkHeader::SIZE).should be_false
        Gcry::ChunkHeader.contains?(chunk, Gcry::ChunkHeader.data_start(chunk).address).should be_true
      end
      p.null?.should be_false
    ensure
      heap.destroy
    end
  end
end
