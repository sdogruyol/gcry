require "../../src/gcry"
require "spec"

# A refill retires its exhausted chunk (`retire_cursor_slot`) and takes
# another. The retire cleared CURSOR on the chunk first, then read the chunk
# (`bitmap_pool_candidate?`, `bitmap_capacity_changed`), then cleared the
# slot. A stop that froze the refill between the first two found a chunk no
# cursor's: the in-stop sweep honours CURSOR and nothing else (it cannot
# take the class lock the refill holds, and the finishing slice of an
# incremental cycle runs no settle), so a chunk whose blocks had all died
# was queued for release and unmapped by the flush after `start_world`. The
# refill resumed into the unmapped header, and its slot still named the
# chunk for the next settle to write PINNED into. The retire now reads the
# chunk while it is CURSOR, clears the slot, and clears CURSOR last: frozen
# before that the chunk is CURSOR and kept; after it nothing touches the
# chunk again (`retire_cursor_slot`).
#
# The interleaving is forced: `cursor_retire_hook` runs on the retiring
# thread right after CURSOR is cleared, frees the chunk's blocks there (the
# thread holds its class lock, so `GC.free` would wait on itself; the body
# of the free is called instead), and parks until the main thread has
# collected, with the sweep in the stop, and released the chunk. The control
# arm (`cursor_retire_slot_first = false`, the order before) must leave the
# slot naming the unmapped chunk on the same construction, or the fixed arm
# passes on nothing; it exits before the thread can touch the chunk. Each
# arm runs in a process of its own.
# `bench/log/linux/2026-10-22-in-stop-sweep-audit/FINDINGS.md`.

class Gcry::Heap
  # The body of `GC.free` for a bitmap block, without the class lock: for a
  # thread that already holds it. Allocates nothing.
  def retire82_free(chunk : Gcry::ChunkHeader*, user : Void*) : Nil
    header = BlockHeader.from_user(user)
    payload = SizeClasses.payload(chunk.value.size_class.to_i32).to_u64
    BlockHeader.set_free(header, Pointer(Void).null)
    bitmap_free_block(chunk, header)
    free_bytes_add(payload)
    bytes_since_gc_sub(payload)
    note_explicit_free(payload)
    live_objects_dec
  end

  # Does any cursor slot name *chunk*?
  def retire82_slot_names?(chunk : UInt64) : Bool
    found = false
    each_cursor_set do |set|
      i = 0
      while i < POOL_SLOTS
        found = true if CursorSet.slot(set, i).value.chunk.address == chunk
        i += 1
      end
    end
    found
  end

  def retire82_indexed?(chunk : UInt64) : Bool
    found = false
    each_indexed_chunk { |c| found = true if c.address == chunk }
    found
  end
end

# A class nothing in the spec runner allocates (24 576 B, five blocks to a
# 128 KiB chunk), so the chunk under test is the retiring thread's alone.
private RETIRE82_BYTES = 24576
private RETIRE82_ROOM  =    16

private def retire82_heap : Gcry::Heap
  heap = Gcry.default_heap
  heap.lazy_sweep = false
  # The empty chunk is released (unmapped), not made dormant or kept,
  # whatever the thread count.
  heap.parallel_empty_chunk_munmap = true
  heap.empty_chunk_retain = 0_u64
  heap.empty_chunk_warm_retain = 0_u64
  heap
end

# Walk minus counter, read until two readings agree (a runtime thread may be
# allocating), as `bench/claim_stress.cr` reads it.
private def retire82_drift(& : -> Int64?) : Int64?
  last = nil
  100.times do
    d = yield
    return d if d && d == last
    last = d
    sleep 10.milliseconds
  end
  last
end

# A thread allocates RETIRE82_BYTES blocks until its cursor exhausts the
# chunk the first one came from and retires it. Parked in the retire, it
# frees that chunk's blocks; the main thread collects. Returns the chunk,
# whether the stop ended while the thread was parked, and the release
# function for the parked thread (and its join).
private def retire82_window(heap : Gcry::Heap) : {UInt64, Bool, Proc(Nil)}
  starts = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  go = Atomic(Int32).new(0)
  stopped_while_parked = Atomic(Int32).new(0)
  target = Atomic(UInt64).new(0_u64)
  blocks = Array(Void*).new(RETIRE82_ROOM, Pointer(Void).null)
  count = Atomic(Int32).new(0)
  heap.post_stw_hook = ->(stage : Symbol) do
    starts.add(1) if stage == :after_start_world
    nil
  end
  # On the retiring thread, under its class lock, CURSOR just cleared:
  # allocates nothing.
  heap.cursor_retire_hook = ->(c : Gcry::ChunkHeader*) do
    if c.address == target.get && parked.get == 0
      n = count.get
      i = 0
      while i < n
        p = blocks[i]
        heap.retire82_free(c, p) if heap.chunk_address_of(p) == c.address
        i += 1
      end
      entered = starts.get
      parked.set(1)
      deadline = Time.instant + 10.seconds
      while (starts.get == entered || go.get == 0) && Time.instant < deadline
        Intrinsics.pause
      end
      stopped_while_parked.set(1) if starts.get != entered
    end
    nil
  end

  thread = Thread.new do
    first = GC.malloc(RETIRE82_BYTES)
    blocks[0] = first
    count.set(1)
    target.set(heap.chunk_address_of(first))
    # Every block until the one after the chunk's last: that allocation's
    # refill retires the chunk, exhausted.
    while count.get < RETIRE82_ROOM && parked.get == 0
      p = GC.malloc(RETIRE82_BYTES)
      blocks[count.get] = p
      count.add(1)
    end
  end
  deadline = Time.instant + 10.seconds
  until parked.get == 1 || Time.instant >= deadline
    sleep 1.millisecond
  end
  fail "the thread never retired the chunk under test" unless parked.get == 1
  GC.collect
  release = -> do
    go.set(1)
    thread.join
    heap.cursor_retire_hook = nil
    heap.post_stw_hook = nil
    nil
  end
  {target.get, starts.get > 0, release}
end

describe "Regression: a cursor retire leaves no chunk an in-stop sweep may release under it" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      env = {"GCRY_FROZEN_RETIRE_CHILD" => arm} of String => String?
      status = Process.run(Process.executable_path.not_nil!, ["-e", "stop-sweep-frozen-cursor-retire child #{arm}"],
        env: env, output: captured, error: captured)
      fail "child #{status.inspect}:\n#{captured}" unless status.success?
      if arm == "control"
        captured.to_s.should contain("retire82: control released the chunk its slot names")
      else
        captured.to_s.should contain("1 examples, 0 failures")
      end
    end
  end

  it "stop-sweep-frozen-cursor-retire child fixed" do
    next unless ENV["GCRY_FROZEN_RETIRE_CHILD"]? == "fixed"
    heap = retire82_heap
    next unless heap.bitmap_alloc?
    chunk, stopped, release = retire82_window(heap)
    stopped.should be_true
    # The sweep released the chunk (empty, no cursor's): it is out of the
    # index and unmapped, and no slot names it.
    heap.retire82_indexed?(chunk).should be_false
    heap.retire82_slot_names?(chunk).should be_false
    # The thread resumes past the point where it used to read the chunk.
    release.call
    retire82_drift { Gcry::Invariant.live_objects_drift(heap) }.should eq(0)
    retire82_drift { Gcry::Invariant.free_bytes_drift(heap) }.should eq(0)
    GC.collect
  end

  it "stop-sweep-frozen-cursor-retire child control" do
    next unless ENV["GCRY_FROZEN_RETIRE_CHILD"]? == "control"
    heap = retire82_heap
    unless heap.bitmap_alloc?
      STDOUT.puts "retire82: control released the chunk its slot names (skipped: no bitmap allocator)"
      next
    end
    heap.cursor_retire_slot_first = false
    chunk, stopped, _ = retire82_window(heap)
    stopped.should be_true
    # Unmapped, and the parked thread's slot still names it: on resume the
    # thread reads its header (`bitmap_pool_candidate?`), and the next
    # settle writes PINNED into it. Exit before either happens.
    heap.retire82_indexed?(chunk).should be_false
    heap.retire82_slot_names?(chunk).should be_true
    STDOUT.puts "retire82: control released the chunk its slot names"
    STDOUT.flush
    LibC._exit(0)
  end
end
