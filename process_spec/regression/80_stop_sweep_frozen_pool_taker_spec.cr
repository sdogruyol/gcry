require "../../src/gcry"
require "spec"

# A cursor takes a chunk from its class's pool in one hold of
# `@chunk_list_lock`: `bitmap_pool_candidate?` finds the chunk free to take
# (not dormant, no cursor on it, a free block), then CURSOR is set. Between
# the two the chunk is nobody's, and an in-stop sweep that froze the taker
# there found it empty and made it dormant. The taker resumed, set CURSOR and
# allocated into it — a cursor's chunk and a dormant one at once. The walks
# count a dormant chunk all free and the counters held its blocks, which is
# how `bench/claim_stress.cr` with `GCRY_DISABLE_LAZY_SWEEP=1` first showed
# it (live -1632, a class-4 chunk's every block, 1 run in 100). Worse, every
# later flush DONTNEEDs a dormant chunk's pages, so the objects in it read
# zero (stamps zeroed, 1 run in 112), sweeps skip it, and a revive zeroes its
# `occ` and hands its blocks out again. The in-stop sweep now makes no chunk
# dormant while a frozen thread holds the list lock (`Heap#sweep`,
# `stop_sweep_dormant_declined`), as it already relinks nothing then
# (process_spec/regression/75).
#
# The interleaving is forced: `pool_take_hook` parks the taking thread
# between its check and its take until a stop has come and gone, and the
# main thread collects with the sweep in the stop. The chunk under test is
# emptied by explicit frees before the take, so the stop finds it empty
# whatever the conservative scan sees. The control arm
# (`stop_sweep_dormant_lock = false`, the code before) must hand the taker a
# dormant chunk on the same construction, or the fixed arm passes on
# nothing. Each arm runs in a process of its own: the control arm leaves its
# heap broken.

class Gcry::Heap
  def taker80_chunk(user : Void*) : Gcry::ChunkHeader*
    chunk_containing(user.address) || raise "#{user} is not in the heap"
  end
end

# A class nothing in the spec runner allocates (24 576 B, five blocks to a
# 128 KiB chunk), so the chunk under test is this example's alone and the
# only one its pool offers.
private TAKER80_BYTES  =                     24576
private TAKER80_BLOCKS =                         3
private TAKER80_STAMP  = 0x7A4E_80C0_FFEE_0080_u64
# The block's last word as well as its first: block 0 starts in the chunk's
# page 0, which no release reaches (`chunk_layout.cr`); it ends pages later.
private TAKER80_LAST         = TAKER80_BYTES // 8 - 1
private TAKER80_CONTROL_MARK = "taker80: the stop made the chunk dormant under its parked taker"

private def taker80_heap : Gcry::Heap
  heap = Gcry.default_heap
  heap.lazy_sweep = false
  # A budget for dormant empties, so that the stop's sweep makes empty
  # chunks dormant however many threads it counts: the Linux process
  # default is 0, and a multi-mutator `GC.collect` makes them dormant
  # anyway (`claim_stress`), a single-mutator one unmaps them.
  heap.empty_chunk_retain = 64_u64 << 20
  heap
end

# Lay out the chunk: blocks in a fresh chunk, kept across a collection that
# retires this thread's cursor off it, then freed. Returns the chunk, empty,
# not dormant and no cursor's.
private def taker80_empty_chunk(heap : Gcry::Heap) : Gcry::ChunkHeader*
  blocks = Array(Void*).new(TAKER80_BLOCKS) { GC.malloc(TAKER80_BYTES) }
  chunk = heap.taker80_chunk(blocks[0])
  blocks.each { |p| heap.taker80_chunk(p).should eq(chunk) }
  GC.collect
  Gcry::ChunkHeader.cursor?(chunk).should be_false
  heap.chunk_occupied_count(chunk).should eq(TAKER80_BLOCKS)
  blocks.each { |p| GC.free(p) }
  heap.chunk_occupied_count(chunk).should eq(0)
  Gcry::ChunkHeader.dormant?(chunk).should be_false
  chunk
end

# Walk minus counter, read until two readings agree (a runtime thread may be
# allocating), as `bench/claim_stress.cr` reads it.
private def taker80_drift(& : -> Int64?) : Int64?
  last = nil
  100.times do
    d = yield
    return d if d && d == last
    last = d
    sleep 10.milliseconds
  end
  last
end

# Park a thread allocating TAKER80_BYTES between its check of *chunk* and
# its take, collect, call *before_release* while it is still parked (the
# collection, its flush included, has returned), then let it finish. Returns
# the stops that ended while it was parked and the block it was handed.
private def taker80_window(heap : Gcry::Heap, chunk : Gcry::ChunkHeader*, &before_release : -> Nil) : {Int32, Void*}
  starts = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  stops_seen = Atomic(Int32).new(0)
  release = Atomic(Int32).new(0)
  target = chunk.address
  heap.post_stw_hook = ->(stage : Symbol) do
    starts.add(1) if stage == :after_start_world
    nil
  end
  # On the taking thread, under its class lock and `@chunk_list_lock`:
  # allocates nothing.
  heap.pool_take_hook = ->(c : Gcry::ChunkHeader*) do
    if c.address == target && parked.get == 0
      entered = starts.get
      parked.set(1)
      deadline = Time.instant + 10.seconds
      while starts.get == entered && Time.instant < deadline
        Intrinsics.pause
      end
      stops_seen.set(starts.get - entered)
      # Held past the stop until the main thread has looked at the chunk:
      # what the stop left is read before the taker writes into it.
      while release.get == 0 && Time.instant < deadline + 10.seconds
        Intrinsics.pause
      end
    end
    nil
  end

  holder = Array(Void*).new(1, Pointer(Void).null)
  thread = Thread.new do
    p = GC.malloc(TAKER80_BYTES)
    p.as(UInt64*).value = TAKER80_STAMP
    p.as(UInt64*)[TAKER80_LAST] = ~TAKER80_STAMP
    holder[0] = p
  end
  deadline = Time.instant + 10.seconds
  until parked.get == 1 || !holder[0].null? || Time.instant >= deadline
    sleep 1.millisecond
  end
  fail "the thread never took the chunk under test" unless parked.get == 1
  GC.collect
  before_release.call
  release.set(1)
  thread.join
  heap.pool_take_hook = nil
  heap.post_stw_hook = nil
  holder[0].null?.should be_false
  {stops_seen.get, holder[0]}
end

describe "Regression: an in-stop sweep makes no chunk dormant under a frozen pool taker" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      # The control arm hands a cursor a dormant chunk on purpose, so its
      # counters drift and the checker would rightly abort the child.
      env = {"GCRY_FROZEN_TAKER_CHILD" => arm} of String => String?
      env["GCRY_DEBUG_INVARIANTS"] = nil if arm == "control"
      status = Process.run(Process.executable_path.not_nil!, ["-e", "stop-sweep-frozen-pool-taker child #{arm}"],
        env: env, output: captured, error: captured)
      # Both children release their taker only after the collection, its
      # dormant flush included, has returned. That matters on Windows, where
      # the flush decommits a dormant chunk's pages and recommits them at once
      # (`Platform.release_physical_pages`): a control-arm taker that wrote
      # between the two died with an access violation in `clear_block` (CI run
      # 39681882864). After the flush the pages are committed and zero again,
      # as on Linux, and the control child's assertions hold on every platform.
      fail "child #{status.inspect}:\n#{captured}" unless status.success?
      captured.to_s.should contain("1 examples, 0 failures")
    end
  end

  it "stop-sweep-frozen-pool-taker child fixed" do
    next unless ENV["GCRY_FROZEN_TAKER_CHILD"]? == "fixed"
    heap = taker80_heap
    next unless heap.bitmap_alloc?
    chunk = taker80_empty_chunk(heap)
    relinks = heap.stop_sweep_relinks_declined
    declined = heap.stop_sweep_dormant_declined
    stops, p = taker80_window(heap, chunk) do
      # The stop and its flush are over and the taker has not taken yet.
      Gcry::ChunkHeader.dormant?(chunk).should be_false
    end
    stops.should be > 0
    # The stop found the list lock held: the taker was inside it.
    (heap.stop_sweep_relinks_declined - relinks).should be > 0
    # The taker got the chunk it checked, and the chunk is awake.
    heap.taker80_chunk(p).should eq(chunk)
    Gcry::ChunkHeader.dormant?(chunk).should be_false
    heap.chunk_occupied_count(chunk).should eq(1)
    taker80_drift { Gcry::Invariant.live_objects_drift(heap) }.should eq(0)
    taker80_drift { Gcry::Invariant.free_bytes_drift(heap) }.should eq(0)
    # Kept out of dormancy by the decline, not by luck.
    (heap.stop_sweep_dormant_declined - declined).should be > 0
    # A dormant chunk's pages go back at every flush; this one's do not.
    GC.collect
    Gcry::ChunkHeader.dormant?(chunk).should be_false
    heap.live?(p).should be_true
    p.as(UInt64*).value.should eq(TAKER80_STAMP)
    p.as(UInt64*)[TAKER80_LAST].should eq(~TAKER80_STAMP)
    taker80_drift { Gcry::Invariant.live_objects_drift(heap) }.should eq(0)
    taker80_drift { Gcry::Invariant.free_bytes_drift(heap) }.should eq(0)
  end

  it "stop-sweep-frozen-pool-taker child control" do
    next unless ENV["GCRY_FROZEN_TAKER_CHILD"]? == "control"
    heap = taker80_heap
    next unless heap.bitmap_alloc?
    heap.stop_sweep_dormant_lock = false
    chunk = taker80_empty_chunk(heap)
    stops, p = taker80_window(heap, chunk) do
      # The old code: the stop made the chunk dormant while its taker was
      # parked between check and take, and the flush has released its pages.
      Gcry::ChunkHeader.dormant?(chunk).should be_true
      Gcry::ChunkHeader.cursor?(chunk).should be_false
      STDOUT.puts TAKER80_CONTROL_MARK
      STDOUT.flush
    end
    stops.should be > 0
    # The taker allocated into the chunk the stop made dormant: a cursor's
    # and dormant at once, its block in the counters and out of the walk.
    heap.taker80_chunk(p).should eq(chunk)
    Gcry::ChunkHeader.dormant?(chunk).should be_true
    Gcry::ChunkHeader.cursor?(chunk).should be_true
    taker80_drift { Gcry::Invariant.live_objects_drift(heap) }.should eq(-1)
  end
end
