require "../../src/gcry"
require "spec"

# A sweep inside the stop rebuilt `@chunks` without `@chunk_list_lock` while
# a thread the stop had frozen *inside* that lock was halfway through a
# prepend. `map_chunk` reads the head, then stores `@chunks = new` with
# `new.next` that head; the rebuild reverses the list, so the head it read
# became the tail, and the store it finished after `start_world` left the
# list two chunks long. Everything else stayed in the chunk index and off the
# list: never swept again, its blocks counted live and its free capacity
# counted free for good. `bench/claim_stress.cr` (from the occupancy-claim
# branch) with `GCRY_DISABLE_LAZY_SWEEP=1` and two workers lost 31-252
# chunks in 14 of 40 2-second runs on e8c0327e, every loss after a stop that
# froze a mapper between those two lines. The in-stop sweep now takes the
# lock without waiting, and leaves the list alone when it cannot
# (`Heap#sweep`, `stop_sweep_relinks_declined`).
#
# The interleaving is forced rather than waited for: `chunk_publish_hook`
# parks one thread between the head read and the head store until a stop
# has come and gone, and the main thread collects with the sweep in the
# stop. The control arm (`stop_sweep_list_lock = false`, the code before)
# must lose chunks on the same construction, or the fixed arm passes on
# nothing. Each arm runs in a process of its own: the control arm leaves
# its heap broken.

private FROZEN_MAPPER_SIZE = 1024
# Kept live across the collection, so the list has chunks to lose.
private FROZEN_MAPPER_KEPT = 4096
# The mapping thread's blocks, preallocated: its array never grows.
private FROZEN_MAPPER_ROOM = 1 << 16

# Chunks the index knows and the list does not. The set is sized first: an
# allocation inside either walk could map a chunk one walk has passed.
private def frozen_mapper_unlisted(heap : Gcry::Heap) : Int32
  listed = Set(UInt64).new(initial_capacity: 1 << 16)
  heap.each_chunk { |c| listed << c.address }
  unlisted = 0
  heap.each_indexed_chunk { |c| unlisted += 1 unless listed.includes?(c.address) }
  unlisted
end

# Park a thread inside `map_chunk`, collect, let it finish. Returns the
# number of stops that ended while it was parked.
private def frozen_mapper_window(heap : Gcry::Heap) : Int32
  starts = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  done = Atomic(Int32).new(0)
  stops_seen = Atomic(Int32).new(0)
  target = Atomic(UInt64).new(0_u64)
  heap.post_stw_hook = ->(stage : Symbol) do
    starts.add(1) if stage == :after_start_world
    nil
  end
  # On the mapping thread, under `@chunk_list_lock`: allocates nothing.
  heap.chunk_publish_hook = -> do
    t = Thread.current?
    if t && t.object_id == target.get && parked.get == 0
      entered = starts.get
      parked.set(1)
      deadline = Time.instant + 10.seconds
      while starts.get == entered && Time.instant < deadline
        Intrinsics.pause
      end
      stops_seen.set(starts.get - entered)
      done.set(1)
    end
    nil
  end

  # Room for every block up front: a fresh chunk is what the loop is for.
  kept = Array(Void*).new(FROZEN_MAPPER_ROOM)
  thread = Thread.new do
    target.set(Thread.current.object_id)
    while done.get == 0 && kept.size < FROZEN_MAPPER_ROOM
      kept << GC.malloc_atomic(FROZEN_MAPPER_SIZE)
    end
  end
  deadline = Time.instant + 10.seconds
  until parked.get == 1 || done.get == 1 || Time.instant >= deadline
    sleep 1.millisecond
  end
  fail "the thread never mapped a chunk" unless parked.get == 1
  GC.collect
  thread.join
  heap.chunk_publish_hook = nil
  heap.post_stw_hook = nil
  # Its blocks stay live to the end of the child, in a fresh chunk now on
  # the list or off it.
  kept.size.should be > 0
  stops_seen.get
end

private def frozen_mapper_heap : Gcry::Heap
  heap = Gcry.default_heap
  heap.lazy_sweep = false
  heap
end

private def frozen_mapper_setup(heap : Gcry::Heap) : Array(Void*)
  roots = Array(Void*).new(FROZEN_MAPPER_KEPT) { |i| GC.malloc(16 + (i % 64) * 16) }
  GC.collect
  frozen_mapper_unlisted(heap).should eq(0)
  heap.chunk_back_link_faults.should eq(0)
  roots
end

describe "Regression: an in-stop sweep keeps the chunks a frozen mapper would drop" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      status = Process.run(Process.executable_path.not_nil!, ["-e", "stop-sweep-frozen-mapper child #{arm}"],
        env: {"GCRY_FROZEN_MAPPER_CHILD" => arm}, output: captured, error: captured)
      fail "child #{status.inspect}:\n#{captured}" unless status.success?
      captured.to_s.should contain("1 examples, 0 failures")
    end
  end

  it "stop-sweep-frozen-mapper child fixed" do
    next unless ENV["GCRY_FROZEN_MAPPER_CHILD"]? == "fixed"
    heap = frozen_mapper_heap
    roots = frozen_mapper_setup(heap)
    declined = heap.stop_sweep_relinks_declined
    frozen_mapper_window(heap).should be > 0
    # The sweep saw the lock held and left the list alone.
    (heap.stop_sweep_relinks_declined - declined).should be > 0
    frozen_mapper_unlisted(heap).should eq(0)
    heap.chunk_back_link_faults.should eq(0)
    # And the next stop, with the lock free, relinks as before.
    GC.collect
    frozen_mapper_unlisted(heap).should eq(0)
    heap.chunk_back_link_faults.should eq(0)
    roots.each { |p| heap.live?(p).should be_true }
  end

  it "stop-sweep-frozen-mapper child control" do
    next unless ENV["GCRY_FROZEN_MAPPER_CHILD"]? == "control"
    heap = frozen_mapper_heap
    heap.stop_sweep_list_lock = false
    frozen_mapper_setup(heap)
    frozen_mapper_window(heap).should be > 0
    frozen_mapper_unlisted(heap).should be > 1
  end
end
