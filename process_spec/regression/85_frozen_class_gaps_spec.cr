require "../../src/gcry"
require "spec"

# Three gaps regression 84 left, each a stop writing state a thread is
# halfway through, or a stop not writing state it had to:
#
# - *tlab-flush* (`GCRY_TLAB=1`, freelist allocator). `flush_all_tlabs` and
#   `scrub_freelists` wrote every class list in the stop, including one a
#   thread the stop froze inside its class lock had the head of in hand. The
#   thread stored that head when it resumed, and the TLAB chains the flush had
#   spliced in front of it went off every list and out of every TLAB: FREE
#   blocks nothing hands out. A frozen class's chains now stay in their TLAB
#   (`flush_all_tlabs`, `note_frozen_freelists`).
# - *slice-stash* and *slice-tlab* (`GCRY_INCREMENTAL=1`, freelist
#   allocator). No stop of an incremental cycle flushed allocation-batch
#   stashes or TLABs, and the finishing slice sweeps inside its stop. A stash
#   claimed before the cycle is USED, unmarked and linked only through its
#   headers, so the sweep put its blocks on the class list while the slot
#   still linked them. A TLAB chain is FREE and on no list, so a rebuild of
#   the class list (after the sweep released an empty chunk of the class)
#   linked it onto the list while the TLAB still held it. Both are blocks
#   two allocations hand out. The finishing slice now flushes both before it
#   sweeps (`collect_a_little`).
# - *bitmap-free* (`GCRY_INCREMENTAL=1`, bitmap allocator). A `free` frozen
#   between its `occ` and `mark` clears left the block marked and not
#   occupied, and the finishing slice's `occ = mark` occupied it again, owned
#   by nobody: `live_objects` one low and `free_bytes` one payload high for
#   good, the block out of use for a cycle. The slice now clears marks with
#   no occupancy behind them in a class whose lock is held
#   (`clear_frozen_bitmap_stray_marks`).
#
# Each window is forced and each has a control arm that restores the code
# before and must go wrong on the same construction, or the fixed arm passes
# on nothing. Every arm runs in a process of its own. A child whose heap
# cannot reach its window — the wrong allocator, or no page barrier for the
# incremental windows (Linux only) — prints `FROZEN85_SKIP_MARK` and passes,
# and the parent then does not ask for the control's mark.
# `bench/log/linux/2026-10-22-frozen-class-gaps/FINDINGS.md`.

private FROZEN85_SKIP_MARK    = "frozen85: this heap cannot reach the window, skipped"
private FROZEN85_CONTROL_MARK = "frozen85: the control arm went wrong"

# A class the spec runner does not allocate from, small enough that a TLAB
# refill (8 KiB) and a batch take several blocks of it.
private FROZEN85_BYTES = 1792
# The bitmap window's class: nothing else allocates it, so the class lock
# the parked free holds stops nobody.
private FROZEN85_BITMAP_BYTES = 24576
# Blocks the *slice-tlab* window holds and then drops: several chunks' worth.
private FROZEN85_HELD = 200

# The bitmap window's block, in static data, which every slice scans: the
# trace must have marked it before the free clears its `occ` bit.
private class Frozen85Roots
  class_property block : Void* = Pointer(Void).null
end

class Gcry::Heap
  # Is *user* on the class's old-generation freelist? Walks it, bounded.
  def frozen85_listed?(class_index : Int32, user : Void*) : Bool
    u = @freelists[class_index]
    steps = 0
    while !u.null? && steps < (1 << 20)
      return true if u == user
      u = BlockHeader.from_user(u).value.next_free
      steps += 1
    end
    false
  end

  private def frozen85_chain(head : Void*, into : Array(Void*)) : Nil
    u = head
    while !u.null? && into.size < 4096
      into << u
      u = BlockHeader.from_user(u).value.next_free
    end
  end

  # This thread's TLAB chain of the class, head first.
  def frozen85_my_tlab_chain(class_index : Int32) : Array(Void*)
    acc = [] of Void*
    frozen85_chain(current_tlab.value.freelists[class_index], acc)
    acc
  end

  # Every live TLAB's chain of the class.
  def frozen85_tlab_chains(class_index : Int32) : Array(Void*)
    acc = [] of Void*
    return acc unless @tlabs_booted
    MAX_TLABS.times do |i|
      next unless @tlabs[i].live
      frozen85_chain((@tlabs.to_unsafe + i).value.freelists[class_index], acc)
    end
    acc
  end

  # Every live allocation-batch slot's stash of the class.
  def frozen85_stashes(class_index : Int32) : Array(Void*)
    acc = [] of Void*
    return acc unless @alloc_batches_booted
    MAX_TLABS.times do |i|
      next unless @alloc_batches[i].live
      frozen85_chain((@alloc_batches.to_unsafe + i).value.freelists[class_index], acc)
    end
    acc
  end

  # Lengths of the same chains, with no array of their addresses left
  # behind for the collector to find.
  @[NoInline]
  def frozen85_tlab_chain_count(class_index : Int32) : Int32
    return 0 unless @tlabs_booted
    n = 0
    MAX_TLABS.times do |i|
      next unless @tlabs[i].live
      n += frozen85_chain_length((@tlabs.to_unsafe + i).value.freelists[class_index])
    end
    n
  end

  @[NoInline]
  def frozen85_stash_count(class_index : Int32) : Int32
    return 0 unless @alloc_batches_booted
    n = 0
    MAX_TLABS.times do |i|
      next unless @alloc_batches[i].live
      n += frozen85_chain_length((@alloc_batches.to_unsafe + i).value.freelists[class_index])
    end
    n
  end

  private def frozen85_chain_length(head : Void*) : Int32
    n = 0
    u = head
    while !u.null? && n < 4096
      n += 1
      u = BlockHeader.from_user(u).value.next_free
    end
    n
  end

  # The block's `occ` and `mark` bits on a bitmap chunk.
  def frozen85_bits(user : Void*) : {Bool, Bool}
    chunk = chunk_for_owned(user) || raise "no chunk for the block"
    bitmap_alloc_chunk?(chunk) || raise "not a bitmap chunk"
    header = BlockHeader.from_user(user)
    ordinal = chunk_block_ordinal(chunk, header.address)
    bit = 1_u64 << (ordinal & 63)
    word = ordinal >> 6
    occ = ChunkHeader.occ_bitmap(chunk)
    mark = ChunkHeader.mark_bitmap(chunk)
    {(occ[word] & bit) != 0, (mark[word] & bit) != 0}
  end

  # The bitmap arm of `free_result`, step for step, split where a stop can
  # freeze it: under the class lock, after the `occ` clear and before the
  # `mark` clear of `bitmap_free_block`, it yields. Then the counters, as
  # `free_result` does. Returns whether the block was freed.
  def frozen85_split_bitmap_free(user : Void*, &) : Bool
    chunk = chunk_for_owned(user) || raise "no chunk for the block"
    bitmap_alloc_chunk?(chunk) || raise "not a bitmap chunk"
    header = BlockHeader.from_user(user)
    class_index = chunk.value.size_class.to_i32
    payload = SizeClasses.payload(class_index)
    freed = false
    with_freelist_lock(class_index, false) do
      if block_allocated_exact?(chunk, header)
        BlockHeader.set_free(header, Pointer(Void).null)
        ordinal = chunk_block_ordinal(chunk, header.address)
        word = ordinal >> 6
        clear = ~(1_u64 << (ordinal & 63))
        Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And, ChunkHeader.occ_bitmap(chunk) + word, clear,
          LLVM::AtomicOrdering::Monotonic, false)
        yield
        Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::And, ChunkHeader.mark_bitmap(chunk) + word, clear,
          LLVM::AtomicOrdering::Monotonic, false)
        bitmap_capacity_changed(chunk)
        freed = true
      end
    end
    if freed
      free_bytes_add(payload.to_u64)
      bytes_since_gc_sub(payload.to_u64)
      note_explicit_free(payload.to_u64)
      live_objects_dec
    end
    freed
  end
end

private def frozen85_skip : Nil
  STDOUT.puts FROZEN85_SKIP_MARK
  STDOUT.flush
end

private def frozen85_control_went_wrong(what : String) : Nil
  STDOUT.puts "#{FROZEN85_CONTROL_MARK}: #{what}"
  STDOUT.flush
end

# The freelist allocator with TLABs, or nil.
private def frozen85_tlab_heap : Gcry::Heap?
  heap = Gcry.default_heap
  return nil if heap.bitmap_alloc? || heap.nursery_enabled
  heap.tlab_enabled = true
  return nil unless heap.tlab_enabled?
  heap.tight_grow = false
  heap.alloc_batch = 0
  heap
end

# Ready the heap for a sliced cycle; false when it cannot run one (no page
# barrier, which the cycle needs with the world running between slices).
# The barrier is mprotect, as regression 83's: on Linux it works whatever
# the kernel's soft-dirty does.
private def frozen85_incremental_ready?(heap : Gcry::Heap) : Bool
  {% if flag?(:linux) %}
    heap.prefer_mprotect_barrier = true
    true
  {% else %}
    false
  {% end %}
end

private def frozen85_finish_cycle(heap : Gcry::Heap) : Nil
  10_000.times do
    return if heap.collect_a_little
  end
  fail "the incremental cycle never finished"
end

# *tlab-flush*: this thread's TLAB holds a chain of the class; another
# thread, with TLAB off for its allocations, parks in a refill of the class
# under the class lock with the head store still to come; TLAB goes back on
# and this thread collects. Returns the stops that ended while the refill was
# parked and how many of the chain's blocks ended in no TLAB and on no list.
private def frozen85_tlab_flush_window(heap : Gcry::Heap) : {Int32, Int32}
  class_index = Gcry::SizeClasses.index_of(FROZEN85_BYTES.to_u32)
  keep = GC.malloc(FROZEN85_BYTES)
  chain = heap.frozen85_my_tlab_chain(class_index)
  fail "the TLAB refill left no chain" if chain.empty?

  starts = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  stops_seen = Atomic(Int32).new(0)
  heap.post_stw_hook = ->(stage : Symbol) do
    starts.add(1) if stage == :after_start_world
    nil
  end
  # On the refilling thread, under its class lock: allocates nothing.
  heap.refill_publish_hook = ->(c : Gcry::ChunkHeader*) do
    if c.value.size_class == class_index.to_u32 && parked.get == 0
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
  # Allocations from here to the collection take the class lists. The
  # thread allocates until the class list runs dry and its refill parks.
  heap.tlab_enabled = false
  thread = Thread.new do
    until parked.get == 1
      GC.malloc(FROZEN85_BYTES)
    end
  end
  deadline = Time.instant + 10.seconds
  until parked.get == 1 || Time.instant >= deadline
    Intrinsics.pause
  end
  fail "the thread never refilled the class under test" unless parked.get == 1
  heap.tlab_enabled = true
  GC.collect
  thread.join
  heap.refill_publish_hook = nil
  heap.post_stw_hook = nil

  mine = heap.frozen85_my_tlab_chain(class_index)
  stranded = chain.count do |b|
    !mine.includes?(b) && !heap.frozen85_listed?(class_index, b) &&
      Gcry::BlockHeader.free?(Gcry::BlockHeader.from_user(b))
  end
  keep.null?.should be_false
  {stops_seen.get, stranded}
end

# *slice-stash*: a thread's first allocation of the class claims a batch;
# its stash stays in its slot when it exits. A whole incremental cycle runs.
# Returns whether a block of a stash is on the class list.
#
# Before the cycle the stash is only counted: an array of its addresses
# would be a conservative root for every block in it, and the sweep would
# find them marked.
private def frozen85_slice_stash_window(heap : Gcry::Heap) : Bool
  class_index = Gcry::SizeClasses.index_of(FROZEN85_BYTES.to_u32)
  GC.collect
  holder = Array(Void*).new(1, Pointer(Void).null)
  thread = Thread.new do
    # Kept, so the chunk has a live block and the sweep links the stash's
    # blocks onto the list rather than finding the chunk empty.
    holder[0] = GC.malloc(FROZEN85_BYTES)
  end
  thread.join
  heap.frozen85_stash_count(class_index) == 0 && fail "the first allocation stashed nothing"
  frozen85_finish_cycle(heap)
  holder[0].null?.should be_false
  heap.frozen85_stashes(class_index).any? { |b| heap.frozen85_listed?(class_index, b) }
end

# *slice-tlab*: a thread refills its TLAB of the class, keeps the block it
# took and exits, its chain left in its slot; the class's other chunks hold
# only blocks that die just before a whole incremental cycle runs. The
# slice's sweep finds those chunks empty, releases them and rebuilds the
# class list from the chunks it kept — every FREE block in them, the chain's
# included. Returns whether a block of a TLAB chain is on the class list as
# well.
#
# The kept block is what makes the chain's chunk rebuilt: the chain's head
# is marked (the slot is in the heap's own memory, which the trace scans),
# and a chunk whose only marks are on FREE blocks is classified HOLED with
# no live page, so its FREE blocks are not relinked. The chain is counted
# before the cycle, not listed, for the reason the stash window gives.
private def frozen85_slice_tlab_window(heap : Gcry::Heap) : Bool
  class_index = Gcry::SizeClasses.index_of(FROZEN85_BYTES.to_u32)
  heap.lazy_sweep = false
  heap.empty_chunk_retain = 64_u64 << 20
  heap.empty_chunk_warm_retain = 0_u64
  # Several chunks of the class, every block held.
  held = Array(Void*).new(FROZEN85_HELD, Pointer(Void).null)
  FROZEN85_HELD.times { |i| held[i] = GC.malloc(FROZEN85_BYTES) }
  # Back on the class list: this thread's TLAB chain.
  GC.collect
  kept = Array(Void*).new(1, Pointer(Void).null)
  thread = Thread.new do
    kept[0] = GC.malloc(FROZEN85_BYTES)
  end
  thread.join
  heap.frozen85_tlab_chain_count(class_index) == 0 && fail "the thread's TLAB holds no chain"
  held.fill(Pointer(Void).null)
  frozen85_finish_cycle(heap)
  kept[0].null?.should be_false
  heap.frozen85_tlab_chains(class_index).any? { |b| heap.frozen85_listed?(class_index, b) }
end

# *bitmap-free*: start a cycle and mark the block, park another thread's
# free of it between its two clears, finish the cycle, let the free finish.
# Returns whether the block is occupied after all that.
#
# Nothing allocates on either thread from the first slice to the last: while
# a cycle is open every allocation runs a slice of it (`maybe_collect`), and
# the cycle would end before the free parks. So the thread is made first and
# waits for its cue.
private def frozen85_bitmap_free_window(heap : Gcry::Heap) : Bool
  GC.collect
  Frozen85Roots.block = GC.malloc(FROZEN85_BITMAP_BYTES)
  p = Frozen85Roots.block
  start = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  go = Atomic(Int32).new(0)
  freed = Atomic(Int32).new(0)
  # On the freeing thread, under the class lock: allocates nothing.
  thread = Thread.new do
    until start.get == 1
      Intrinsics.pause
    end
    ok = heap.frozen85_split_bitmap_free(p) do
      parked.set(1)
      deadline = Time.instant + 10.seconds
      while go.get == 0 && Time.instant < deadline
        Intrinsics.pause
      end
    end
    freed.set(ok ? 1 : 0)
  end
  # The begin stop and one unit of marking: static data is a root, so the
  # block is marked from here on.
  heap.collect_a_little(1) && fail "the cycle finished in its first slice"
  occ, mark = heap.frozen85_bits(p)
  fail "the block is not occupied and marked (occ=#{occ} mark=#{mark})" unless occ && mark
  start.set(1)
  deadline = Time.instant + 10.seconds
  until parked.get == 1 || Time.instant >= deadline
    Intrinsics.pause
  end
  fail "the free never reached its park" unless parked.get == 1
  fail "the cycle ended before the free parked" unless heap.incremental_in_progress?
  frozen85_finish_cycle(heap)
  go.set(1)
  thread.join
  freed.get.should eq(1)
  Frozen85Roots.block = Pointer(Void).null
  occ_after, _ = heap.frozen85_bits(p)
  occ_after
end

describe "Regression: the stop's frozen-class gaps after 84" do
  {"tlab-flush", "slice-stash", "slice-tlab", "bitmap-free"}.each do |window|
    {"fixed", "control"}.each do |arm|
      it "#{window} #{arm} arm in a process of its own" do
        captured = IO::Memory.new
        env = {"GCRY_FROZEN85_CHILD" => "#{window}-#{arm}"} of String => String?
        # The control arms leave blocks lost or handed out twice on purpose.
        env["GCRY_DEBUG_INVARIANTS"] = nil if arm == "control"
        status = Process.run(Process.executable_path.not_nil!,
          ["-e", "frozen85 child #{window} #{arm}"],
          env: env, output: captured, error: captured)
        text = captured.to_s
        fail "child #{status.inspect}:\n#{text}" unless status.success?
        text.should contain("1 examples, 0 failures")
        if arm == "control" && !text.includes?(FROZEN85_SKIP_MARK)
          text.should contain(FROZEN85_CONTROL_MARK)
        end
      end
    end
  end

  it "frozen85 child tlab-flush fixed" do
    next unless ENV["GCRY_FROZEN85_CHILD"]? == "tlab-flush-fixed"
    next frozen85_skip unless heap = frozen85_tlab_heap
    kept = heap.stop_tlab_flush_frozen_kept
    stops, stranded = frozen85_tlab_flush_window(heap)
    stops.should be > 0
    # Kept in the TLAB because the class was frozen, not by luck.
    (heap.stop_tlab_flush_frozen_kept - kept).should be > 0
    stranded.should eq(0)
  end

  it "frozen85 child tlab-flush control" do
    next unless ENV["GCRY_FROZEN85_CHILD"]? == "tlab-flush-control"
    next frozen85_skip unless heap = frozen85_tlab_heap
    heap.stop_tlab_flush_frozen_skip = false
    stops, stranded = frozen85_tlab_flush_window(heap)
    stops.should be > 0
    stranded.should be > 0
    frozen85_control_went_wrong("#{stranded} TLAB blocks in no TLAB and on no list")
  end

  it "frozen85 child slice-stash fixed" do
    next unless ENV["GCRY_FROZEN85_CHILD"]? == "slice-stash-fixed"
    heap = Gcry.default_heap
    next frozen85_skip if heap.bitmap_alloc? || heap.nursery_enabled || !frozen85_incremental_ready?(heap)
    heap.alloc_batch = 8
    frozen85_slice_stash_window(heap).should be_false
  end

  it "frozen85 child slice-stash control" do
    next unless ENV["GCRY_FROZEN85_CHILD"]? == "slice-stash-control"
    heap = Gcry.default_heap
    next frozen85_skip if heap.bitmap_alloc? || heap.nursery_enabled || !frozen85_incremental_ready?(heap)
    heap.alloc_batch = 8
    heap.inc_finish_flush = false
    frozen85_slice_stash_window(heap).should be_true
    frozen85_control_went_wrong("stash blocks on the class list")
  end

  it "frozen85 child slice-tlab fixed" do
    next unless ENV["GCRY_FROZEN85_CHILD"]? == "slice-tlab-fixed"
    next frozen85_skip unless (heap = frozen85_tlab_heap) && frozen85_incremental_ready?(heap)
    frozen85_slice_tlab_window(heap).should be_false
  end

  it "frozen85 child slice-tlab control" do
    next unless ENV["GCRY_FROZEN85_CHILD"]? == "slice-tlab-control"
    next frozen85_skip unless (heap = frozen85_tlab_heap) && frozen85_incremental_ready?(heap)
    heap.inc_finish_flush = false
    frozen85_slice_tlab_window(heap).should be_true
    frozen85_control_went_wrong("TLAB blocks on the class list")
  end

  it "frozen85 child bitmap-free fixed" do
    next unless ENV["GCRY_FROZEN85_CHILD"]? == "bitmap-free-fixed"
    heap = Gcry.default_heap
    next frozen85_skip unless heap.bitmap_alloc? && frozen85_incremental_ready?(heap)
    cleared = heap.stop_slice_stray_marks_cleared
    frozen85_bitmap_free_window(heap).should be_false
    (heap.stop_slice_stray_marks_cleared - cleared).should be > 0
  end

  it "frozen85 child bitmap-free control" do
    next unless ENV["GCRY_FROZEN85_CHILD"]? == "bitmap-free-control"
    heap = Gcry.default_heap
    next frozen85_skip unless heap.bitmap_alloc? && frozen85_incremental_ready?(heap)
    heap.stop_slice_stray_mark_clear = false
    frozen85_bitmap_free_window(heap).should be_true
    frozen85_control_went_wrong("the freed block occupied again")
  end
end
