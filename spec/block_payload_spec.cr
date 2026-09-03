require "./spec_helper"

# Phase 7.6: `header.value.size` is the last header field with no alternative
# source, and it is what keeps the 16-byte header alive. `Heap#block_payload`
# derives the same number from the chunk instead.
#
# This is the correctness argument for removing the header, so it is pinned
# directly: for every allocated block, across every size class and both kinds,
# the chunk-derived payload must equal what the header says. If these ever
# disagree, a headerless build scans an object with the wrong length — reading
# past it, or missing the pointers in its tail.
describe "block_payload (chunk-derived size)" do
  it "agrees with the header for every allocated small block" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX

      kept = [] of Void*
      # Span many size classes and both kinds.
      [8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 512, 1024, 4096].each do |bytes|
        60.times do |i|
          kept << (i.even? ? heap.malloc(bytes) : heap.malloc_atomic(bytes))
        end
      end

      checked = 0
      heap.each_chunk do |chunk|
        next if Gcry::ChunkHeader.large?(chunk)
        cls = chunk.value.size_class.to_i32
        block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(cls).to_u64
        cursor = Gcry::ChunkHeader.data_start(chunk).as(UInt8*)
        limit = Gcry::ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(Gcry::BlockHeader*)
          if heap.block_allocated_public?(chunk, header)
            checked += 1
            heap.block_payload(chunk, header).should eq(header.value.size)
          end
          cursor += block_bytes
        end
      end
      checked.should be > 500
      kept.size.should be > 0
    ensure
      heap.destroy
    end
  end

  it "agrees for large blocks, which own their whole mapping" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      kept = [] of Void*
      [64 * 1024, 256 * 1024, 1024 * 1024].each { |b| kept << heap.malloc(b) }

      seen = 0
      heap.each_chunk do |chunk|
        next unless Gcry::ChunkHeader.large?(chunk)
        header = Gcry::ChunkHeader.data_start(chunk).as(Gcry::BlockHeader*)
        next if Gcry::BlockHeader.free?(header)
        seen += 1
        # A large object's header size is what was asked for; the mapping is
        # rounded up, so the chunk-derived extent is an upper bound that must
        # cover it and never fall short.
        heap.block_payload(chunk, header).should be >= header.value.size
      end
      seen.should eq(kept.size)
    ensure
      heap.destroy
    end
  end

  it "resolves without a chunk in hand" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      p = heap.malloc(96)
      h = Gcry::BlockHeader.from_user(p)
      heap.block_payload(h).should eq(h.value.size)
    ensure
      heap.destroy
    end
  end
end
