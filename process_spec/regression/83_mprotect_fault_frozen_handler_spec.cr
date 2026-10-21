require "../../src/gcry"
require "spec"

# The mprotect page barrier's SEGV handler (`Platform.mprotect_fault`) reads
# the card state, sets the faulting page's dirty bit in it and makes the page
# writable. It ran with the stop's suspend signal deliverable, so a stop could
# freeze it in between, and a stop whose sweep runs inside it re-arms the
# barrier there (`arm_page_barrier_after_major`): the card state the handler
# had read was freed (`disarm_mprotect_barrier` retires it,
# `mprotect_set_heap_range` frees what was just retired) and the page was
# protected again under fresh cards with its dirty bit clear. The handler
# resumed, wrote its bit into freed memory and made the page writable behind
# the new cards' back: that write and every later one to the page until the
# next arm reached no dirty bit, which is an old→young or incremental edge
# the barrier exists to report, lost. The handler now holds the suspend
# signal off until it returns (`install_mprotect_barrier`).
#
# The interleaving is forced: `mprotect_fault_hook` parks the handler of one
# thread's write to a protected page, the main thread collects with the sweep
# — and so the re-arm — inside the stop, and then writes the same page and
# asks whether the current cards saw it. The control arm
# (`mprotect_block_suspend = false`, the code before) must lose that write on
# the same construction, or the fixed arm passes on nothing. Each arm runs in
# a process of its own: the control arm's handler writes into freed memory.
# Linux only, the one platform with the mprotect barrier.
# `bench/log/linux/2026-10-22-in-stop-sweep-audit/FINDINGS.md`.

private MPROTECT83_BYTES = 64 * 1024
private MPROTECT83_SPAN  = 64 * 1024 * 1024

private def mprotect83_page_dirty?(page : UInt64) : Bool
  dirty = false
  Gcry::Platform.each_mprotect_dirty_page { |p| dirty = true if p == page }
  dirty
end

# Arm the barrier over a block, park one thread's write to it in the
# handler, collect, finish the write, then write the page again from here.
# Returns the stops that ended while the handler was parked and whether the
# current cards record the second write.
private def mprotect83_window(heap : Gcry::Heap) : {Int32, Bool}
  heap.lazy_sweep = false
  heap.incremental_auto = true
  heap.prefer_mprotect_barrier = true
  block = GC.malloc_atomic(MPROTECT83_BYTES).as(UInt8*)
  block.clear(MPROTECT83_BYTES)
  # Arms the barrier, inside the stop, over every old chunk: the block's
  # pages are read-only now.
  GC.collect
  heap.barrier_backend_name.should eq("mprotect")
  page_size = Gcry::Platform::PAGE
  target = ((block.address + MPROTECT83_BYTES // 2) & ~(page_size - 1))

  starts = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  entered_at = Atomic(Int32).new(0)
  # `starts` when the handler left the hook, -1 while it is still in it.
  left_at = Atomic(Int32).new(-1)
  go = Atomic(Int32).new(0)
  heap.post_stw_hook = ->(stage : Symbol) do
    starts.add(1) if stage == :after_start_world
    nil
  end
  # In the SEGV handler of the parked thread: allocates nothing. Parks until
  # a stop has ended and the main thread says go. With the suspend signal
  # held off no stop can end while it spins, so it gives up after a while
  # and the stop, which has been waiting for it, goes ahead.
  Gcry::Platform.mprotect_fault_hook = ->(addr : UInt64) do
    if (addr & ~(page_size - 1)) == target && parked.get == 0
      entered = starts.get
      entered_at.set(entered)
      parked.set(1)
      deadline = Time.instant + 2.seconds
      while (starts.get == entered || go.get == 0) && Time.instant < deadline
        Intrinsics.pause
      end
      left_at.set(starts.get)
    end
    nil
  end

  thread = Thread.new do
    Pointer(UInt8).new(target).value = 1_u8
  end
  deadline = Time.instant + 10.seconds
  until parked.get == 1 || Time.instant >= deadline
    sleep 1.millisecond
  end
  fail "the thread's write never faulted on the block" unless parked.get == 1
  # Widen the heap span before the re-arm, so the card state it allocates
  # is a different size from the one the parked handler holds, and malloc
  # does not hand the freed block straight back as the new state: that
  # reuse would put the stale handler's bits into the current cards by
  # accident (the first control runs read the write as recorded).
  wide = GC.malloc_atomic(MPROTECT83_SPAN)
  GC.collect
  wide.null?.should be_false
  # Stops that ended while the handler was parked, read before it resumes.
  left = left_at.get
  inside = (left < 0 ? starts.get : left) - entered_at.get
  STDOUT.puts "mprotect83: stops that ended inside the handler: #{inside}"
  STDOUT.flush
  go.set(1)
  thread.join
  Gcry::Platform.mprotect_fault_hook = nil
  heap.post_stw_hook = nil

  # The page the stop re-armed, written again: the current cards must say so.
  Pointer(UInt8).new(target + 8).value = 2_u8
  {inside, mprotect83_page_dirty?(target)}
end

describe "Regression: no stop freezes the mprotect barrier's fault handler" do
  {% if flag?(:linux) %}
    it "fixed arm in a process of its own" do
      captured = IO::Memory.new
      status = Process.run(Process.executable_path.not_nil!, ["-e", "mprotect-fault-frozen-handler child fixed"],
        env: {"GCRY_FROZEN_MPROTECT_CHILD" => "fixed"}, output: captured, error: captured)
      fail "child #{status.inspect}:\n#{captured}" unless status.success?
      captured.to_s.should contain("mprotect83: stops that ended inside the handler: 0")
      captured.to_s.should contain("1 examples, 0 failures")
    end

    # A stop ends while the handler is parked, and when it resumes the
    # handler either writes into card state the re-arm unmapped — a SIGSEGV
    # inside the SIGSEGV handler, which kills the process — or, where malloc
    # kept the block mapped, the write that follows is in no dirty bit.
    it "control arm in a process of its own" do
      captured = IO::Memory.new
      status = Process.run(Process.executable_path.not_nil!, ["-e", "mprotect-fault-frozen-handler child control"],
        env: {"GCRY_FROZEN_MPROTECT_CHILD" => "control"}, output: captured, error: captured)
      text = captured.to_s
      text.should contain("mprotect83: stops that ended inside the handler: 1")
      killed = status.exit_signal? == Signal::SEGV
      fail "control child #{status.inspect}:\n#{text}" unless killed || text.includes?("mprotect83: control lost the write")
    end

    it "mprotect-fault-frozen-handler child fixed" do
      next unless ENV["GCRY_FROZEN_MPROTECT_CHILD"]? == "fixed"
      inside, dirty = mprotect83_window(Gcry.default_heap)
      # The stop waited for the handler to return.
      inside.should eq(0)
      dirty.should be_true
    end

    it "mprotect-fault-frozen-handler child control" do
      next unless ENV["GCRY_FROZEN_MPROTECT_CHILD"]? == "control"
      # Read when the handler is installed, at the first arm.
      Gcry::Platform.mprotect_block_suspend = false
      inside, dirty = mprotect83_window(Gcry.default_heap)
      inside.should be > 0
      # The page is writable under cards that call it protected and clean.
      dirty.should be_false
      STDOUT.puts "mprotect83: control lost the write"
      STDOUT.flush
      # The handler wrote into freed card state; leave before malloc notices.
      LibC._exit(0)
    end
  {% end %}
end
