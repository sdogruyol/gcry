require "./spec_helper"

# A cursor claims a whole `occ` word when it takes it and hands its blocks
# out with no shared write (`bitmap_alloc.cr`, "Occupancy is claimed a word
# at a time"). These pin down what the claim must not change: a claimed
# block is not allocated to anyone who asks, a free of one is refused, a
# retiring cursor gives the claim back, and a sweep that can run while the
# claim is held keeps it and counts none of it freed.
class Gcry::Heap
  # The chunk, word and bit of *user*'s block.
  def claim_spec_position(user : Void*) : {Gcry::ChunkHeader*, Int32, UInt64}
    chunk = chunk_containing(user.address) || raise "#{user} is not in the heap"
    ordinal = chunk_block_ordinal(chunk, Gcry::BlockHeader.from_user(user).address)
    {chunk, (ordinal >> 6).to_i32, 1_u64 << (ordinal & 63)}
  end

  # The user pointer of block *bit* of *word* in *chunk*.
  def claim_spec_user(chunk : Gcry::ChunkHeader*, word : Int32, bit : Int) : Void*
    block_bytes = @block_bytes[chunk.value.size_class.to_i32]
    ordinal = (word.to_u64 << 6) &+ bit.to_u64
    Pointer(Void).new(Gcry::ChunkHeader.data_start(chunk).address &+ ordinal &* block_bytes &+ Gcry::BlockHeader::SIZE)
  end

  def claim_spec_occ(chunk : Gcry::ChunkHeader*, word : Int32) : UInt64
    Gcry::ChunkHeader.occ_bitmap(chunk)[word]
  end

  def claim_spec_mark(chunk : Gcry::ChunkHeader*, word : Int32) : UInt64
    Gcry::ChunkHeader.mark_bitmap(chunk)[word]
  end

  def claim_spec_claim(chunk : Gcry::ChunkHeader*) : {Int32, UInt64}
    cursor_claim(chunk)
  end
end

private def claim_spec_heap : Gcry::Heap
  heap = Gcry::Heap.new
  heap.bitmap_alloc = true
  heap.nursery_enabled = false
  heap.gc_threshold = UInt64::MAX
  heap
end

private def claim_spec_drift_free(heap : Gcry::Heap) : Nil
  Gcry::Invariant.live_objects_drift(heap).should eq(0)
  Gcry::Invariant.free_bytes_drift(heap).should eq(0)
end

describe "occupancy claimed a word at a time" do
  it "sets the word's free blocks in occ and counts only what it handed out" do
    heap = claim_spec_heap
    begin
      p = heap.malloc(48)
      chunk, word, bit = heap.claim_spec_position(p)
      claim_word, claim = heap.claim_spec_claim(chunk)
      claim_word.should eq(word)
      claim.should_not eq(0_u64)
      (claim & bit).should eq(0_u64)
      occ = heap.claim_spec_occ(chunk, word)
      (occ & claim).should eq(claim)
      (occ & bit).should eq(bit)

      heap.chunk_occupied_count(chunk).should eq(1)
      heap.live?(p).should be_true
      q = heap.claim_spec_user(chunk, word, claim.trailing_zeros_count)
      heap.is_heap_ptr(q).should be_true
      heap.live?(q).should be_false
      heap.block_allocated_public?(chunk, Gcry::BlockHeader.from_user(q)).should be_false
      heap.live_objects.should eq(1)
      claim_spec_drift_free(heap)
    ensure
      heap.destroy
    end
  end

  # Raw `occ` says a claimed block is occupied. Accepting a free of it — a
  # double free, or a stale pointer into a word the cursor took since — would
  # clear the bit under the cursor, which then hands the block out with it
  # clear, and the next cursor on the chunk hands it out again.
  it "refuses a free of a claimed block, from this thread and another, and hands it out once" do
    heap = claim_spec_heap
    begin
      p = heap.malloc(48)
      chunk, word, bit = heap.claim_spec_position(p)
      _, claim = heap.claim_spec_claim(chunk)
      claim.popcount.should be >= 2
      q = heap.claim_spec_user(chunk, word, claim.trailing_zeros_count)
      r = heap.claim_spec_user(chunk, word, (claim & (claim &- 1)).trailing_zeros_count)

      double_frees = heap.double_frees
      expect_raises(ArgumentError, /double free/) { heap.free(q) }
      result = Gcry::Heap::FreeResult::Freed
      # Another thread has no set of its own on this heap: it finds the
      # owner's slot through the table.
      t = Thread.new { result = heap.free_result(r) }
      t.join
      result.should eq(Gcry::Heap::FreeResult::NotAllocated)
      heap.live_objects.should eq(1)
      claim_spec_drift_free(heap)

      seen = Set(UInt64){p.address}
      claim.popcount.times do
        u = heap.malloc(48)
        seen.add?(u.address).should be_true
        heap.live?(u).should be_true
      end
      seen.includes?(q.address).should be_true
      seen.includes?(r.address).should be_true
      heap.claim_spec_occ(chunk, word).should eq(claim | bit)
      heap.chunk_occupied_count(chunk).should eq(claim.popcount + 1)
      heap.live_objects.should eq(claim.popcount + 1)
      claim_spec_drift_free(heap)
      heap.double_frees.should eq(double_frees)
    ensure
      heap.destroy
    end
  end

  it "takes a handed-out block's free from another thread while the claim is held" do
    heap = claim_spec_heap
    begin
      p = heap.malloc(48)
      p2 = heap.malloc(48)
      chunk, word, bit2 = heap.claim_spec_position(p2)
      result = Gcry::Heap::FreeResult::NotAllocated
      t = Thread.new { result = heap.free_result(p2) }
      t.join
      result.should eq(Gcry::Heap::FreeResult::Freed)
      (heap.claim_spec_occ(chunk, word) & bit2).should eq(0_u64)
      heap.live?(p2).should be_false
      heap.live?(p).should be_true
      heap.live_objects.should eq(1)
      claim_spec_drift_free(heap)
    ensure
      heap.destroy
    end
  end

  # Without the release the claimed bits stay in `occ`, the sweep reclaims
  # them as dead objects and `live_objects` loses that many.
  it "gives the claim back when a stop retires the cursor" do
    heap = claim_spec_heap
    begin
      p = heap.malloc(48)
      chunk, word, bit = heap.claim_spec_position(p)
      _, claim = heap.claim_spec_claim(chunk)
      released = heap.cursor_claims_released
      heap.collect(scan_stack: false, roots: [p])
      heap.claim_spec_claim(chunk).should eq({-1, 0_u64})
      heap.claim_spec_occ(chunk, word).should eq(bit)
      (heap.claim_spec_mark(chunk, word) & claim).should eq(0_u64)
      (heap.cursor_claims_released - released).should eq(claim.popcount)
      heap.chunk_occupied_count(chunk).should eq(1)
      heap.live?(p).should be_true
      heap.live_objects.should eq(1)
      claim_spec_drift_free(heap)
    ensure
      heap.destroy
    end
  end

  # The after-world sweep holds the class lock and sweeps a chunk a cursor
  # took after the stop; the claim it made then has no object behind it and
  # must survive `occ = mark` without counting as freed.
  it "marks a claim made while the after-world sweep can run" do
    heap = claim_spec_heap
    heap.lazy_sweep = true
    begin
      p = heap.malloc(48)
      roots = [p]
      taken = Pointer(Void).null
      heap.post_stw_hook = ->(stage : Symbol) do
        if stage == :after_start_world
          # A class nothing else on this heap uses: its first block takes a
          # fresh chunk and claims its first word, with `@collecting` up.
          taken = heap.malloc(400)
          roots << taken
        end
        nil
      end
      heap.collect(scan_stack: false, roots: roots)
      heap.post_stw_hook = nil
      fail "the hook did not allocate" if taken.null?
      heap.last_sweep_after_world.should be_true

      chunk, word, bit = heap.claim_spec_position(taken)
      claim_word, claim = heap.claim_spec_claim(chunk)
      claim_word.should eq(word)
      claim.should_not eq(0_u64)
      (heap.claim_spec_occ(chunk, word) & claim).should eq(claim)
      heap.chunk_occupied_count(chunk).should eq(1)
      heap.live_objects.should eq(2)
      claim_spec_drift_free(heap)

      # The claim is still the cursor's: its blocks come out once each, all
      # occupied.
      seen = Set(UInt64){taken.address}
      claim.popcount.times do
        u = heap.malloc(400)
        seen.add?(u.address).should be_true
        heap.live?(u).should be_true
      end
      heap.claim_spec_occ(chunk, word).should eq(claim | bit)
      heap.live_objects.should eq(claim.popcount + 2)
      claim_spec_drift_free(heap)
    ensure
      heap.destroy
    end
  end
end
