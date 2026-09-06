require "./spec_helper"

class Gcry::Heap
  def hold_cursor_lock_for_spec : Nil
    @cursor_lock.lock
  end

  def reset_cursor_sets_after_fork_for_spec : Nil
    reset_cursor_sets_after_fork
  end

  def cursor_set_states_for_spec : Array(UInt8)
    states = [] of UInt8
    i = 0
    while i < @cursor_set_count
      states << @cursor_sets[i].value.state
      i += 1
    end
    states
  end
end

# What `after_fork_child_reinit` owes the cursor sets. Only the forking
# thread survives a fork: a `@cursor_lock` another thread held is held by
# nobody, and every other thread's set carries an owner key no thread will
# present again. The child must rebuild the lock and let the next
# stop-the-world free those slots.
describe "cursor sets in a fork child" do
  it "rebuilds a lock the dead thread held and retires the dead threads' sets" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.malloc(48) # the survivor's set

      # A peer with a live set, parked so its exit destructor never runs -
      # the state a fork leaves every non-forking thread's set in.
      parked = Atomic(Int32).new(0)
      peer = Thread.new do
        heap.malloc(48)
        while parked.get == 0
          Intrinsics.pause
        end
      end
      while heap.cursor_set_count < 2
        Intrinsics.pause
      end
      heap.cursor_set_states_for_spec.should eq([Gcry::CursorSet::STATE_LIVE, Gcry::CursorSet::STATE_LIVE])

      # The fork happened while that peer held the cursor lock.
      heap.hold_cursor_lock_for_spec
      heap.reset_cursor_sets_after_fork_for_spec

      # A new thread's first allocation takes the lock; with a stale one it
      # would spin here forever.
      t = Thread.new { heap.malloc(48) }
      t.join
      heap.cursor_set_states_for_spec[1].should eq(Gcry::CursorSet::STATE_EXITING)

      # The stop-the-world frees the dead owner's slot, so the next thread
      # reuses it instead of growing the table.
      heap.collect(scan_stack: false)
      heap.cursor_set_states_for_spec[1].should eq(Gcry::CursorSet::STATE_FREE)
      count = heap.cursor_set_count
      t = Thread.new { heap.malloc(48) }
      t.join
      heap.cursor_set_count.should eq(count)

      parked.set(1)
      peer.join
    ensure
      heap.destroy
    end
  end
end
