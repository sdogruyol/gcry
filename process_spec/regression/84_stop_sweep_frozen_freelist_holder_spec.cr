require "../../src/gcry"
require "spec"

# On the freelist allocator (the header layout with `GCRY_BITMAP_ALLOC=0`,
# and every nursery chunk) the in-stop sweep wrote class freelists without
# the class lock, which it cannot wait on: a thread the stop froze inside a
# pop, a free's push, a batch claim or a refill had a head, a `next_free` or
# a whole chunk in hand and stored it after `start_world`. The sharpest of
# them, and the one forced here, is the header form of regression 80: a
# refill (`refill_size_class`) lays a fresh chunk out as FREE blocks and then
# stores the list head. Frozen between the two, the chunk is all FREE and on
# no list, the sweep finds it empty and makes it dormant, and the refill
# installs its freelist into the dormant chunk and allocates from it: every
# later flush DONTNEEDs the chunk's pages under the objects in it. The stop
# now notes which class locks frozen threads hold and leaves those classes
# alone — their lists unwritten, their freelist chunks unswept
# (`note_frozen_freelists`, `Heap#sweep`, `flush_all_alloc_batches`).
#
# The interleaving is forced: `refill_publish_hook` parks the refilling
# thread between its layout and its head store until a stop has come and
# gone, and the main thread collects with the sweep in the stop and a
# dormant budget. The control arm (`stop_freelist_try_lock = false`, the code
# before) must hand the thread a dormant chunk on the same construction, or
# the fixed arm passes on nothing. Each arm runs in a process of its own. On
# a heap with no freelist chunks (the headerless default) the children skip:
# `make bitmap-marks-freelist` runs this suite on the freelist layout.
# `bench/log/linux/2026-10-22-in-stop-sweep-audit/FINDINGS.md`.

# A class nothing in the spec runner allocates (24 576 B), so the refill of
# its first allocation lays out a chunk of its own.
private FREELIST84_BYTES =                     24576
private FREELIST84_STAMP = 0x7A4E_84C0_FFEE_0084_u64
private FREELIST84_LAST  = FREELIST84_BYTES // 8 - 1

private def freelist84_heap : Gcry::Heap?
  heap = Gcry.default_heap
  # Freelist chunks: the header allocator's, or a nursery's.
  return nil if heap.bitmap_alloc? && !heap.nursery_enabled
  heap.lazy_sweep = false
  heap.empty_chunk_retain = 64_u64 << 20
  heap.empty_chunk_warm_retain = 0_u64
  heap
end

# Park a thread allocating FREELIST84_BYTES between its refill's layout and
# its head store, collect, let it finish. Returns the chunk it laid out, the
# stops that ended while it was parked, and the block it was handed.
private def freelist84_window(heap : Gcry::Heap) : {UInt64, Int32, Void*}
  starts = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  stops_seen = Atomic(Int32).new(0)
  laid_out = Atomic(UInt64).new(0_u64)
  heap.post_stw_hook = ->(stage : Symbol) do
    starts.add(1) if stage == :after_start_world
    nil
  end
  # On the refilling thread, under its class lock: allocates nothing.
  heap.refill_publish_hook = ->(c : Gcry::ChunkHeader*) do
    if c.value.size_class == Gcry::SizeClasses.index_of(FREELIST84_BYTES.to_u32).to_u32 && parked.get == 0
      laid_out.set(c.address)
      entered = starts.get
      parked.set(1)
      deadline = Time.instant + 10.seconds
      while starts.get == entered && Time.instant < deadline
        Intrinsics.pause
      end
      stops_seen.set(starts.get - entered)
    end
    nil
  end

  holder = Array(Void*).new(1, Pointer(Void).null)
  thread = Thread.new do
    p = GC.malloc(FREELIST84_BYTES)
    p.as(UInt64*).value = FREELIST84_STAMP
    p.as(UInt64*)[FREELIST84_LAST] = ~FREELIST84_STAMP
    holder[0] = p
  end
  deadline = Time.instant + 10.seconds
  until parked.get == 1 || !holder[0].null? || Time.instant >= deadline
    sleep 1.millisecond
  end
  fail "the thread never refilled the class under test" unless parked.get == 1
  GC.collect
  thread.join
  heap.refill_publish_hook = nil
  heap.post_stw_hook = nil
  holder[0].null?.should be_false
  {laid_out.get, stops_seen.get, holder[0]}
end

private def freelist84_chunk(heap : Gcry::Heap, address : UInt64) : Gcry::ChunkHeader*
  found = Pointer(Gcry::ChunkHeader).null
  heap.each_indexed_chunk { |c| found = c if c.address == address }
  found.null? && raise "chunk 0x#{address.to_s(16)} is not indexed"
  found
end

class Gcry::Heap
  # Is *user* on the class's old-generation freelist? Walks it, bounded.
  def freelist84_listed?(class_index : Int32, user : Void*) : Bool
    u = @freelists[class_index]
    steps = 0
    while !u.null? && steps < (1 << 20)
      return true if u == user
      u = BlockHeader.from_user(u).value.next_free
      steps += 1
    end
    false
  end

  # This thread's stash of the class, head first, bounded.
  def freelist84_my_stash(class_index : Int32) : Array(Void*)
    out = [] of Void*
    u = current_alloc_batch.value.freelists[class_index]
    while !u.null? && out.size < 4096
      out << u
      u = BlockHeader.from_user(u).value.next_free
    end
    out
  end
end

# The allocation-batch path (`GCRY_ALLOC_BATCH`, old generation only): a
# thread keeps a stash of USED blocks linked through their headers. Two
# frozen states, each forced by a hook that parks the thread until a stop has
# come and gone:
#
# - *pop*: inside `alloc_old_small_batched`, under the batch slot lock, with
#   the stash head read and its `next_free` not yet stored. The stop flushed
#   the stash onto the class list as FREE blocks, head included, and the
#   thread then took the head anyway: a block handed out and on the class
#   list, for the next allocation of the class to hand out again.
# - *publish*: `refill_alloc_batch` publishing a stash it has claimed. After
#   the class lock was released and before the slot took the stash, the
#   stash was in no slot and the sweep reclaimed it under the thread, which
#   then made those blocks its stash: blocks in a stash and on the class
#   list at once. (The scan may find a few stash blocks in stale stack
#   slots; a batch of 32 leaves most of them to be reclaimed.)
#
# Returns the stops that ended while the thread was parked and whether a
# block the thread holds — handed out, or in its stash — is on the class
# list as well.
private def freelist84_batch_window(heap : Gcry::Heap, publish : Bool) : {Int32, Bool}
  class_index = Gcry::SizeClasses.index_of(FREELIST84_BYTES.to_u32)
  starts = Atomic(Int32).new(0)
  armed = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  stops_seen = Atomic(Int32).new(0)
  heap.post_stw_hook = ->(stage : Symbol) do
    starts.add(1) if stage == :after_start_world
    nil
  end
  # On the allocating thread, under the slot or class lock: allocates nothing.
  park = ->(_u : Void*) do
    if armed.get == 1 && parked.get == 0
      entered = starts.get
      parked.set(1)
      deadline = Time.instant + 10.seconds
      while starts.get == entered && Time.instant < deadline
        Intrinsics.pause
      end
      stops_seen.set(starts.get - entered)
    end
    nil
  end
  if publish
    heap.alloc_batch_publish_hook = park
  else
    heap.alloc_batch_pop_hook = park
  end

  held = [] of Void*
  thread = Thread.new do
    # *publish*: the first allocation's refill claims a batch and publishes
    # it. *pop*: the second allocation pops the stash the first published.
    armed.set(1) if publish
    first = GC.malloc(FREELIST84_BYTES)
    armed.set(1)
    second = GC.malloc(FREELIST84_BYTES)
    held.concat(heap.freelist84_my_stash(class_index))
    held << first << second
  end
  deadline = Time.instant + 10.seconds
  until parked.get == 1 || Time.instant >= deadline
    sleep 1.millisecond
  end
  fail "the thread never reached the batch window" unless parked.get == 1
  GC.collect
  thread.join
  heap.alloc_batch_pop_hook = nil
  heap.alloc_batch_publish_hook = nil
  heap.post_stw_hook = nil
  {stops_seen.get, held.any? { |p| heap.freelist84_listed?(class_index, p) }}
end

private def freelist84_batch_heap : Gcry::Heap?
  heap = freelist84_heap
  # The batched pop is the old-generation freelist's (`alloc_old_small`).
  return nil if heap.nil? || heap.bitmap_alloc? || heap.nursery_enabled
  heap.alloc_batch = 32
  heap
end

# The batch windows with the sweep after the world, where a multi-mutator
# heap with TLAB off sweeps by default. The after-world sweep takes each
# chunk's class lock, which covers a thread inside it but not the stash it
# leaves: a stash the flush kept (*pop*) or one published after the stop
# (*publish*) is USED and unmarked, so the sweep put its blocks on the class
# list. The stop now sweeps in the stop instead when it found a frozen class
# (`sweep_frozen_classes_in_stop?`). Two idle threads keep the heap
# multi-mutator, as the reviewer's case is.
private def freelist84_lazy_window(heap : Gcry::Heap, publish : Bool) : {Int32, Bool}
  heap.lazy_sweep = true
  stop = Atomic(Int32).new(0)
  idlers = Array(Thread).new(2) do
    Thread.new do
      # A bare thread has no event loop to `sleep` on.
      until stop.get == 1
        Intrinsics.pause
        Thread.yield
      end
    end
  end
  begin
    freelist84_batch_window(heap, publish)
  ensure
    stop.set(1)
    idlers.each(&.join)
  end
end

# A batch refill publishes its stash into its slot under the class lock
# (class → batch slot); a page release takes every slot and the class lock
# (`with_small_allocation_excluded`). With the batch slots first there, a
# refill parked under the class lock before its slot and a release that has
# taken the slots wait on each other for good. Returns whether both
# finished within five seconds.
private def freelist84_exclusion_window(heap : Gcry::Heap) : Bool
  class_index = Gcry::SizeClasses.index_of(FREELIST84_BYTES.to_u32)
  parked = Atomic(Int32).new(0)
  go = Atomic(Int32).new(0)
  done = Atomic(Int32).new(0)
  # On the refilling thread, under the class lock, before its slot lock:
  # allocates nothing.
  # Only the class under test: every other thread's batch refills (the
  # main thread's `Thread.new` among them) pass straight through.
  heap.alloc_batch_publish_hook = ->(u : Void*) do
    if parked.get == 0 && Gcry::BlockHeader.from_user(u).value.size == FREELIST84_BYTES
      parked.set(1)
      until go.get == 1
        Intrinsics.pause
      end
    end
    nil
  end
  refiller = Thread.new do
    GC.malloc(FREELIST84_BYTES)
    done.add(1)
  end
  deadline = Time.instant + 10.seconds
  until parked.get == 1 || Time.instant >= deadline
    sleep 1.millisecond
  end
  fail "the refill never reached its publish" unless parked.get == 1
  releaser = Thread.new do
    heap.exclude_small_allocation_for_spec(class_index)
    done.add(1)
  end
  # Long enough for the releaser to take every lock it can and wait.
  sleep 200.milliseconds
  go.set(1)
  deadline = Time.instant + 5.seconds
  until done.get == 2 || Time.instant >= deadline
    sleep 1.millisecond
  end
  return false unless done.get == 2
  refiller.join
  releaser.join
  heap.alloc_batch_publish_hook = nil
  true
end

describe "Regression: an in-stop sweep writes no freelist a frozen thread is inside" do
  {"refill", "pop", "publish", "pop-lazy", "publish-lazy", "exclusion"}.each do |window|
    {"fixed", "control"}.each do |arm|
      it "#{window} #{arm} arm in a process of its own" do
        captured = IO::Memory.new
        # The control arms hand blocks out wrongly on purpose.
        env = {"GCRY_FROZEN_FREELIST_CHILD" => "#{window}-#{arm}"} of String => String?
        env["GCRY_DEBUG_INVARIANTS"] = nil if arm == "control"
        status = Process.run(Process.executable_path.not_nil!,
          ["-e", "stop-sweep-frozen-freelist-holder child #{window} #{arm}"],
          env: env, output: captured, error: captured)
        fail "child #{status.inspect}:\n#{captured}" unless status.success?
        if window == "exclusion" && arm == "control"
          # Or skipped: no batch path on this heap.
          text = captured.to_s
          text.should match(/freelist84: the release and the refill deadlocked|1 examples, 0 failures/)
        else
          captured.to_s.should contain("1 examples, 0 failures")
        end
      end
    end
  end

  it "stop-sweep-frozen-freelist-holder child refill fixed" do
    next unless ENV["GCRY_FROZEN_FREELIST_CHILD"]? == "refill-fixed"
    next unless heap = freelist84_heap
    declined = heap.stop_sweep_freelist_declined
    address, stops, p = freelist84_window(heap)
    stops.should be > 0
    chunk = freelist84_chunk(heap, address)
    # The stop left the class alone: the chunk it found all FREE is awake,
    # and the thread's block is in it.
    (heap.stop_sweep_freelist_declined - declined).should be > 0
    heap.chunk_address_of(p).should eq(address)
    Gcry::ChunkHeader.dormant?(chunk).should be_false
    # A dormant chunk's pages go back at every flush; this one's do not.
    GC.collect
    Gcry::ChunkHeader.dormant?(chunk).should be_false
    heap.live?(p).should be_true
    p.as(UInt64*).value.should eq(FREELIST84_STAMP)
    p.as(UInt64*)[FREELIST84_LAST].should eq(~FREELIST84_STAMP)
  end

  it "stop-sweep-frozen-freelist-holder child refill control" do
    next unless ENV["GCRY_FROZEN_FREELIST_CHILD"]? == "refill-control"
    next unless heap = freelist84_heap
    heap.stop_freelist_try_lock = false
    address, stops, p = freelist84_window(heap)
    stops.should be > 0
    chunk = freelist84_chunk(heap, address)
    # The thread allocated out of the chunk the stop made dormant.
    heap.chunk_address_of(p).should eq(address)
    Gcry::ChunkHeader.dormant?(chunk).should be_true
  end

  {"pop", "publish"}.each do |window|
    it "stop-sweep-frozen-freelist-holder child #{window} fixed" do
      next unless ENV["GCRY_FROZEN_FREELIST_CHILD"]? == "#{window}-fixed"
      next unless heap = freelist84_batch_heap
      stops, shared = freelist84_batch_window(heap, window == "publish")
      stops.should be > 0
      shared.should be_false
    end

    it "stop-sweep-frozen-freelist-holder child #{window} control" do
      next unless ENV["GCRY_FROZEN_FREELIST_CHILD"]? == "#{window}-control"
      next unless heap = freelist84_batch_heap
      if window == "publish"
        heap.alloc_batch_publish_locked = false
      else
        heap.stop_freelist_try_lock = false
      end
      stops, shared = freelist84_batch_window(heap, window == "publish")
      stops.should be > 0
      shared.should be_true
    end

    it "stop-sweep-frozen-freelist-holder child #{window}-lazy fixed" do
      next unless ENV["GCRY_FROZEN_FREELIST_CHILD"]? == "#{window}-lazy-fixed"
      next unless heap = freelist84_batch_heap
      in_stop = heap.stop_frozen_sweeps_in_stop
      stops, shared = freelist84_lazy_window(heap, window == "publish")
      stops.should be > 0
      # Swept in the stop because of the frozen class, not by luck.
      (heap.stop_frozen_sweeps_in_stop - in_stop).should be > 0
      shared.should be_false
    end

    it "stop-sweep-frozen-freelist-holder child #{window}-lazy control" do
      next unless ENV["GCRY_FROZEN_FREELIST_CHILD"]? == "#{window}-lazy-control"
      next unless heap = freelist84_batch_heap
      heap.stop_frozen_sweep_in_stop = false
      stops, shared = freelist84_lazy_window(heap, window == "publish")
      stops.should be > 0
      shared.should be_true
    end
  end

  it "stop-sweep-frozen-freelist-holder child exclusion fixed" do
    next unless ENV["GCRY_FROZEN_FREELIST_CHILD"]? == "exclusion-fixed"
    next unless heap = freelist84_batch_heap
    freelist84_exclusion_window(heap).should be_true
  end

  it "stop-sweep-frozen-freelist-holder child exclusion control" do
    next unless ENV["GCRY_FROZEN_FREELIST_CHILD"]? == "exclusion-control"
    next unless heap = freelist84_batch_heap
    heap.small_exclusion_batch_first = true
    finished = freelist84_exclusion_window(heap)
    finished.should be_false
    STDOUT.puts "freelist84: the release and the refill deadlocked"
    STDOUT.flush
    # Two threads spin on each other's locks for good.
    LibC._exit(0)
  end
end
