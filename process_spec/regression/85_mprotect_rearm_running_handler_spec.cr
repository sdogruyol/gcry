require "../../src/gcry"
require "spec"

# The mprotect page barrier is re-armed with the world running after a lazy
# sweep (`run_collection_body`'s lazy path, the default): the collector
# unprotects every old chunk, swaps the card state twice
# (`disarm_mprotect_barrier`, then `mprotect_set_heap_range`), and protects
# the old chunks again under new cards. Regression 83 keeps a stop from
# freezing a fault handler, but this re-arm happens outside any stop, so a
# handler on another thread can be anywhere in its few dozen instructions
# while it runs. Until 2026-10-22 that went wrong four ways, and each has a
# construction here, with a research hook parking the writer's handler at
# one point while the main thread collects:
#
# - *held*: parked just after reading the card state. The second swap freed
#   that state under it (use-after-free); now it is retired and freed once
#   no handler is inside. Resumed, the handler found the page unprotected
#   in its old cards and called the fault foreign, which uninstalled the
#   barrier and handed the retried write — to a page the re-arm had
#   protected again — to Crystal's handler: "Invalid memory access". Now
#   the fault is retried once and lands in the new cards.
# - *stale*: parked after claiming the page in the old cards, before its
#   `mprotect`. It then made the page writable under new cards that called
#   it protected and clean, and the writes went unrecorded. Now it checks
#   the generation after its `mprotect` and records the page in the
#   current cards.
# - *straggler*: parked on entry, before reading anything, and released by
#   the re-arm itself between setting the page's protected bit and its
#   `mprotect`. It claimed the page and unprotected it first, the re-arm
#   protected it after, and the next writer read "claimed" in the bits on a
#   read-only page and returned to fault again, for ever in this child. Now
#   a handler that claims makes the page writable itself.
#
# Each control arm restores one piece of the code before
# (`Gcry::Platform.mprotect_defer_free`, `mprotect_retry_unclaimed`,
# `mprotect_revalidate`, `mprotect_claim_unprotects` = false) and must go
# wrong on the same construction, or the fixed arm passes on nothing. The
# *held* free control leaves before the handler resumes into freed memory.
# Every arm runs in a process of its own. A child that finds the re-arm ran
# inside the stop (the sweep went there) says so and the parent accepts it.
# Linux only, the one platform with the mprotect barrier.
# `bench/log/linux/2026-10-22-mprotect-card-reclaim/FINDINGS.md`.

private MPROTECT85_BYTES     = 64 * 1024
private MPROTECT85_SKIP_MARK = "mprotect85: the re-arm ran inside the stop, skipped"

private def mprotect85_page(addr : UInt64) : UInt64
  addr & ~(Gcry::Platform::PAGE - 1)
end

private def mprotect85_page_dirty?(page : UInt64) : Bool
  dirty = false
  Gcry::Platform.each_mprotect_dirty_page { |p| dirty = true if p == page }
  dirty
end

private def mprotect85_say(line : String) : Nil
  STDOUT.puts line
  STDOUT.flush
end

# A flag one thread sets and another waits on. A class, so every holder
# shares the one value: an `Atomic` is a struct, and passing one copies it.
# The value lives outside the GC heap: the hooks set flags inside the SEGV
# handler, where a write to a heap page the barrier has protected would fault
# with SIGSEGV blocked, and the kernel kills the process for that.
private class Mprotect85Flag
  @cell : Int32* = LibC.malloc(sizeof(Int32)).as(Int32*)

  def initialize
    @cell.value = 0
  end

  def set : Nil
    Atomic::Ops.store(@cell, 1, LLVM::AtomicOrdering::SequentiallyConsistent, true)
  end

  def set? : Bool
    Atomic::Ops.load(@cell, LLVM::AtomicOrdering::SequentiallyConsistent, true) != 0
  end

  # Spins until set or *seconds* pass; true if it was set. Allocates
  # nothing, so the hooks call it inside the SEGV handler.
  def await(seconds : Int32) : Bool
    deadline = Time.instant + seconds.seconds
    until set?
      return false if Time.instant >= deadline
      Intrinsics.pause
    end
    true
  end
end

# A thread that writes one byte at an address once `go` is set, and sets
# `done` when the write has gone through.
private class Mprotect85Writer
  getter go = Mprotect85Flag.new
  getter done = Mprotect85Flag.new

  def initialize(addr : UInt64)
    @thread = Thread.new do
      if @go.await(60)
        Pointer(UInt8).new(addr).value = 1_u8
        @done.set
      end
    end
  end

  def join : Nil
    @thread.join
  end
end

# Arms the barrier over a fresh block the way the lazy path does, after the
# sweep. Returns the block; its pages are read-only now.
private def mprotect85_arm(heap : Gcry::Heap) : UInt8*
  # No collection but the ones asked for: an allocation-driven slice would
  # open a sliced cycle whose arm and abort move the barrier between the
  # steps below.
  heap.gc_threshold = UInt64::MAX
  heap.lazy_sweep = true
  heap.incremental_auto = true
  heap.prefer_mprotect_barrier = true
  block = GC.malloc_atomic(MPROTECT85_BYTES).as(UInt8*)
  block.clear(MPROTECT85_BYTES)
  GC.collect
  heap.barrier_backend_name.should eq("mprotect")
  block
end

# Collects once. Right after the world restarts, before the lazy sweep and
# the re-arm, the writer is let go and its fault parks in whichever hook the
# caller set, which sets *parked*; the collection goes on with the handler
# inside. True if the re-arm ran after the handler parked (the generation
# moved), false if it ran inside the stop.
private def mprotect85_collect_with_parked(heap : Gcry::Heap, writer : Mprotect85Writer,
                                           parked : Mprotect85Flag) : Bool
  triggered = Mprotect85Flag.new
  gen_at_park = Atomic(UInt64).new(0_u64)
  heap.post_stw_hook = ->(stage : Symbol) do
    if stage == :after_start_world && !triggered.set?
      triggered.set
      writer.go.set
      parked.await(10)
      gen_at_park.set(Gcry::Platform.mprotect_generation)
    end
    nil
  end
  GC.collect
  heap.post_stw_hook = nil
  fail "the writer's fault never reached the hook" unless parked.set?
  Gcry::Platform.mprotect_generation != gen_at_park.get
end

private def mprotect85_skip(writer : Mprotect85Writer, release : Mprotect85Flag) : Nil
  mprotect85_say(MPROTECT85_SKIP_MARK)
  release.set
  writer.join
end

# *held*: the handler parked after reading the card state.
private def mprotect85_held(arm : String) : Nil
  heap = Gcry.default_heap
  block = mprotect85_arm(heap)
  target = mprotect85_page(block.address + MPROTECT85_BYTES // 2)
  writer = Mprotect85Writer.new(target)
  parked = Mprotect85Flag.new
  release = Mprotect85Flag.new
  Gcry::Platform.mprotect_fault_hook = ->(addr : UInt64) do
    if mprotect85_page(addr) == target && !parked.set?
      parked.set
      release.await(20)
    end
    nil
  end
  unless mprotect85_collect_with_parked(heap, writer, parked)
    mprotect85_skip(writer, release)
    return
  end
  unsafe = Gcry::Platform.mprotect_unsafe_frees
  retired = Gcry::Platform.mprotect_retired_count
  mprotect85_say("mprotect85 held: re-armed with the handler inside; freed under it #{unsafe}, retired and kept #{retired}")
  if arm == "control-free"
    unsafe.should be > 0
    mprotect85_say("mprotect85: control freed the cards the handler holds")
    # Resumed, the handler would read the freed cards: leave first.
    LibC._exit(0)
  end
  unsafe.should eq(0)
  retired.should be > 0
  # The forwarding control dies in here: its handler uninstalls the barrier
  # and the retried write faults on the re-armed page into Crystal's handler.
  release.set
  writer.join
  Gcry::Platform.mprotect_fault_hook = nil
  writer.done.set?.should be_true
  Gcry::Platform.mprotect_barrier_enabled?.should be_true
  # The write was retried and claimed under the new cards.
  mprotect85_page_dirty?(target).should be_true
  # No handler is inside now, so the next swap frees what was kept.
  GC.collect
  Gcry::Platform.mprotect_retired_count.should eq(0)
  block.value.should eq(0_u8)
end

# *stale*: the handler parked after claiming the page in the old cards.
private def mprotect85_stale(arm : String) : Nil
  heap = Gcry.default_heap
  block = mprotect85_arm(heap)
  target = mprotect85_page(block.address + MPROTECT85_BYTES // 2)
  writer = Mprotect85Writer.new(target)
  parked = Mprotect85Flag.new
  release = Mprotect85Flag.new
  Gcry::Platform.mprotect_claim_hook = ->(addr : UInt64) do
    if mprotect85_page(addr) == target && !parked.set?
      parked.set
      release.await(20)
    end
    nil
  end
  unless mprotect85_collect_with_parked(heap, writer, parked)
    mprotect85_skip(writer, release)
    return
  end
  release.set
  writer.join
  Gcry::Platform.mprotect_claim_hook = nil
  writer.done.set?.should be_true
  # The page is writable now; written again, the current cards must say so.
  Pointer(UInt8).new(target + 8).value = 2_u8
  dirty = mprotect85_page_dirty?(target)
  mprotect85_say("mprotect85 stale: re-armed with the handler inside; the current cards record the page: #{dirty}")
  if arm == "control-recheck"
    dirty.should be_false
    mprotect85_say("mprotect85: control lost the write")
  else
    dirty.should be_true
  end
  block.value.should eq(0_u8)
end

# *straggler*: the handler parked on entry and let go by the re-arm between
# the page's protected bit and its `mprotect`.
private def mprotect85_straggler(arm : String) : Nil
  heap = Gcry.default_heap
  block = mprotect85_arm(heap)
  target = mprotect85_page(block.address + MPROTECT85_BYTES // 2)
  writer = Mprotect85Writer.new(target)
  parked = Mprotect85Flag.new
  release = Mprotect85Flag.new
  Gcry::Platform.mprotect_entry_hook = ->(addr : UInt64) do
    if mprotect85_page(addr) == target && !parked.set?
      parked.set
      release.await(20)
    end
    nil
  end
  # On the collector, in the re-arm: the block's protected bits are set and
  # its pages are not read-only yet. Let the parked handler go and wait for
  # its write to finish before the pages are protected.
  Gcry::Platform.mprotect_protect_hook = ->(lo : UInt64, hi : UInt64) do
    if parked.set? && !release.set? && lo <= target && target < hi
      release.set
      writer.done.await(10)
    end
    nil
  end
  rearmed = mprotect85_collect_with_parked(heap, writer, parked)
  Gcry::Platform.mprotect_protect_hook = nil
  unless rearmed
    mprotect85_skip(writer, release)
    return
  end
  writer.join
  Gcry::Platform.mprotect_entry_hook = nil
  fail "the re-arm never reached the block" unless release.set?
  writer.done.set?.should be_true
  # The handler claimed the page under the new cards.
  mprotect85_page_dirty?(target).should be_true
  second = Mprotect85Writer.new(target + 8)
  second.go.set
  through = second.done.await(5)
  mprotect85_say("mprotect85 straggler: re-armed around the handler; the next write went through: #{through}")
  if arm == "control-unprotect"
    through.should be_false
    mprotect85_say("mprotect85: control left the next writer faulting")
    # That writer never finishes.
    LibC._exit(0)
  end
  through.should be_true
  second.join
  block.value.should eq(0_u8)
end

# Runs one child; kills it past *seconds*. Returns its status and output.
private def mprotect85_child(arm : String, seconds : Int32 = 90) : {Process::Status, String}
  captured = IO::Memory.new
  child = Process.new(Process.executable_path.not_nil!, ["-e", "mprotect-rearm-running-handler child #{arm}"],
    env: {"GCRY_MPROTECT85_CHILD" => arm}, output: captured, error: captured)
  deadline = Time.instant + seconds.seconds
  until child.terminated? || Time.instant >= deadline
    sleep 100.milliseconds
  end
  child.terminate(graceful: false) unless child.terminated?
  status = child.wait
  {status, captured.to_s}
end

private def mprotect85_expect_pass(arm : String, mark : String?) : Nil
  status, text = mprotect85_child(arm)
  fail "child #{arm} #{status.inspect}:\n#{text}" unless status.success?
  text.should contain("1 examples, 0 failures")
  if mark && !text.includes?(MPROTECT85_SKIP_MARK)
    text.should contain(mark)
  end
end

describe "Regression: an mprotect re-arm with the world running and a fault handler inside" do
  {% if flag?(:linux) %}
    it "held: fixed arm in a process of its own" do
      mprotect85_expect_pass("held-fixed", "mprotect85 held: re-armed with the handler inside; freed under it 0")
    end

    it "held: control arm frees the cards under the handler" do
      status, text = mprotect85_child("held-control-free")
      fail "child #{status.inspect}:\n#{text}" unless status.success?
      text.should contain("mprotect85: control freed the cards the handler holds") unless text.includes?(MPROTECT85_SKIP_MARK)
    end

    # The handler forwards the retried write to Crystal's handler, which
    # prints and exits with the signal number.
    it "held: control arm forwards the fault and dies" do
      status, text = mprotect85_child("held-control-retry")
      next if status.success? && text.includes?(MPROTECT85_SKIP_MARK)
      text.should contain("mprotect85 held: re-armed with the handler inside")
      fail "the control arm survived:\n#{text}" if status.success?
      text.should contain("Invalid memory access")
    end

    it "stale: fixed arm in a process of its own" do
      mprotect85_expect_pass("stale-fixed", "the current cards record the page: true")
    end

    it "stale: control arm loses the write" do
      mprotect85_expect_pass("stale-control-recheck", "mprotect85: control lost the write")
    end

    it "straggler: fixed arm in a process of its own" do
      mprotect85_expect_pass("straggler-fixed", "the next write went through: true")
    end

    it "straggler: control arm leaves the next writer faulting" do
      status, text = mprotect85_child("straggler-control-unprotect")
      fail "child #{status.inspect}:\n#{text}" unless status.success?
      text.should contain("mprotect85: control left the next writer faulting") unless text.includes?(MPROTECT85_SKIP_MARK)
    end

    it "mprotect-rearm-running-handler child held-fixed" do
      next unless ENV["GCRY_MPROTECT85_CHILD"]? == "held-fixed"
      mprotect85_held("fixed")
    end

    it "mprotect-rearm-running-handler child held-control-free" do
      next unless ENV["GCRY_MPROTECT85_CHILD"]? == "held-control-free"
      Gcry::Platform.mprotect_defer_free = false
      mprotect85_held("control-free")
    end

    it "mprotect-rearm-running-handler child held-control-retry" do
      next unless ENV["GCRY_MPROTECT85_CHILD"]? == "held-control-retry"
      Gcry::Platform.mprotect_retry_unclaimed = false
      mprotect85_held("control-retry")
    end

    it "mprotect-rearm-running-handler child stale-fixed" do
      next unless ENV["GCRY_MPROTECT85_CHILD"]? == "stale-fixed"
      mprotect85_stale("fixed")
    end

    it "mprotect-rearm-running-handler child stale-control-recheck" do
      next unless ENV["GCRY_MPROTECT85_CHILD"]? == "stale-control-recheck"
      Gcry::Platform.mprotect_revalidate = false
      mprotect85_stale("control-recheck")
    end

    it "mprotect-rearm-running-handler child straggler-fixed" do
      next unless ENV["GCRY_MPROTECT85_CHILD"]? == "straggler-fixed"
      mprotect85_straggler("fixed")
    end

    it "mprotect-rearm-running-handler child straggler-control-unprotect" do
      next unless ENV["GCRY_MPROTECT85_CHILD"]? == "straggler-control-unprotect"
      Gcry::Platform.mprotect_claim_unprotects = false
      mprotect85_straggler("control-unprotect")
    end
  {% end %}
end
