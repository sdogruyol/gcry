require "../../src/gcry"
require "spec"

# An object queued for finalization stays alive, with everything it reaches,
# until its finalizer has run — whatever collections come first. Boehm keeps
# the queue (`finalize_now`) in a root it pushes every collection
# (`GC_push_finalizer_structures`), with the object pointers revealed.
#
# Until 2026-10-06 gcry resurrected a queued object only in the collection that
# queued it; the queue itself was libc memory nothing marked. A second
# collection before `run_pending` found the object unmarked and swept it, and
# with it the ordering: what the object held was no longer held, so a
# finalizable it held was queued in that second collection, ahead of it, and
# the holder's finalizer ran last, on a swept block, finding what it holds
# already finalized. The idle collector (src/gcry/idle_release.cr) is one
# source of such a second collection — its cycles leave finalizers queued for
# a mutator — and another thread's collection is the other.
#
# A held node can be kept by a stale word in a live frame (17's header), so an
# attempt in which the holder is never finalized is retried; every attempt must
# keep the order, and one must finish.

private module PendingRootLog
  CAP = 8
  @@ids = Pointer(Int32).malloc(CAP)
  @@intact = Pointer(Bool).malloc(CAP)
  @@count = 0
  @@generation = 0

  def self.reset : Nil
    @@count = 0
    @@generation += 1
  end

  def self.generation : Int32
    @@generation
  end

  def self.count : Int32
    @@count
  end

  # Allocation-free: runs inside `run_pending`.
  def self.record(id : Int32, intact : Bool, generation : Int32) : Nil
    return if generation != @@generation || @@count >= CAP
    @@ids[@@count] = id
    @@intact[@@count] = intact
    @@count += 1
  end

  def self.ids : Array(Int32)
    Array(Int32).new(@@count) { |i| @@ids[i] }
  end

  def self.intact : Array(Bool)
    Array(Bool).new(@@count) { |i| @@intact[i] }
  end
end

private class PendingRootNode
  PAYLOAD = 64

  getter? finalized = false
  @generation : Int32 = PendingRootLog.generation

  def initialize(@id : Int32, @peer : PendingRootNode? = nil)
    @payload = Pointer(UInt8).malloc(PAYLOAD) { |i| pattern(i) }
  end

  private def pattern(i : Int32) : UInt8
    (@id &* 47 &+ i).to_u8!
  end

  def intact? : Bool
    PAYLOAD.times { |i| return false unless @payload[i] == pattern(i) }
    true
  end

  # Intact: this object still holds what was written into it, and what it
  # holds has not been finalized and is intact too.
  def finalize
    peer = @peer
    ok = intact? && (peer.nil? || (!peer.finalized? && peer.intact?))
    @finalized = true
    PendingRootLog.record(@id, ok, @generation)
  end
end

@[NoInline]
private def pending_root_pair : Nil
  PendingRootNode.new(1, PendingRootNode.new(2))
end

@[NoInline]
private def pending_root_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

private def pending_root_on_fiber(&block : ->) : Nil
  done = Channel(Nil).new
  spawn do
    block.call
    pending_root_scrub
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

describe "Regression: queued finalizers are roots until they run" do
  it "keeps a queued holder and what it holds through further collections, and finalizes in order" do
    heap = Gcry.default_heap
    finished = 3.times.any? do
      PendingRootLog.reset
      pending_root_on_fiber { pending_root_pair }

      # Idle collections queue the holder and leave it queued; the second
      # finds it, and the node it holds, waiting.
      heap.idle_collect
      heap.idle_collect
      heap.idle_collect
      PendingRootLog.count.should eq(0)

      10.times do
        break if PendingRootLog.count >= 2
        GC.collect
      end
      ids = PendingRootLog.ids
      ids.should eq([1, 2][0, ids.size])
      PendingRootLog.intact.all?.should be_true
      ids.size == 2
    end
    finished.should be_true
  ensure
    PendingRootLog.reset
  end
end
