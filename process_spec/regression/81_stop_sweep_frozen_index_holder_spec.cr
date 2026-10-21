require "../../src/gcry"
require "spec"

# An in-stop sweep that queued an empty chunk for release recomputed the heap
# bounds before the world restarted (`update_heap_bounds_after_unmap`), and
# that takes `@index_lock` with a blocking `sync`. A thread the stop froze
# while holding that lock — every locked `chunk_containing` holds it, from a
# free, a realloc, `GC.is_heap_ptr`; so do `note_mapped` and
# `publish_large_growth` — never lets go, so the collector spun on it with
# every mutator parked: a hang, the 0.21.1 `@chunk_list_lock` hang one lock
# over. `index_remove` had been moved out of the stop for exactly that
# reason; the bounds update a few lines below it had not. The chunk-list
# try-lock does not cover it, since `chunk_containing` takes the index lock
# alone. The bounds are now recomputed by the post-stop flush, after the
# release, with the world running (`Heap#sweep`, `stop_sweep_index_lock`).
#
# The interleaving is forced: a thread holds `@index_lock` and spins, so the
# stop freezes it inside, and the main thread collects with the sweep in the
# stop and an empty chunk for it to release. The fixed arm finishes the stop
# while the holder still holds the lock, and the release waits for the
# holder after the world restarts. The control arm
# (`stop_sweep_index_lock = false`, the code before) must hang on the same
# construction — the parent kills it at a deadline and reads the watchdog —
# or the fixed arm passes on nothing. Each arm runs in a process of its own.
# `bench/log/linux/2026-10-22-in-stop-sweep-audit/FINDINGS.md`.

class Gcry::Heap
  # Take `@index_lock`, say so, and hold it for *ms* milliseconds. Spins
  # rather than sleeps: the caller holds a spinlock, and the stop must find
  # this thread running inside it. Allocates nothing.
  def holder81_hold(held : Atomic(Int32)*, ms : Int32) : Nil
    @index_lock.sync do
      held.value.set(1)
      deadline = Time.instant + ms.milliseconds
      while Time.instant < deadline
        Intrinsics.pause
      end
    end
  end
end

# A class nothing in the spec runner allocates (24 576 B, five blocks to a
# 128 KiB chunk), so the chunk under test is this example's alone.
private HOLDER81_BYTES  = 24576
private HOLDER81_BLOCKS =     3
# Long enough that the stop lands inside it, short enough that the fixed
# arm's flush, which waits for it with the world running, ends promptly.
private HOLDER81_HOLD_MS = 2000

private def holder81_heap : Gcry::Heap
  heap = Gcry.default_heap
  heap.lazy_sweep = false
  # The empty chunk is released (unmapped), not made dormant or kept,
  # whatever the thread count: the branch that recomputed the bounds.
  heap.parallel_empty_chunk_munmap = true
  heap.empty_chunk_retain = 0_u64
  heap.empty_chunk_warm_retain = 0_u64
  heap
end

# Blocks in a fresh chunk, kept across a collection that retires this
# thread's cursor off it, then freed: an empty chunk no cursor holds, which
# the next major's sweep queues for release.
private def holder81_empty_chunk(heap : Gcry::Heap) : UInt64
  blocks = Array(Void*).new(HOLDER81_BLOCKS) { GC.malloc(HOLDER81_BYTES) }
  chunk = heap.chunk_address_of(blocks[0])
  chunk.should_not eq(0_u64)
  blocks.each { |p| heap.chunk_address_of(p).should eq(chunk) }
  GC.collect
  blocks.each { |p| GC.free(p) }
  chunk
end

# Hold `@index_lock` on another thread and collect. Returns whether the
# stop ended while the holder still held the lock.
private def holder81_window(heap : Gcry::Heap) : Bool
  held = Atomic(Int32).new(0)
  released = Atomic(Int32).new(0)
  restarted_while_held = Atomic(Int32).new(0)
  heap.post_stw_hook = ->(stage : Symbol) do
    if stage == :after_start_world && held.get == 1 && released.get == 0
      restarted_while_held.set(1)
    end
    nil
  end
  # Said before the holder starts: from then until `GC.collect` this thread
  # must take no `@index_lock` itself, so it allocates nothing (a first
  # allocation of a class maps a chunk, and `map_chunk` takes the lock) and
  # spins rather than sleeps.
  STDOUT.puts "holder81: collecting with @index_lock held"
  STDOUT.flush
  thread = Thread.new do
    heap.holder81_hold(pointerof(held), HOLDER81_HOLD_MS)
    released.set(1)
  end
  deadline = Time.instant + 10.seconds
  until held.get == 1 || Time.instant >= deadline
    Intrinsics.pause
  end
  fail "the holder never took @index_lock" unless held.get == 1
  GC.collect
  thread.join
  heap.post_stw_hook = nil
  restarted_while_held.get == 1
end

describe "Regression: an in-stop sweep takes no @index_lock a frozen thread may hold" do
  it "fixed arm in a process of its own" do
    captured = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!, ["-e", "stop-sweep-frozen-index-holder child fixed"],
      env: {"GCRY_FROZEN_INDEX_CHILD" => "fixed"}, output: captured, error: captured)
    fail "child #{status.inspect}:\n#{captured}" unless status.success?
    captured.to_s.should contain("1 examples, 0 failures")
  end

  it "control arm hangs in the stop" do
    captured = IO::Memory.new
    child = Process.new(Process.executable_path.not_nil!, ["-e", "stop-sweep-frozen-index-holder child control"],
      env: {"GCRY_FROZEN_INDEX_CHILD" => "control", "GCRY_STW_WATCHDOG_MS" => "1000"},
      output: captured, error: captured)
    deadline = Time.instant + 20.seconds
    finished = false
    while Time.instant < deadline
      if child.terminated?
        child.wait
        finished = true
        break
      end
      sleep 100.milliseconds
    end
    unless finished
      child.terminate(graceful: false)
      child.wait
    end
    text = captured.to_s
    # Reached the collection, and never came back from its stop: the
    # holder's 2 s hold ended long before the deadline for a thread that
    # runs, and never for one the stop froze.
    text.should contain("holder81: collecting with @index_lock held")
    fail "the control arm finished:\n#{text}" if finished
    text.should contain("STOP-THE-WORLD STALLED")
    text.should contain("phase=sweep")
  end

  it "stop-sweep-frozen-index-holder child fixed" do
    next unless ENV["GCRY_FROZEN_INDEX_CHILD"]? == "fixed"
    heap = holder81_heap
    chunk = holder81_empty_chunk(heap)
    restarted = holder81_window(heap)
    # The stop finished while a thread it froze held `@index_lock`.
    restarted.should be_true
    # And the sweep released the empty chunk, so it reached the branch that
    # used to take the lock: the chunk is out of the index.
    heap.each_indexed_chunk { |c| c.address.should_not eq(chunk) }
  end

  it "stop-sweep-frozen-index-holder child control" do
    next unless ENV["GCRY_FROZEN_INDEX_CHILD"]? == "control"
    heap = holder81_heap
    heap.stop_sweep_index_lock = false
    holder81_empty_chunk(heap)
    holder81_window(heap)
  end
end
