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

# An atomic class nothing in the spec runner allocates on purpose. Something
# can still land in it: a failing example's message is an atomic `String` the
# runner keeps to the end of the run, and 95's crashed child's output (2 864–
# 2 954 bytes) was one, in the chunk this example then allocated from, which
# read `chunk_occupied_count` 2 (`bench/log/linux/2026-11-03-arm64-ci/`). So
# the example first takes a chunk in which its block is the only one
# allocated (`claim74_alone`), and every count below is that chunk's.
private CLAIM74_BYTES = 2900

# Generous: a chunk of this class holds a few dozen blocks, and what the
# runner leaves in the class is a handful of strings.
private CLAIM74_FILLER_LIMIT = 4096

# Allocate in the class until a block comes back that is its chunk's only
# allocated one: the cursor has moved to a chunk nothing else occupies,
# normally a fresh one. The blocks before it stay live in *fillers*, so the
# cursor does not come back to their chunks. Returns that block, its chunk,
# word and bit.
private def claim74_alone(heap, fillers : Array(Void*)) : {Void*, Gcry::ChunkHeader*, Int32, UInt64}
  loop do
    p = GC.malloc_atomic(CLAIM74_BYTES)
    chunk, word, bit = heap.claim74_position(p)
    return {p, chunk, word, bit} if heap.chunk_occupied_count(chunk) == 1
    fillers << p
    fail "no chunk of the class to itself after #{fillers.size} blocks" if fillers.size >= CLAIM74_FILLER_LIMIT
  end
end

describe "Regression: a cursor frozen mid-allocation keeps its claim through the stop's sweep" do
  it "keeps the claimed word occupied and hands each block out once" do
    heap = Gcry.default_heap
    # The claim is the bitmap allocator's; the header allocator
    # (`GCRY_BITMAP_ALLOC=0` on the header layout) has no cursor words.
    next unless heap.bitmap_alloc?
    lazy = heap.lazy_sweep
    heap.lazy_sweep = false
    begin
      fillers = Array(Void*).new(CLAIM74_FILLER_LIMIT)
      p, chunk, word, bit = claim74_alone(heap, fillers)
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
      # The fillers stay live to here, so the cursor never went back to
      # their chunks.
      fillers.each { |f| heap.live?(f).should be_true }
    ensure
      heap.lazy_sweep = lazy
    end
  end
end
