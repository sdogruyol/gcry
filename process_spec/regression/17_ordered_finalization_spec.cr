require "../../src/gcry"
require "spec"
require "weak_ref"

# Readiness M4: finalization order.
#
# Crystal registers every finalizer through Boehm's
# `GC_register_finalizer_ignore_self` (stdlib `gc/boehm.cr`), and that call is
# *ordered*: when an unreachable finalizable object A reaches another one, B,
# only A is finalized; B waits for a later collection, so A's finalizer may
# still use B. That is what lets a wrapper flush into the descriptor it wraps,
# or `OpenSSL::SSL::Socket` shut down over the `TCPSocket` under it. gcry
# queued every unreachable finalizable in one pass, so all of them ran after
# the same collection in table order: the 8-chain below came back as
# `[7, 6, 5, 4, 3, 2, 1, 8]`, and the cycle was finalized (2026-10-05).
#
# The objects are built on a spawned fiber, which zeroes the stack its builder
# used before it finishes. Without the scrub, a stale copy of a node's address
# in those dead frames was still read as a root from a parked fiber stack
# (`GCRY_LIVE_ATTR` counted it under `parked`), and the chain never started.

private module FinalizeLog
  CAP = 32

  # Plain heap buffers rooted by class variables. Recording must not allocate:
  # it runs inside `run_pending`, right after the collection it reports.
  @@ids = Pointer(Int32).malloc(CAP)
  @@collections = Pointer(UInt64).malloc(CAP)
  @@intact = Pointer(Bool).malloc(CAP)
  @@weak_cleared = Pointer(Bool).malloc(CAP)
  @@count = 0
  class_property weak : WeakRef(OrderedNode)? = nil

  def self.reset : Nil
    @@count = 0
    @@weak = nil
  end

  def self.count : Int32
    @@count
  end

  def self.record(id : Int32, intact : Bool) : Nil
    return if @@count >= CAP
    @@ids[@@count] = id
    @@collections[@@count] = Gcry.default_heap.collections
    @@intact[@@count] = intact
    @@weak_cleared[@@count] = @@weak.try(&.value).nil?
    @@count += 1
  end

  def self.ids : Array(Int32)
    Array(Int32).new(@@count) { |i| @@ids[i] }
  end

  def self.collections : Array(UInt64)
    Array(UInt64).new(@@count) { |i| @@collections[i] }
  end

  def self.intact : Array(Bool)
    Array(Bool).new(@@count) { |i| @@intact[i] }
  end

  def self.weak_cleared : Array(Bool)
    Array(Bool).new(@@count) { |i| @@weak_cleared[i] }
  end
end

private class OrderedNode
  PAYLOAD = 64

  getter id : Int32
  property peer : OrderedNode?
  getter? finalized = false
  # What `XML::Document` does (`@document = self`): a pointer to itself must
  # not count as reaching a finalizable object, or it is never finalized.
  @me : OrderedNode?

  def initialize(@id : Int32, @peer : OrderedNode? = nil, self_pointer : Bool = false)
    @payload = Pointer(UInt8).malloc(PAYLOAD) { |i| pattern(i) }
    @me = self if self_pointer
  end

  private def pattern(i : Int32) : UInt8
    (@id &* 31 &+ i).to_u8!
  end

  def intact? : Bool
    PAYLOAD.times { |i| return false unless @payload[i] == pattern(i) }
    true
  end

  # Intact means: this object's memory still holds what was written into it,
  # and the object it holds, if any, has not been finalized yet and is intact
  # too — the guarantee ordered finalization gives a finalizer.
  def finalize
    peer = @peer
    ok = intact? && (peer.nil? || (!peer.finalized? && peer.intact?))
    @finalized = true
    FinalizeLog.record(@id, ok)
  end
end

# Builds 1 -> 2 -> ... -> n (node i holds node i+1) and drops it.
@[NoInline]
private def ordered_chain(n : Int32, weak_to_second : Bool) : Nil
  head = nil.as(OrderedNode?)
  n.downto(1) do |id|
    head = OrderedNode.new(id, head)
    FinalizeLog.weak = WeakRef.new(head.not_nil!) if weak_to_second && id == 2
  end
end

# Builds a <-> b, both finalizable, and keeps a's address where the
# conservative scan cannot read it as a pointer.
private HIDE = 0x5a5a_5a5a_5a5a_5a5a_u64

@[NoInline]
private def ordered_cycle(holder : Pointer(UInt64)) : Nil
  a = OrderedNode.new(1)
  b = OrderedNode.new(2, a)
  a.peer = b
  holder.value = a.object_id ^ HIDE
end

# Reaches the cycle through the hidden address, reports whether both members
# are still intact, and breaks it (a stops holding b; b still holds a).
@[NoInline]
private def break_ordered_cycle(holder : Pointer(UInt64), intact : Pointer(Bool)) : Nil
  a = Pointer(Void).new(holder.value ^ HIDE).as(OrderedNode)
  peer = a.peer
  intact.value = a.intact? && !peer.nil? && peer.intact?
  a.peer = nil
  holder.value = 0_u64
end

@[NoInline]
private def ordered_self_pointer : Nil
  OrderedNode.new(1, self_pointer: true)
end

# Zeroes the frames a returned builder left below this one.
@[NoInline]
private def scrub_builder_frames : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

private def on_finished_fiber(&block : ->) : Nil
  done = Channel(Nil).new
  spawn do
    block.call
    scrub_builder_frames
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

private def collect_until(count : Int32, limit : Int32) : Nil
  limit.times do
    break if FinalizeLog.count >= count
    GC.collect
  end
end

describe "Regression: ordered finalization (readiness M4)" do
  it "runs the holder's finalizer first and the held object's in a later collection, intact" do
    FinalizeLog.reset
    on_finished_fiber { ordered_chain(2, weak_to_second: true) }
    collect_until(2, 20)

    FinalizeLog.ids.should eq([1, 2])
    gcs = FinalizeLog.collections
    gcs[0].should be < gcs[1]
    FinalizeLog.intact.should eq([true, true])
    # Boehm clears a short disappearing link (`WeakRef`) before it marks from
    # finalizable objects: B is only reachable through A, so the reference to
    # it is gone by the time A's finalizer runs, though B itself is intact.
    FinalizeLog.weak_cleared[0].should be_true
  ensure
    FinalizeLog.reset
  end

  it "finalizes a chain of 8 strictly in order, one link per collection" do
    FinalizeLog.reset
    on_finished_fiber { ordered_chain(8, weak_to_second: false) }
    collect_until(8, 40)

    FinalizeLog.ids.should eq((1..8).to_a)
    gcs = FinalizeLog.collections
    gcs.each_cons_pair { |earlier, later| earlier.should be < later }
    FinalizeLog.intact.all?.should be_true
  ensure
    FinalizeLog.reset
  end

  it "finalizes an object that points at itself" do
    FinalizeLog.reset
    on_finished_fiber { ordered_self_pointer }
    collect_until(1, 10)

    FinalizeLog.ids.should eq([1])
    FinalizeLog.intact.should eq([true])
  ensure
    FinalizeLog.reset
  end

  it "keeps a cycle of finalizable objects allocated and unfinalized, reports it, and orders it once broken" do
    FinalizeLog.reset
    heap = Gcry.default_heap
    holder = Pointer(UInt64).malloc(1)
    cycles_before = heap.finalization_cycles
    on_finished_fiber { ordered_cycle(holder) }
    4.times { GC.collect }

    # Boehm never finalizes a cycle under ordered finalization; neither may
    # this, and it must not reclaim the objects either while they are still
    # registered. It says so rather than leaking in silence.
    FinalizeLog.count.should eq(0)
    heap.finalization_cycles.should be > cycles_before

    intact = Pointer(Bool).malloc(1)
    on_finished_fiber { break_ordered_cycle(holder, intact) }
    intact.value.should be_true
    collect_until(2, 20)

    FinalizeLog.ids.should eq([2, 1])
    gcs = FinalizeLog.collections
    gcs[0].should be < gcs[1]
    FinalizeLog.intact.should eq([true, true])
  ensure
    FinalizeLog.reset
  end
end
