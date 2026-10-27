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
# The interleaving is forced, with no timer in it. A thread takes
# `@index_lock` and holds it until the collection has restarted the world
# (`post_stw_hook :after_start_world` lets it go), so the stop freezes it
# inside the lock. The main thread collects with the sweep in the stop and
# one empty chunk for it to queue for release. The sweep's research hook
# (`stop_sweep_bounds_hook`) runs on the collector at the branch that used to
# recompute the bounds, in the stop, and reads the lock word there, so what
# each arm reports about that branch comes from inside it rather than from
# the heap after the fact:
#
# - fixed: the hook ran with the lock held and the recompute deferred
#   (`stop_sweep_bounds_deferred`), the stop restarted the world while the
#   holder still held the lock, and the flush released the chunk after it.
# - control (`stop_sweep_index_lock = false`, the code before): the hook
#   writes, from inside the stop, that the collector is taking `@index_lock`
#   while another thread holds it, and the stop never ends. The parent kills
#   the child at a deadline and reads that line and the watchdog's. One that
#   wrote it and still finished fails the arm, and so does a hang without it.
#
# The one thing that can keep the stop from reaching that branch is a third
# thread waiting for `@index_lock` inside `@chunk_list_lock`: a cursor's pool
# take (`bitmap_take_pool_chunk` looks the chunk up in the index under the
# list lock) or a `map_chunk`. The stop then finds the list lock held,
# relinks nothing and releases nothing (`stop_sweep_relinks_declined`,
# regression 75), so no bounds recompute is reached. Locally that was the
# idle-release thread taking a pool chunk right after the layout's
# collection, in 5 of 6 fixed children; `GCRY_IDLE_RELEASE_MS=0` keeps it
# unborn, as regressions 65, 69 and 78 do. The CI run where the control
# child came back (39825990272, macOS header layout) said nothing about why;
# a window that misses now says so (that count among it) and the child tries
# again, at most three times, and the arm fails if every try misses.
#
# Each arm runs in a process of its own, and the parent prints each child's
# `holder81:` and watchdog lines on success too, so a green log says which
# branch was taken. `bench/log/linux/2026-10-22-in-stop-sweep-audit/FINDINGS.md`.

class Gcry::Heap
  # Take `@index_lock`, say so, and hold it until *release* is set or
  # *deadline* passes. Spins rather than sleeps: the caller holds a
  # spinlock, and the stop must find this thread running inside it.
  # Allocates nothing.
  def holder81_hold(held : Atomic(Int32)*, release : Atomic(Int32)*, deadline : Time::Instant) : Nil
    @index_lock.sync do
      held.value.set(1)
      until release.value.get != 0 || Time.instant >= deadline
        Intrinsics.pause
      end
    end
  end

  # The word of `Crystal::SpinLock` (`@m`, checked by `try_lock_spinlock`):
  # nonzero while some thread holds `@index_lock`.
  def holder81_index_lock_word : Int32
    Atomic::Ops.load(pointerof(@index_lock).as(Int32*), LLVM::AtomicOrdering::SequentiallyConsistent, true)
  end
end

# A class nothing in the spec runner allocates (24 576 B: five blocks to the
# 128 KiB library chunk, ten to Darwin's 256 KiB process chunk), so the
# chunk under test is this example's alone. Three blocks fit either way.
private HOLDER81_BYTES  = 24576
private HOLDER81_BLOCKS =     3
# How long the holder may hold the lock at most. Only a broken setup reaches
# it: the fixed arm lets it go at the restart, and the control arm's holder
# is frozen. Long enough for a slow debug build's collection.
private HOLDER81_HOLD_S = 60
# Windows a child tries before it gives up on reaching the branch.
private HOLDER81_ATTEMPTS = 3
# The control parent's deadline: a child that has not finished by then is
# hung (the watchdog fires at 1 s, a missed window costs milliseconds).
private HOLDER81_CONTROL_S = 20
# Written by the sweep's hook, from inside the stop, with a raw write.
private HOLDER81_TAKING = "holder81: the stop's sweep is taking @index_lock while another thread holds it\n"
private HOLDER81_FREE   = "holder81: the stop's sweep is taking @index_lock, which no thread holds\n"
private HOLDER81_SETUP  = "holder81: collecting with @index_lock held"
private HOLDER81_FIXED  = "holder81: fixed:"

private def holder81_heap : Gcry::Heap
  heap = Gcry.default_heap
  heap.lazy_sweep = false
  # The empty chunk is released (unmapped), not made dormant, kept warm or
  # kept on grace, whatever the thread count and platform: the branch that
  # recomputed the bounds. `GC.collect` releases warm (`release_warm`), so
  # no grace either; Darwin's process default keeps 512 KiB dormant, hence
  # the zero retain.
  heap.release_empty_chunks = true
  heap.parallel_empty_chunk_munmap = true
  heap.empty_chunk_retain = 0_u64
  heap.empty_chunk_warm_retain = 0_u64
  heap
end

# What one window saw: the sweep hook's calls with the lock held and with
# nobody holding it, and those on the arm that takes it; whether a stop
# restarted the world with the holder inside; whether the chunk under test
# left the index; and the `stop_sweep_bounds_deferred` and
# `stop_sweep_relinks_declined` deltas over the collection.
private record Holder81Result,
  reached_held : Int32,
  reached_free : Int32,
  takes_lock : Int32,
  restarted_held : Bool,
  released : Bool,
  deferred : UInt64,
  relinks_declined : UInt64 do
  def to_s(io : IO) : Nil
    io << "branch reached with the lock held=" << reached_held << " free=" << reached_free
    io << " taking it=" << takes_lock << ", deferred=+" << deferred
    io << ", relinks declined=+" << relinks_declined
    io << ", restarted with the lock held=" << restarted_held << ", chunk released=" << released
  end
end

# Start the holder, lay out an empty chunk no cursor holds, let the holder
# take `@index_lock`, and collect. The holder exists before the layout so
# that its `Thread.new`, which allocates and may collect, cannot release the
# chunk early; and from the holder's taking the lock until `GC.collect` this
# thread allocates nothing (a first allocation of a class maps a chunk, and
# `map_chunk` takes the lock) and spins rather than sleeps.
private def holder81_window(heap : Gcry::Heap) : Holder81Result
  go = Atomic(Int32).new(0)
  held = Atomic(Int32).new(0)
  release = Atomic(Int32).new(0)
  restarted_held = Atomic(Int32).new(0)
  reached_held = Atomic(Int32).new(0)
  reached_free = Atomic(Int32).new(0)
  takes_lock = Atomic(Int32).new(0)
  # On the collector, in the stop: atomics and a raw write only.
  bounds_hook = ->(taking : Bool) do
    locked = heap.holder81_index_lock_word != 0
    if locked
      reached_held.add(1)
    else
      reached_free.add(1)
    end
    if taking
      takes_lock.add(1)
      line = locked ? HOLDER81_TAKING : HOLDER81_FREE
      Gcry::OS.write(2, line.to_unsafe, LibC::SizeT.new(line.bytesize))
    end
    nil
  end
  # On the collector, world running: the holder may go. It is what keeps
  # the fixed arm's flush, whose `index_remove` waits for the lock, from
  # waiting on a timer.
  stw_hook = ->(stage : Symbol) do
    if stage == :after_start_world && held.get == 1
      restarted_held.set(1) if release.get == 0
      release.set(1)
    end
    nil
  end
  heap.stop_sweep_bounds_hook = bounds_hook
  heap.post_stw_hook = stw_hook
  deadline = Time.instant + HOLDER81_HOLD_S.seconds
  thread = Thread.new do
    until go.get != 0 || Time.instant >= deadline
      Intrinsics.pause
    end
    heap.holder81_hold(pointerof(held), pointerof(release), deadline)
  end

  # Blocks in a fresh chunk, kept across a collection that retires this
  # thread's cursor off it, then freed: an empty chunk no cursor holds,
  # which the next major's sweep queues for release.
  blocks = Array(Void*).new(HOLDER81_BLOCKS) { GC.malloc(HOLDER81_BYTES) }
  chunk = heap.chunk_address_of(blocks[0])
  chunk.should_not eq(0_u64)
  blocks.each { |p| heap.chunk_address_of(p).should eq(chunk) }
  GC.collect
  blocks.each { |p| GC.free(p) }
  indexed = false
  heap.each_indexed_chunk { |c| indexed = true if c.address == chunk }
  fail "the chunk under test left the index before the window" unless indexed
  deferred = heap.stop_sweep_bounds_deferred
  relinks = heap.stop_sweep_relinks_declined

  STDOUT.puts HOLDER81_SETUP
  STDOUT.flush
  go.set(1)
  until held.get == 1 || Time.instant >= deadline
    Intrinsics.pause
  end
  fail "the holder never took @index_lock" unless held.get == 1
  GC.collect
  thread.join
  heap.stop_sweep_bounds_hook = nil
  heap.post_stw_hook = nil
  released = true
  heap.each_indexed_chunk { |c| released = false if c.address == chunk }
  # Keeps both closures on this stack through the collection: the heap's
  # properties are no root.
  bounds_hook.closure?.should be_true
  stw_hook.closure?.should be_true
  Holder81Result.new(reached_held.get, reached_free.get, takes_lock.get, restarted_held.get == 1,
    released, heap.stop_sweep_bounds_deferred - deferred, heap.stop_sweep_relinks_declined - relinks)
end

# Windows until one whose stop reaches the bounds branch with the holder in
# the lock, each miss said; the last result either way.
private def holder81_attempts(heap : Gcry::Heap, arm : String) : Holder81Result
  result = holder81_window(heap)
  attempt = 1
  while result.reached_held == 0 && attempt < HOLDER81_ATTEMPTS
    STDOUT.puts "holder81: #{arm} window #{attempt} missed the branch: #{result}"
    STDOUT.flush
    result = holder81_window(heap)
    attempt += 1
  end
  result
end

# A child's `holder81:` and watchdog lines, for the parent's log, on lines
# of their own after the runner's progress output.
private def holder81_report(arm : String, text : String) : Nil
  STDOUT.puts
  text.each_line do |line|
    STDOUT.puts "  [81 #{arm}] #{line}" if line.starts_with?("holder81:") || line.includes?("STOP-THE-WORLD STALLED")
  end
  STDOUT.flush
end

# Both children run without the idle-release thread (see the top).
private def holder81_env(arm : String) : Hash(String, String?)
  env = {"GCRY_FROZEN_INDEX_CHILD" => arm, "GCRY_IDLE_RELEASE_MS" => "0"} of String => String?
  env["GCRY_STW_WATCHDOG_MS"] = "1000" if arm == "control"
  env
end

describe "Regression: an in-stop sweep takes no @index_lock a frozen thread may hold" do
  it "fixed arm in a process of its own" do
    captured = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!, ["-e", "stop-sweep-frozen-index-holder child fixed"],
      env: holder81_env("fixed"), output: captured, error: captured)
    fail "child #{status.inspect}:\n#{captured}" unless status.success?
    text = captured.to_s
    text.should contain("1 examples, 0 failures")
    text.should contain(HOLDER81_FIXED)
    holder81_report("fixed", text)
  end

  it "control arm hangs in the stop" do
    captured = IO::Memory.new
    child = Process.new(Process.executable_path.not_nil!, ["-e", "stop-sweep-frozen-index-holder child control"],
      env: holder81_env("control"), output: captured, error: captured)
    deadline = Time.instant + HOLDER81_CONTROL_S.seconds
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
    # Came back: every window missed the branch (each says why), or one
    # reached it with the lock held and still finished, which the old code
    # cannot do.
    fail "the control child finished:\n#{text}" if finished
    # Hung, and it is this hang: the collector wrote from inside the stop
    # that it was taking the lock the holder held, and the stop never
    # restarted the world — the holder's hold ends at that restart — so the
    # watchdog reports the sweep stalled.
    text.should contain(HOLDER81_SETUP)
    text.should contain(HOLDER81_TAKING)
    text.should contain("STOP-THE-WORLD STALLED")
    text.should contain("phase=sweep")
    holder81_report("control", text)
  end

  it "stop-sweep-frozen-index-holder child fixed" do
    next unless ENV["GCRY_FROZEN_INDEX_CHILD"]? == "fixed"
    heap = holder81_heap
    result = holder81_attempts(heap, "fixed")
    STDOUT.puts "#{HOLDER81_FIXED} #{result}"
    STDOUT.flush
    # The stop reached the branch that used to take the lock while the holder
    # held it, and deferred the recompute rather than take it.
    result.reached_held.should be > 0
    result.takes_lock.should eq(0)
    result.deferred.should be > 0
    # The stop finished while a thread it froze held `@index_lock`.
    result.restarted_held.should be_true
    # And the flush released the empty chunk after the holder let go.
    result.released.should be_true
  end

  it "stop-sweep-frozen-index-holder child control" do
    next unless ENV["GCRY_FROZEN_INDEX_CHILD"]? == "control"
    heap = holder81_heap
    heap.stop_sweep_index_lock = false
    result = holder81_attempts(heap, "control")
    # Only a window that missed the branch gets here: the old code, reaching
    # it with the lock held, never comes back.
    STDOUT.puts "holder81: control came back: #{result}"
    STDOUT.flush
  end
end
