require "./spec_helper"

# Reach the shared fallback set and one slot's in-flight word from a spec.
class Gcry::Heap
  def in_flight_for_spec(slot : Int32) : Void*
    Gcry::CursorSet.slot(cursor_set, slot).value.in_flight
  end

  def publish_in_flight_for_spec(slot : Int32, value : Void*) : Nil
    Gcry::CursorSet.slot(cursor_set, slot).value.in_flight = value
  end

  def clear_in_flight_for_spec(index : Int32, user : Void*) : Nil
    clear_bitmap_alloc_in_flight(index, 0_u32, user)
  end
end

# `clear_bitmap_alloc_in_flight` runs after the class lock is released. On a
# thread's own set that is harmless; on the fallback set every thread past
# the 64th shares, the slot may by then hold a peer's sentinel or the address
# the peer just published under the lock, and a plain null store would erase
# that peer's only root before its frame holds the block. The clear must
# compare against its own pointer.
describe "in-flight clear on a shared cursor slot" do
  it "leaves a peer's publication in place and clears only its own" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      index = Gcry::SizeClasses.index_of(48_u32)
      mine = heap.malloc(48)
      heap.in_flight_for_spec(index).should eq(Pointer(Void).null)

      # A peer sharing the slot is mid-allocation: sentinel, then its block.
      heap.publish_in_flight_for_spec(index, Gcry::CursorSet.sentinel)
      heap.clear_in_flight_for_spec(index, mine)
      heap.in_flight_for_spec(index).should eq(Gcry::CursorSet.sentinel)

      peer = heap.malloc(48)
      heap.publish_in_flight_for_spec(index, peer)
      heap.clear_in_flight_for_spec(index, mine)
      heap.in_flight_for_spec(index).should eq(peer)

      # The peer's own clear, with the peer's pointer, does drop it.
      heap.clear_in_flight_for_spec(index, peer)
      heap.in_flight_for_spec(index).should eq(Pointer(Void).null)
    ensure
      heap.destroy
    end
  end
end
