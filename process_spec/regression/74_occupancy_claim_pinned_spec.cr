require "../../src/gcry"
require "spec"

# A cursor claims a whole `occ` word when it takes it and hands the word's
# blocks out with no shared write (`bitmap_alloc.cr`, "Occupancy is claimed a
# word at a time"). A thread frozen inside its allocation window keeps its
# cursor across the stop, with the claim, and resumes handing blocks out of
# it. The stop's own sweep (`occ = mark`, the in-stop arm, which sweeps a
# pinned chunk) must keep the claim: the claimed blocks are unmarked, and
# without the settle marking them (`cursor_premark_claim`) the sweep clears
# their bits and counts them freed, and the cursor then hands them out
# unoccupied — each to be handed out a second time once a cursor next takes
# the chunk.
#
# Only a process heap stops the world, so only here does the in-stop sweep
# reach a pinned chunk (a library heap's collection never sets
# `@world_stopped`, and its sweep skips the chunk). The frozen thread is
# this one: its slot carries the mid-allocation sentinel across
# `GC.collect`, as a thread the stop caught between the sentinel and its
# pop would.

class Gcry::Heap
  def claim74_position(user : Void*) : {Gcry::ChunkHeader*, Int32, UInt64}
    chunk = chunk_containing(user.address) || raise "#{user} is not in the heap"
    ordinal = chunk_block_ordinal(chunk, Gcry::BlockHeader.from_user(user).address)
    {chunk, (ordinal >> 6).to_i32, 1_u64 << (ordinal & 63)}
  end

  def claim74_slot(chunk : Gcry::ChunkHeader*) : Gcry::CursorSlot*
    index = chunk.value.size_class.to_i32
    index += SIZE_CLASS_COUNT if Gcry::ChunkHeader.atomic?(chunk)
    Gcry::CursorSet.slot(cursor_set, index)
  end

  def claim74_claim(chunk : Gcry::ChunkHeader*) : {Int32, UInt64}
    cursor_claim(chunk)
  end

  def claim74_occ(chunk : Gcry::ChunkHeader*, word : Int32) : UInt64
    Gcry::ChunkHeader.occ_bitmap(chunk)[word]
  end
end

# An atomic class nothing in the spec runner allocates, so the word under
# test is this example's alone.
private CLAIM74_BYTES = 2900

describe "Regression: a cursor frozen mid-allocation keeps its claim through the stop's sweep" do
  it "keeps the claimed word occupied and hands each block out once" do
    heap = Gcry.default_heap
    # The claim is the bitmap allocator's; the header allocator
    # (`GCRY_BITMAP_ALLOC=0` on the header layout) has no cursor words.
    next unless heap.bitmap_alloc?
    lazy = heap.lazy_sweep
    heap.lazy_sweep = false
    begin
      p = GC.malloc_atomic(CLAIM74_BYTES)
      chunk, word, bit = heap.claim74_position(p)
      claim_word, claim = heap.claim74_claim(chunk)
      claim_word.should eq(word)
      claim.should_not eq(0_u64)
      (heap.claim74_occ(chunk, word) & claim).should eq(claim)

      slot = heap.claim74_slot(chunk)
      pinned = heap.cursor_sets_pinned
      slot.value.in_flight = Gcry::CursorSet.sentinel
      begin
        GC.collect
      ensure
        slot.value.in_flight = Pointer(Void).null
      end
      (heap.cursor_sets_pinned - pinned).should be > 0
      heap.last_sweep_after_world.should be_false

      # Still the cursor's, still occupied, and not counted as allocated.
      heap.claim74_claim(chunk).should eq({word, claim})
      (heap.claim74_occ(chunk, word) & claim).should eq(claim)
      heap.live?(p).should be_true
      heap.chunk_occupied_count(chunk).should eq(1)

      seen = Set(UInt64){p.address}
      claim.popcount.times do
        u = GC.malloc_atomic(CLAIM74_BYTES)
        seen.add?(u.address).should be_true
        heap.live?(u).should be_true
      end
      heap.claim74_occ(chunk, word).should eq(claim | bit)
      heap.chunk_occupied_count(chunk).should eq(claim.popcount + 1)
    ensure
      heap.lazy_sweep = lazy
    end
  end
end
