require "../../src/gcry"
require "spec"

# Three byte counters are written by threads under different locks (or none)
# and by the stop: `@heap_size` (`map_chunk` with no lock, the large paths
# under `@alloc_lock`; the in-stop sweep's unmap), `@dormant_chunk_bytes`
# (revivals under a class lock; the major sweep, which used to zero it and
# recount the dormant chunks it walked) and `@expl_freed_bytes_since_gc`
# (`GC.free` with no lock; zeroed in the stop at every major). Each write was
# a plain load and store. A stop suspends by signal, so it can freeze a
# thread between the two; the stop writes the counter, and the thread,
# resumed, stores what it computed from the value before the stop. The
# stop's write is lost for good: `heap_size` stays high by every chunk the
# stop unmapped, `dormant_chunk_bytes` low by every chunk it made dormant (at
# zero the flush skips the release of their pages), and
# `expl_freed_bytes_since_gc` keeps the bytes of the cycle before. Now every
# write is an atomic add or a compare-and-set, and `@dormant_chunk_bytes` is
# kept by the dormancy transitions alone: the recount also lost a revival
# frozen between its flag store and its subtraction, atomic or not
# (`Heap#def_shared_counter`).
#
# The interleaving is forced. `shared_counter_hook` runs between the load and
# the store of each of those writes; on the thread under test it parks there
# until the main thread has collected and the world has restarted. The
# collection writes the counter: it unmaps an empty chunk, makes one dormant,
# or zeroes the explicit-free bytes. Then the counter is read against a walk
# of the chunks (`Invariant.heap_size_drift`, `Invariant.dormant_bytes_drift`)
# or against the one free made after the reset. The control arm
# (`shared_counters_atomic = false`, the code before) must lose the stop's
# write on the same construction, or the fixed arm passes on nothing. Each
# arm runs in a process of its own.
# `bench/log/linux/2026-10-23-frozen-counter-rmw/FINDINGS.md`.

# Five blocks to a chunk, in a class nothing in the spec runner allocates.
private C88_CHUNK_CLASS = 24576
# Another such class, for the chunk the stop makes dormant beside the revival.
private C88_SECOND_CLASS = 20480
# A large allocation of a size nothing else asks for, so it maps a chunk.
private C88_LARGE_BYTES = 3 * 1024 * 1024 + 4096
private C88_FREE_BYTES  = 4096
private C88_COUNTERS    = {"heap_size", "dormant", "expl_freed"}

private def c88_heap(arm : String) : Gcry::Heap
  heap = Gcry.default_heap
  # The sweep in the stop, whatever the thread count, and empty chunks
  # released (heap_size) or made dormant (dormant) rather than kept warm.
  heap.lazy_sweep = false
  heap.release_empty_chunks = true
  heap.empty_chunk_warm_retain = 0_u64
  heap.shared_counters_atomic = arm == "fixed"
  heap
end

# Read until two readings agree (a runtime thread may be allocating), as
# `bench/claim_stress.cr` reads its drifts.
private def c88_stable(& : -> Int64?) : Int64?
  last = nil
  100.times do
    d = yield
    return d if d && d == last
    last = d
    sleep 10.milliseconds
  end
  last
end

# Allocates `bytes` blocks well past one chunk and frees the blocks of the
# first: an empty chunk that is no cursor's, for the next major to release or
# make dormant. Returns the chunk and the blocks kept live.
private def c88_empty_chunk(heap : Gcry::Heap, bytes : Int32) : {UInt64, Array(Void*)}
  blocks = Array(Void*).new(16) { GC.malloc(bytes) }
  target = heap.chunk_address_of(blocks[0])
  kept = [] of Void*
  blocks.each_with_index do |p, i|
    if heap.chunk_address_of(p) == target
      GC.free(p)
      blocks[i] = Pointer(Void).null
    else
      kept << p
    end
  end
  {target, kept}
end

# The mapped bytes of the chunk at *address* if it is dormant, else 0.
private def c88_dormant_bytes(heap : Gcry::Heap, address : UInt64) : UInt64
  bytes = 0_u64
  heap.each_chunk { |c| bytes = c.value.mapped_bytes if c.address == address && Gcry::ChunkHeader.dormant?(c) }
  bytes
end

# Runs *action* on a thread of its own; the first write of counter *name* it
# makes parks in `shared_counter_hook` between its load and its store. The
# main thread collects while it is parked, and the thread goes on once the
# world has restarted (`post_stw_hook` `:after_start_world`, before the
# flushes, which may want a lock it holds). Returns whether the stop ended
# while it was parked.
private def c88_window(heap : Gcry::Heap, name : Symbol, &action : Atomic(Int32) ->) : Bool
  starts = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  stopped_while_parked = Atomic(Int32).new(0)
  armed = Atomic(UInt64).new(0_u64)
  heap.post_stw_hook = ->(stage : Symbol) do
    starts.add(1) if stage == :after_start_world
    nil
  end
  # Called with whatever lock the write holds, by every thread including
  # the collector's sweep: parks only the armed thread, and allocates
  # nothing.
  heap.shared_counter_hook = ->(which : Symbol) do
    id = armed.get
    if which == name && parked.get == 0 && id != 0 && Thread.current.object_id == id
      entered = starts.get
      parked.set(1)
      deadline = Time.instant + 10.seconds
      while starts.get == entered && Time.instant < deadline
        Intrinsics.pause
      end
      stopped_while_parked.set(1) if starts.get != entered
    end
    nil
  end

  thread = Thread.new do
    # Armed only now: the thread's own start-up writes nothing under test.
    armed.set(Thread.current.object_id)
    action.call(parked)
  end
  deadline = Time.instant + 10.seconds
  until parked.get == 1 || Time.instant >= deadline
    sleep 1.millisecond
  end
  fail "the thread never reached the #{name} write" unless parked.get == 1
  GC.collect
  thread.join
  heap.shared_counter_hook = nil
  heap.post_stw_hook = nil
  stopped_while_parked.get == 1
end

# `heap_size`: the thread maps a large chunk (`map_chunk`'s add, under
# `@alloc_lock`); the stop unmaps an empty size-class chunk (the sweep's
# subtraction). Returns the walk-minus-counter drift and the bytes the stop
# unmapped.
private def c88_heap_size(heap : Gcry::Heap) : {Bool, Int64?, UInt64}
  heap.parallel_empty_chunk_munmap = true
  heap.empty_chunk_retain = 0_u64
  _, kept = c88_empty_chunk(heap, C88_CHUNK_CLASS)
  c88_stable { Gcry::Invariant.heap_size_drift(heap) }.should eq(0)
  large = Atomic(UInt64).new(0_u64)
  stopped = c88_window(heap, :heap_size) do |_|
    large.set(GC.malloc(C88_LARGE_BYTES).address)
  end
  released = heap.released_chunk_bytes
  drift = c88_stable { Gcry::Invariant.heap_size_drift(heap) }
  kept.size.should be > 0
  large.get.should_not eq(0)
  {stopped, drift, released}
end

# `dormant_chunk_bytes`: one chunk made dormant by a first major, which the
# thread then revives (the subtraction, under its class lock); a second
# empty chunk, of another class, made dormant by the stop the thread is
# parked across. Returns the drift and the bytes the stop made dormant.
private def c88_dormant(heap : Gcry::Heap) : {Bool, Int64?, UInt64}
  heap.parallel_empty_chunk_dormant = true
  heap.empty_chunk_retain = 64_u64 << 20
  revived, kept = c88_empty_chunk(heap, C88_CHUNK_CLASS)
  GC.collect
  (c88_dormant_bytes(heap, revived) > 0).should be_true
  c88_stable { Gcry::Invariant.dormant_bytes_drift(heap) }.should eq(0)
  second, kept2 = c88_empty_chunk(heap, C88_SECOND_CLASS)
  taken = [] of Void*
  stopped = c88_window(heap, :dormant_bytes) do |parked|
    # The class's other chunks are full or another thread's cursor, so a
    # refill revives the dormant one within a few allocations.
    16.times do
      break if parked.get == 1
      taken << GC.malloc(C88_CHUNK_CLASS)
    end
  end
  made_dormant = c88_dormant_bytes(heap, second)
  c88_dormant_bytes(heap, revived).should eq(0)
  drift = c88_stable { Gcry::Invariant.dormant_bytes_drift(heap) }
  (kept.size + kept2.size + taken.size).should be > 0
  {stopped, drift, made_dormant}
end

# `expl_freed_bytes_since_gc`: frees counted before the collection, then
# the thread's `GC.free` parked across the stop that zeroes the counter.
# Returns the counter, which must hold the parked free and nothing older.
private def c88_expl_freed(heap : Gcry::Heap) : {Bool, UInt64, UInt64}
  before = Array(Void*).new(8) { GC.malloc(C88_FREE_BYTES) }
  victim = GC.malloc(C88_FREE_BYTES)
  probe = GC.malloc(C88_FREE_BYTES)
  start = heap.expl_freed_bytes_since_gc
  GC.free(probe)
  payload = heap.expl_freed_bytes_since_gc &- start
  before.each { |p| GC.free(p) }
  stale = heap.expl_freed_bytes_since_gc
  stale.should be > payload
  stopped = c88_window(heap, :expl_freed) do |_|
    GC.free(victim)
  end
  {stopped, heap.expl_freed_bytes_since_gc, payload}
end

private def c88_invariants(heap : Gcry::Heap) : Nil
  c88_stable { Gcry::Invariant.live_objects_drift(heap) }.should eq(0)
  c88_stable { Gcry::Invariant.free_bytes_drift(heap) }.should eq(0)
end

describe "Regression: a thread frozen inside a counter's read-modify-write loses none of the stop's writes" do
  C88_COUNTERS.each do |counter|
    {"fixed", "control"}.each do |arm|
      it "#{counter} #{arm} arm in a process of its own" do
        captured = IO::Memory.new
        env = {"GCRY_FROZEN_COUNTER_CHILD" => "#{counter}-#{arm}"} of String => String?
        status = Process.run(Process.executable_path.not_nil!, ["-e", "frozen-counter child #{counter} #{arm}"],
          env: env, output: captured, error: captured)
        fail "child #{status.inspect}:\n#{captured}" unless status.success?
        if arm == "control"
          captured.to_s.should contain("counter88: control lost the stop's #{counter} write")
        else
          captured.to_s.should contain("1 examples, 0 failures")
        end
      end
    end
  end

  it "frozen-counter child heap_size fixed" do
    next unless ENV["GCRY_FROZEN_COUNTER_CHILD"]? == "heap_size-fixed"
    heap = c88_heap("fixed")
    stopped, drift, released = c88_heap_size(heap)
    stopped.should be_true
    # The stop unmapped a chunk, and the counter kept it out.
    released.should be > 0
    drift.should eq(0)
    c88_invariants(heap)
  end

  it "frozen-counter child heap_size control" do
    next unless ENV["GCRY_FROZEN_COUNTER_CHILD"]? == "heap_size-control"
    heap = c88_heap("control")
    stopped, drift, released = c88_heap_size(heap)
    stopped.should be_true
    released.should be > 0
    # High by exactly the chunk the stop unmapped.
    drift.should eq(-released.to_i64)
    STDOUT.puts "counter88: control lost the stop's heap_size write (drift=#{drift}, unmapped=#{released})"
    STDOUT.flush
  end

  it "frozen-counter child dormant fixed" do
    next unless ENV["GCRY_FROZEN_COUNTER_CHILD"]? == "dormant-fixed"
    heap = c88_heap("fixed")
    stopped, drift, made_dormant = c88_dormant(heap)
    stopped.should be_true
    made_dormant.should be > 0
    drift.should eq(0)
    c88_invariants(heap)
  end

  it "frozen-counter child dormant control" do
    next unless ENV["GCRY_FROZEN_COUNTER_CHILD"]? == "dormant-control"
    heap = c88_heap("control")
    stopped, drift, _ = c88_dormant(heap)
    stopped.should be_true
    # Low by the chunk the stop made dormant: the revival's stale store
    # zeroed the counter while that chunk stayed dormant.
    drift.should_not be_nil
    drift.not_nil!.should be > 0
    STDOUT.puts "counter88: control lost the stop's dormant write (drift=#{drift}, counter=#{heap.dormant_chunk_bytes})"
    STDOUT.flush
  end

  it "frozen-counter child expl_freed fixed" do
    next unless ENV["GCRY_FROZEN_COUNTER_CHILD"]? == "expl_freed-fixed"
    heap = c88_heap("fixed")
    stopped, counter, payload = c88_expl_freed(heap)
    stopped.should be_true
    # The stop's zero, then the parked free.
    counter.should eq(payload)
    c88_invariants(heap)
  end

  it "frozen-counter child expl_freed control" do
    next unless ENV["GCRY_FROZEN_COUNTER_CHILD"]? == "expl_freed-control"
    heap = c88_heap("control")
    stopped, counter, payload = c88_expl_freed(heap)
    stopped.should be_true
    # The cycle before's frees came back over the stop's zero.
    counter.should be > payload
    STDOUT.puts "counter88: control lost the stop's expl_freed write (counter=#{counter}, parked free=#{payload})"
    STDOUT.flush
  end
end
