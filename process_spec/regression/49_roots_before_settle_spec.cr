require "../../src/gcry"
require "spec"

# Roots marked before the cursor settle (readiness-2 review).
#
# A collection's root phase zeroes the mark bits of every chunk the previous
# cycle pinned — chunks whose allocating thread was frozen mid-allocation —
# in `bitmap_settle_cursor_sets`. Until 2026-10-08 the before-collect hook
# (`GC_add_roots` ranges, `GC_set_push_other_roots`) and the explicit roots
# (`GC.add_root`, the realloc pin) were marked *before* it, so a root in such
# a chunk lost its bit and was swept with its range still naming it: with 16
# threads registering ranges while another thread collected, 900–2600 of 3200
# objects held only by registered ranges were freed and reused, every run.
# One adder thread, or a heap array instead of ranges, never showed it: it
# takes allocation racing a collection to pin chunks.

private THREADS    =                        16
private PER_THREAD =                       200
private WORDS      =                         4
private TAG_BASE   = 0x4900_0000_0000_0000_u64

private def tag(t : Int32, i : Int32) : UInt64
  TAG_BASE | (t.to_u64 << 16) | i.to_u64
end

describe "Regression: roots marked before the cursor settle" do
  it "keeps every object held only by a GC_add_roots range while threads allocate and another collects" do
    total = THREADS * PER_THREAD
    # The range words, in libc memory: only the registered ranges name the
    # objects, never a scanned word of this test's own.
    slots = LibC.malloc(total * sizeof(Void*)).as(Void**)
    slots.clear(total)
    stop = Atomic(Int32).new(0)
    collections = Atomic(Int32).new(0)

    collector = Thread.new do
      until stop.get == 1
        GC.collect
        collections.add(1)
      end
    end

    adders = Array(Thread).new(THREADS) do |t|
      Thread.new do
        PER_THREAD.times do |i|
          slot = slots + (t * PER_THREAD + i)
          obj = GC.malloc(LibC::SizeT.new(WORDS * sizeof(UInt64))).as(UInt64*)
          WORDS.times { |w| obj[w] = tag(t, i) &+ w.to_u64 }
          slot.value = obj.as(Void*)
          LibGC.add_roots(slot.as(Void*), (slot + 1).as(Void*))
          # Garbage between registrations, so this thread is often frozen
          # mid-allocation by the collector's stops: that is what pins chunks.
          8.times { GC.malloc(LibC::SizeT.new(48)) }
        end
      end
    end
    adders.each(&.join)
    stop.set(1)
    collector.join
    collections.get.should be > 0

    # Collect and churn, so a block that was wrongly freed is reused and no
    # longer carries its tag.
    3.times do
      GC.collect
      20_000.times { GC.malloc(LibC::SizeT.new(WORDS * sizeof(UInt64))).as(UInt64*).clear(WORDS) }
    end

    bad = 0
    total.times do |k|
      t = k // PER_THREAD
      i = k % PER_THREAD
      obj = slots[k].as(UInt64*)
      if obj.null? || LibGC.base(obj.as(Void*)) != obj.as(Void*)
        bad += 1
        next
      end
      intact = true
      WORDS.times { |w| intact = false unless obj[w] == tag(t, i) &+ w.to_u64 }
      bad += 1 unless intact
    end
    bad.should eq(0)
    # Taken back off as a whole (`GC_remove_roots`), so later files do not
    # scan this memory once it is freed.
    LibGC.remove_roots(slots.as(Void*), (slots + total).as(Void*))
    LibC.free(slots.as(Void*))
  end
end
