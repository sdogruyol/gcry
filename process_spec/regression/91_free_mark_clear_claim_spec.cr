require "../../src/gcry"
require "spec"

# A bitmap `free` clears its block's `occ` bit and then its `mark` bit
# (`Heap#bitmap_free_block`), under the class lock. The chunk's cursor owner
# claims words of the chunk with no lock (`cursor_advance_word`), and before
# 2026-10-31 nothing kept it out of the gap: it could claim the freed block
# there and hand it out, a stop could mark it (as a claim, an `in_flight`
# root, or a block the trace reaches), and the free's `mark` clear then
# wiped that mark. The incremental finishing slice sweeps on the cycle's
# marks with no settle, so it took the block out of `occ` while the program
# held it: free to the next claim of its word, a block handed out twice. A
# `free` now holds FREEING on the chunk across both clears and the owner
# claims nothing from it meanwhile (`ChunkHeader::Flags::FREEING`).
#
# The window, forced: thread A fills a chunk of a class nothing else
# allocates until its cursor stands on it with nothing left to claim;
# thread F frees A's last block and parks between the two clears
# (`bitmap_free_split_hook`); A allocates once more; the begin stop of an
# incremental cycle runs, and one unit of marking; F finishes; the cycle
# finishes. On the control arm (`bitmap_free_claim_guard = false`, the code
# before) A's allocation claims the freed block on the hit path and gets
# it, the begin stop marks it, F's clear unmarks it, and the finishing
# slice leaves it unoccupied under A. On the fixed arm A's hit path finds
# FREEING and takes the locked path, which waits on the class lock until F
# is done (`cursor_free_deferrals` counts it). Each arm runs in a process
# of its own; a child whose heap cannot reach the window (no bitmap
# allocator or hit path, or no page barrier for the incremental cycle —
# Linux only, as regression 85) prints `CLAIM91_SKIP_MARK` and passes.
# `bench/log/linux/2026-11-01-free-mark-clear-claim/FINDINGS.md`.

private CLAIM91_SKIP_MARK    = "claim91: this heap cannot reach the window, skipped"
private CLAIM91_CONTROL_MARK = "claim91: the control arm went wrong"

# A class the spec runner does not allocate from, on the hit path
# (`FAST_PATH_MAX`): the class lock the parked free holds stops nobody else.
private CLAIM91_BYTES = 24576

# Static data is scanned by the begin stop and by no slice after it, so a
# block named only from here is marked once, at the begin stop — the mark
# the free's clear wipes. Pointers between the threads go through here and
# not through closures, whose captures live in a heap object every slice
# can trace.
private class Claim91Roots
  class_property victim : Void* = Pointer(Void).null
  class_property mine : Void* = Pointer(Void).null
  class_property held = [] of Void*
end

class Gcry::Heap
  # This thread's cursor slot of the pointerful class *class_index*: its
  # chunk and the blocks of its claim not handed out yet.
  def claim91_slot(class_index : Int32) : {ChunkHeader*, UInt64}
    set = cursor_set_cached
    return {Pointer(ChunkHeader).null, 0_u64} if set.null?
    s = CursorSet.slot(set, class_index)
    {s.value.chunk, s.value.free_mask}
  end

  # No block of *chunk* left for a cursor to claim.
  def claim91_chunk_full?(chunk : ChunkHeader*) : Bool
    nblocks = chunk_block_count(chunk)
    words = ((nblocks + 63) >> 6).to_i32
    words.times do |w|
      return false if chunk_free_mask(chunk, w, nblocks) != 0_u64
    end
    true
  end

  def claim91_chunk(user : Void*) : ChunkHeader*
    chunk = chunk_for_owned(user) || raise "no chunk for the block"
    bitmap_alloc_chunk?(chunk) || raise "not a bitmap chunk"
    chunk
  end

  # The block's `occ` and `mark` bits.
  def claim91_bits(user : Void*) : {Bool, Bool}
    chunk = claim91_chunk(user)
    ordinal = chunk_block_ordinal(chunk, BlockHeader.from_user(user).address)
    bit = 1_u64 << (ordinal & 63)
    word = ordinal >> 6
    occ = ChunkHeader.occ_bitmap(chunk)
    mark = ChunkHeader.mark_bitmap(chunk)
    {(occ[word] & bit) != 0, (mark[word] & bit) != 0}
  end
end

private def claim91_skip : Nil
  STDOUT.puts CLAIM91_SKIP_MARK
  STDOUT.flush
end

private def claim91_wait(what : String, & : -> Bool) : Nil
  deadline = Time.instant + 10.seconds
  until yield
    fail "timed out waiting for #{what}" if Time.instant >= deadline
    Intrinsics.pause
  end
end

# The heap, ready for the window, or nil when it cannot reach it.
private def claim91_heap : Gcry::Heap?
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    return nil unless heap.bitmap_alloc? && heap.fast_path?
    # The cycle needs a page barrier with the world running between slices;
    # mprotect works on Linux whatever the kernel's soft-dirty does.
    heap.prefer_mprotect_barrier = true
    # No collection but the ones the window asks for: a threshold crossed
    # also closes the hit path the window needs.
    heap.gc_threshold = 1_u64 << 40
    heap
  {% else %}
    nil
  {% end %}
end

# Runs the window. Returns whether A's block is occupied once the cycle has
# finished, and whether one of the class's next allocations handed it out
# a second time.
private def claim91_window(heap : Gcry::Heap, fixed : Bool) : {Bool, Bool}
  class_index = Gcry::SizeClasses.index_of(CLAIM91_BYTES.to_u32)
  GC.collect
  phase = Atomic(Int32).new(0)
  got = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  go = Atomic(Int32).new(0)
  freed = Atomic(Int32).new(0)
  target = Atomic(UInt64).new(0_u64)

  thread_a = Thread.new do
    # Every block but the last stays held, so the chunk has nothing left to
    # claim once the cursor's last word is used up.
    held = Claim91Roots.held
    4096.times do
      u = GC.malloc(CLAIM91_BYTES)
      chunk, mask = heap.claim91_slot(class_index)
      if !chunk.null? && mask == 0_u64 && heap.claim91_chunk(u) == chunk &&
         heap.claim91_chunk_full?(chunk)
        target.set(chunk.address)
        Claim91Roots.victim = u
        break
      end
      held << u
    end
    phase.set(1)
    until phase.get == 2
      Intrinsics.pause
    end
    Claim91Roots.mine = GC.malloc(CLAIM91_BYTES)
    got.set(1)
    until phase.get == 3
      Intrinsics.pause
    end
    nil
  end
  claim91_wait("A to fill its chunk") { phase.get == 1 }
  fail "A never stood on a full chunk" if Claim91Roots.victim.null?

  # On F, under the class lock: allocates nothing.
  heap.bitmap_free_split_hook = ->(c : Gcry::ChunkHeader*) do
    if c.address == target.get && parked.get == 0
      parked.set(1)
      deadline = Time.instant + 10.seconds
      while go.get == 0 && Time.instant < deadline
        Intrinsics.pause
      end
    end
    nil
  end
  thread_f = Thread.new do
    GC.free(Claim91Roots.victim)
    freed.set(1)
  end
  claim91_wait("F to park between its clears") { parked.get == 1 }
  victim = Claim91Roots.victim
  Claim91Roots.victim = Pointer(Void).null

  deferrals = heap.cursor_free_deferrals
  advances = heap.cursor_word_advances
  phase.set(2)
  if fixed
    # A's hit path finds FREEING and goes for the class lock F holds.
    claim91_wait("A's hit path to defer to the free") { heap.cursor_free_deferrals > deferrals }
    got.get.should eq(0)
  else
    claim91_wait("A's allocation") { got.get == 1 }
    # Claimed on the hit path, and the block F is freeing.
    heap.cursor_word_advances.should be > advances
    Claim91Roots.mine.should eq(victim)
  end

  # The begin stop and one unit of marking: the stop marks every block the
  # static data, A's stack and F's stack name.
  heap.collect_a_little(1) && fail "the cycle finished in its first slice"
  unless fixed
    occ, mark = heap.claim91_bits(Claim91Roots.mine)
    fail "A's block is not occupied and marked (occ=#{occ} mark=#{mark})" unless occ && mark
  end
  go.set(1)
  thread_f.join
  freed.get.should eq(1)
  heap.bitmap_free_split_hook = nil
  claim91_wait("A's allocation") { got.get == 1 }
  fail "the cycle ended before F finished" unless heap.incremental_in_progress? || fixed

  10_000.times do
    break if heap.collect_a_little
  end
  fail "the incremental cycle is still open" if heap.incremental_in_progress?

  mine = Claim91Roots.mine
  occupied, _ = heap.claim91_bits(mine)
  # The class's next allocations, held: one is A's block on the control arm
  # when the sweep left it free to claim.
  again = [] of Void*
  twice = false
  64.times do
    u = GC.malloc(CLAIM91_BYTES)
    again << u
    twice = true if u == mine
  end
  phase.set(3)
  thread_a.join
  again.size.should eq(64)
  Claim91Roots.mine = Pointer(Void).null
  {occupied, twice}
end

describe "Regression: a bitmap free's mark clear wipes a concurrent claim's mark" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      env = {"GCRY_CLAIM91_CHILD" => arm} of String => String?
      # The control arm leaves a block handed out and free on purpose.
      env["GCRY_DEBUG_INVARIANTS"] = nil if arm == "control"
      status = Process.run(Process.executable_path.not_nil!,
        ["-e", "claim91 child #{arm}"],
        env: env, output: captured, error: captured)
      text = captured.to_s
      fail "child #{status.inspect}:\n#{text}" unless status.success?
      text.should contain("1 examples, 0 failures")
      if arm == "control" && !text.includes?(CLAIM91_SKIP_MARK)
        text.should contain(CLAIM91_CONTROL_MARK)
      end
    end
  end

  it "claim91 child fixed" do
    next unless ENV["GCRY_CLAIM91_CHILD"]? == "fixed"
    next claim91_skip unless heap = claim91_heap
    occupied, twice = claim91_window(heap, fixed: true)
    occupied.should be_true
    twice.should be_false
  end

  it "claim91 child control" do
    next unless ENV["GCRY_CLAIM91_CHILD"]? == "control"
    next claim91_skip unless heap = claim91_heap
    heap.bitmap_free_claim_guard = false
    occupied, twice = claim91_window(heap, fixed: false)
    occupied.should be_false
    STDOUT.puts "#{CLAIM91_CONTROL_MARK}: A's block free in occ after the cycle, handed out again: #{twice}"
    STDOUT.flush
  end
end
