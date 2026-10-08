require "../../src/gcry"
require "spec"
require "weak_ref"

# A `WeakRef` that dies before its target must take its disappearing link with
# it. Boehm drops such a link after it marks from finalizable objects
# (`GC_remove_dangling_disappearing_links`); gcry kept the row. The row outlived
# the `WeakRef`, and when the target died later the collector nulled the
# `WeakRef`'s old `@target` word — by then part of whatever had reused the
# block. 2026-10-05, before the fix: all 2000 links stayed registered after
# their `WeakRef`s died, and 2000 of the 20 000 blocks that reused them came
# back with a zeroed word.
#
# Built on a spawned fiber that scrubs its stack before it finishes, so no
# stale copy of the target or a `WeakRef` roots it from a dead frame.

private class DanglingLinkTarget
end

private DANGLING_PATTERN = 0xA5A5_A5A5_A5A5_A5A5_u64

@[NoInline]
private def dangling_weaks(holder : Array(DanglingLinkTarget), survivor : Array(WeakRef(DanglingLinkTarget)), count : Int32) : Nil
  holder << DanglingLinkTarget.new
  survivor << WeakRef.new(holder[0])
  # Dropped at once: each is a 16-byte atomic block whose `@target` word is a
  # registered link location.
  count.times { WeakRef.new(holder[0]) }
end

@[NoInline]
private def dangling_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

private def dangling_on_fiber(&block : ->) : Nil
  done = Channel(Nil).new
  spawn do
    block.call
    dangling_scrub
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

describe "Regression: dangling disappearing links" do
  it "drops a dead WeakRef's link, so its target's death writes nothing into the reused block" do
    heap = Gcry.default_heap
    holder = [] of DanglingLinkTarget
    survivor = [] of WeakRef(DanglingLinkTarget)
    count = 2000

    3.times { GC.collect }
    before = heap.finalizer_link_count
    dangling_on_fiber { dangling_weaks(holder, survivor, count) }
    heap.finalizer_link_count.should eq(before + count + 1)

    # The WeakRefs die; the target and the survivor do not.
    3.times { GC.collect }
    (heap.finalizer_link_count - before).should be < count // 2

    # Reuse their blocks: same size, same (atomic) kind.
    blocks = Array(Pointer(UInt64)).new(10 * count) do
      p = Pointer(UInt64).malloc(2)
      p[0] = DANGLING_PATTERN
      p[1] = DANGLING_PATTERN
      p
    end

    holder.clear
    3.times { GC.collect }

    # Positive control: the target did die and its live link was cleared.
    survivor[0].value.should be_nil
    blocks.count { |p| p[0] != DANGLING_PATTERN || p[1] != DANGLING_PATTERN }.should eq(0)
  end
end
