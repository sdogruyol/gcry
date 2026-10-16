require "./spec_helper"

# Begin marking in the middle of a hit-path allocation. `cursor_advance_word`
# runs after the entry check and the sentinel store and before the block is
# handed out - the window a stop-the-world that starts an incremental cycle
# can land in - so flipping the flag there is that cycle's stop, minus the
# stop.
class Gcry::Heap
  property begin_marking_in_hit_path_for_spec = false

  protected def cursor_advance_word(s : Gcry::CursorSlot*, index : Int32) : UInt64
    if @begin_marking_in_hit_path_for_spec
      @begin_marking_in_hit_path_for_spec = false
      @incremental_marking = true
    end
    previous_def
  end

  def end_marking_for_spec : Nil
    @incremental_marking = false
  end

  def marked_for_spec?(user : Void*) : Bool
    marked_for_report?(Gcry::BlockHeader.from_user(user))
  end
end

# Every block handed out while a cycle is marking must be allocated black:
# the incremental cycle's finishing slice sweeps inside its own stopped
# world and rescans dirty pages, not stacks, so a white block held only in a
# frame is reclaimed live. The locked path marks at allocation; the hit
# path checked the flag once at entry, before the sentinel, and a thread
# frozen after that check completed its allocation white. Since 2026-10-17
# the word's claim, made inside the same window, is marked whole as well.
describe "hit-path allocation while marking begins" do
  it "marks the block a cycle started under" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.malloc(48) # locked path: fills the cursor's first word

      # Walk the word down until the next hit has to advance; that hit runs
      # with the flag flipped inside its window.
      heap.begin_marking_in_hit_path_for_spec = true
      advances = heap.cursor_word_advances
      under_marking = Pointer(Void).null
      while heap.cursor_word_advances == advances
        under_marking = heap.malloc(48)
      end
      heap.end_marking_for_spec
      heap.begin_marking_in_hit_path_for_spec.should be_false
      heap.marked_for_spec?(under_marking).should be_true

      # A word claimed with no cycle running hands out white blocks, so the
      # mark above came from the window and not from the chunk's state. (The
      # rest of the word claimed under marking stays black: the claim marks
      # the word whole, and the next cycle's clear resets it.)
      advances = heap.cursor_word_advances
      white = Pointer(Void).null
      while heap.cursor_word_advances == advances
        white = heap.malloc(48)
      end
      heap.marked_for_spec?(white).should be_false
    ensure
      heap.destroy
    end
  end
end
