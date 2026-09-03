require "./spec_helper"

# Phase 7.2: atomic and pointerful blocks live in separate chunks, so the
# `ATOMIC` bit can leave the block header without a per-allocation store to
# maintain a per-block atomic bitmap (the accounting-on-the-alloc-path failure
# that rejected 2026-08-01-ec4-alloc-bits).
#
# The invariant this pins is the one a headerless build will *rely* on: asking
# the chunk must give the same answer the header gives today. If a chunk ever
# mixes kinds, a headerless scan reads the chunk kind, believes an unscanned
# block is atomic when it holds pointers, and drops everything it references.
describe "chunk kind (atomic vs pointerful)" do
  it "keeps POOL_SLOTS at two cursors per size class" do
    # POOL_SLOTS is a literal (GC.init cannot run a computed initializer), so
    # the relationship it encodes is pinned here instead of by the compiler.
    Gcry::POOL_SLOTS.should eq(Gcry::SIZE_CLASS_COUNT * 2)
  end

  it "never mixes kinds within a bitmap chunk" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX

      kept = [] of Void*
      3_000.times do |i|
        kept << (i % 3 == 0 ? heap.malloc_atomic(48) : heap.malloc(48))
      end

      checked = 0
      atomic_chunks = 0
      pointerful_chunks = 0
      heap.each_chunk do |chunk|
        next if Gcry::ChunkHeader.large?(chunk)
        next unless heap.bitmap_alloc_chunk_public?(chunk)
        kind = Gcry::ChunkHeader.atomic?(chunk)
        kind ? (atomic_chunks += 1) : (pointerful_chunks += 1)
        cls = chunk.value.size_class.to_i32
        block_bytes = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(cls).to_u64
        cursor = Gcry::ChunkHeader.data_start(chunk).as(UInt8*)
        limit = Gcry::ChunkHeader.data_end(chunk).as(UInt8*)
        while (cursor + block_bytes) <= limit
          header = cursor.as(Gcry::BlockHeader*)
          if heap.block_allocated_public?(chunk, header)
            checked += 1
            Gcry::BlockHeader.atomic?(header).should eq(kind)
          end
          cursor += block_bytes
        end
      end

      checked.should be > 0
      # Both kinds were requested, so both kinds of chunk must exist — otherwise
      # the test passed by never exercising the split.
      atomic_chunks.should be > 0
      pointerful_chunks.should be > 0
      kept.size.should eq(3_000)
    ensure
      heap.destroy
    end
  end
end

describe "chunk kind under reuse" do
  it "cannot hand a reused block to the other kind" do
    # The reason chunk kinds beat a per-block atomic bitmap: a bitmap would need
    # a store on every allocation to clear the bit a previous occupant set.
    # With kinds, a freed pointerful block can only ever be reused as
    # pointerful, because its chunk is pointerful. This pins that.
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX

      # Churn both kinds so freed blocks are recycled.
      4.times do
        batch = [] of Void*
        2_000.times { |i| batch << (i.even? ? heap.malloc_atomic(64) : heap.malloc(64)) }
        batch.each_with_index { |p, i| heap.free(p) if i % 3 == 0 }
        heap.collect(scan_stack: false, roots: batch)
      end

      heap.each_chunk do |chunk|
        next if Gcry::ChunkHeader.large?(chunk)
        next unless heap.bitmap_alloc_chunk_public?(chunk)
        kind = Gcry::ChunkHeader.atomic?(chunk)
        cls = chunk.value.size_class.to_i32
        bb = Gcry::BlockHeader::SIZE.to_u64 + Gcry::SizeClasses.payload(cls).to_u64
        cur = Gcry::ChunkHeader.data_start(chunk).as(UInt8*)
        lim = Gcry::ChunkHeader.data_end(chunk).as(UInt8*)
        while (cur + bb) <= lim
          h = cur.as(Gcry::BlockHeader*)
          Gcry::BlockHeader.atomic?(h).should eq(kind) if heap.block_allocated_public?(chunk, h)
          cur += bb
        end
      end
    ensure
      heap.destroy
    end
  end
end
