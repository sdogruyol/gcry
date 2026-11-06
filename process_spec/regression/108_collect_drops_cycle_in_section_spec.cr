require "../../src/gcry"
require "spec"

# A full collection (`collect`, and `minor_collect` the same way) drops an
# open incremental cycle — `abort_incremental`: `@inc_active` false, the
# mark stack cleared, the barrier backend `None`. Until 2026-11-07 it did so
# before queueing for the collection section, so it could land while
# another thread's slice (`collect_a_little`) held the section, after the
# slice's re-read of `@inc_active` and before its stop. The slice then ran
# on with the cycle gone: no grey entry left, so its termination came at
# once; the backend `None`, so its scan read nothing and reported no lost
# barrier; the root rescan found the roots marked; and it swept every
# object only the cleared entries reached, though a root held them. The
# full collection queued behind it marked from the roots again, past the
# freed blocks. Now the cycle is dropped inside the section
# (`run_collection_body`), where no slice can be inside its own; Boehm
# finishes the cycle in progress under the allocation lock before a full
# collection (`GC_try_to_collect_inner`). The same early drop made
# regression 99's *race* control flaky.
#
# The construction, deterministic: automatic collection off, a chain of
# 20 000 blocks whose head is an explicit root (`Heap#add_root`), so the
# begin stop pushes it first and the drain, last in first out, reaches the
# chain after everything else. The stack below is scrubbed, then
# `collect_a_little(0)` begins the cycle (the head marked, the rest of the
# chain white, checked) and slices of 256 marks run until one entry is left
# on the mark stack: the chain's frontier, everything else black and the
# chain mostly white (checked). Dropping the cycle there costs the chain
# alone, not the runtime's own objects — a first version that dropped it
# with every root's entry grey died in the control's thread teardown. A
# second thread is released from inside the next slice —
# `Heap.inc_slice_locked_hook`, called after the re-read and before the
# slice sets `@collecting` — to call `collect`, and the hook waits until
# that collection holds a ticket for the section. Fixed: the cycle is still
# open when the slice goes on (checked), it marks the chain and the chain
# lives. Control (`Heap.collect_drops_cycle_in_section = false`, the code
# before): the collection dropped the cycle before it took its ticket, the
# slice goes on with it gone (checked) and sweeps the chain behind its
# frontier. Each arm in a process of its own. Linux only (the mprotect
# barrier, as regressions 99, 100 and 102 use); elsewhere, and when no
# cycle begins on it, the child prints the skip mark.
# `bench/log/linux/2026-11-06-reg99-race/FINDINGS.md`.

private COLLECT108_SKIP_MARK    = "collect108: this heap cannot reach the window, skipped"
private COLLECT108_FIXED_MARK   = "collect108: the chain a root holds lived through the slice"
private COLLECT108_CONTROL_MARK = "collect108: control swept the chain a root held"
private COLLECT108_CHAIN        = 20_000

private class Collect108Roots
  class_property head = Pointer(Void).null
  class_property sink = 0_u64
end

class Gcry::Heap
  # Whether the mark has reached the block at *pointer*; nil when it is not
  # an allocated block.
  def collect108_marked?(pointer : Void*) : Bool?
    header = find_object(pointer)
    return nil unless header
    heap_marked?(header)
  end
end

private module Collect108
  @@armed = Atomic(Int32).new(0)
  @@go = Atomic(Int32).new(0)
  # Whether the collection took a ticket while the slice held the section.
  @@queued = Atomic(Int32).new(0)
  # The cycle once it had: 0 not seen, 1 open, 2 dropped.
  @@after = Atomic(Int32).new(0)

  def self.arm : Nil
    @@armed.set(1)
  end

  def self.queued? : Bool
    @@queued.get == 1
  end

  def self.after : Int32
    @@after.get
  end

  # In the slice, holding the section. Allocates nothing.
  def self.locked : Nil
    return unless @@armed.swap(0) == 1
    heap = Gcry.default_heap
    queued = heap.@post_stw_next
    @@go.set(1)
    deadline = Gcry::Clock.monotonic_ns &+ 10_000_000_000_u64
    loop do
      Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, false)
      if heap.@post_stw_next != queued
        @@queued.set(1)
        break
      end
      break if Gcry::Clock.monotonic_ns > deadline
      Intrinsics.pause
    end
    Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, false)
    @@after.set(heap.@inc_active ? 1 : 2)
  end

  def self.collector : Nil
    until @@go.get == 1
      Intrinsics.pause
    end
    Gcry.default_heap.collect
  end
end

private def collect108_say(text : String) : Nil
  STDOUT.puts text
  STDOUT.flush
end

@[NoInline]
private def collect108_build(heap : Gcry::Heap) : Nil
  head = Pointer(Void).null
  COLLECT108_CHAIN.times do
    node = GC.malloc(16).as(Void**)
    node[0] = head
    head = node.as(Void*)
  end
  Collect108Roots.head = head
  heap.add_root(head)
end

# The begin stop scans this thread's stack from the collector's frames up;
# what `collect108_build`'s frames left there is zeroed first.
@[NoInline]
private def collect108_scrub_stack : Nil
  buf = uninitialized StaticArray(UInt64, 8192)
  words = buf.to_unsafe
  8192.times { |i| words[i] = 0_u64 }
  Collect108Roots.sink = words[0] &+ words[8191]
end

# Chain blocks from the head on, up to the first that is no allocated block.
private def collect108_alive(heap : Gcry::Heap) : Int32
  node = Collect108Roots.head
  count = 0
  while count < COLLECT108_CHAIN && !node.null? && heap.find_object(node)
    count += 1
    node = node.as(Void**)[0]
  end
  count
end

# Chain blocks behind the head the mark has not reached.
private def collect108_white(heap : Gcry::Heap) : Int32
  node = Collect108Roots.head.as(Void**)[0]
  white = 0
  until node.null?
    white += 1 if heap.collect108_marked?(node) == false
    node = node.as(Void**)[0]
  end
  white
end

private def collect108_child(fixed : Bool) : Nil
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    heap.disable
    heap.prefer_mprotect_barrier = true
    Gcry::Heap.collect_drops_cycle_in_section = fixed
    second = Thread.new { Collect108.collector }
    collect108_build(heap)
    collect108_scrub_stack
    heap.collect_a_little(0) && fail "the cycle finished in its first slice"
    unless heap.incremental_in_progress? && heap.barrier_backend_name == "mprotect"
      collect108_say("#{COLLECT108_SKIP_MARK}: no incremental cycle on the mprotect barrier")
      Collect108.arm
      Collect108.locked
      second.join
      return
    end
    heap.collect108_marked?(Collect108Roots.head).should be_true
    begun_white = collect108_white(heap)
    fail "the begin stop marked the whole chain: the window was not reached" if begun_white == 0
    slices = 0
    until heap.@mark_stack.size <= 1
      heap.collect_a_little(256) && fail "the cycle finished before the chain was reached"
      slices += 1
      fail "the mark stack did not come down to one entry in #{slices} slices" if slices > 100_000
    end
    entries = heap.@mark_stack.size
    white = collect108_white(heap)
    fail "the mark stack ran empty: the window was not reached" unless entries == 1
    fail "the drain marked the whole chain: the window was not reached" if white == 0
    Gcry::Heap.inc_slice_locked_hook = -> { Collect108.locked }
    Collect108.arm
    heap.collect_a_little(Int32::MAX)
    second.join
    Gcry::Heap.inc_slice_locked_hook = nil
    alive = collect108_alive(heap)
    after = Collect108.after
    collect108_say("collect108: #{begun_white} chain blocks white after the begin stop, #{white} after " \
                   "#{slices} slices left one entry; the cycle " \
                   "#{after == 1 ? "open" : after == 2 ? "dropped" : "not seen"} once the collection queued; " \
                   "#{alive} of #{COLLECT108_CHAIN} chain blocks alive")
    Collect108.queued?.should be_true
    if fixed
      after.should eq(1)
      alive.should eq(COLLECT108_CHAIN)
      collect108_say(COLLECT108_FIXED_MARK)
    else
      after.should eq(2)
      alive.should be < COLLECT108_CHAIN
      collect108_say(COLLECT108_CONTROL_MARK)
    end
  {% else %}
    collect108_say("#{COLLECT108_SKIP_MARK}: Linux only")
  {% end %}
end

# Runs one child; kills it past *seconds*. Returns its status and output.
private def collect108_run(arm : String, seconds : Int32 = 90) : {Process::Status, String}
  captured = IO::Memory.new
  env = {"GCRY_COLLECT108_CHILD" => arm} of String => String?
  # The control's full collection follows a sweep that freed blocks a root
  # still reaches.
  env["GCRY_DEBUG_INVARIANTS"] = nil if arm == "control"
  child = Process.new(Process.executable_path.not_nil!, ["-e", "collect108 child #{arm}"],
    env: env, output: captured, error: captured)
  deadline = Time.instant + seconds.seconds
  until child.terminated? || Time.instant >= deadline
    sleep 100.milliseconds
  end
  child.terminate(graceful: false) unless child.terminated?
  status = child.wait
  {status, captured.to_s}
end

describe "Regression: a full collection drops the incremental cycle inside the collection section" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      status, text = collect108_run(arm)
      fail "child #{arm} #{status.inspect}:\n#{text}" unless status.success?
      text.should contain("1 examples, 0 failures")
      unless text.includes?(COLLECT108_SKIP_MARK)
        text.should contain(arm == "fixed" ? COLLECT108_FIXED_MARK : COLLECT108_CONTROL_MARK)
      end
    end
  end

  it "collect108 child fixed" do
    next unless ENV["GCRY_COLLECT108_CHILD"]? == "fixed"
    collect108_child(fixed: true)
  end

  it "collect108 child control" do
    next unless ENV["GCRY_COLLECT108_CHILD"]? == "control"
    collect108_child(fixed: false)
  end
end
