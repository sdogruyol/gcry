require "../../src/gcry"
require "spec"
require "weak_ref"

# `GC.free` of a `WeakRef` (default-path review). Its disappearing link lives
# inside it, at `@target`, and the free path dropped only links whose *target*
# was the freed block. The row stayed, and the collector's dead-holder check
# (`dead_link_location?`) let it be once the block was reused, because the new
# owner is marked. When the target then died, its link's word was nulled —
# inside the new owner. 2026-10-11, before the fix: a live 16-byte buffer
# that took the freed `WeakRef`'s block (59 allocations later) and held
# {0x1111, 0x2222} read {0x1111, 0x0} after the target was freed, and the
# same after a collection reclaimed it. gcry now drops the links inside a
# block when it is freed.
#
# The buffers are the `WeakRef`'s size and kind (16 bytes, atomic), so one
# reuses its block within the allocator's current word (60 to 63 allocations
# on a bitmap chunk, the next one on a freelist).

private REUSE_TRIES = 100_000

private class FreedHolderTarget
  @value = 0_i64
end

private PATTERN_LO = 0x1111_u64
private PATTERN_HI = 0x2222_u64

# Allocates until a 16-byte atomic buffer lands on *address*, filling it with
# the pattern; nothing else may allocate between the free and this. *keep*
# keeps every buffer alive and must have its capacity already.
private def reuse_block(address : Void*, keep : Array(Pointer(UInt64))) : Pointer(UInt64)
  REUSE_TRIES.times do
    keep << Pointer(UInt64).malloc(2)
    break if keep.last.as(Void*) == address
  end
  buffer = keep.last
  buffer.as(Void*).should eq(address)
  buffer[0] = PATTERN_LO
  buffer[1] = PATTERN_HI
  buffer
end

@[NoInline]
private def freed_holder_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

# Builds on a spawned fiber that scrubs its stack before it finishes, so no
# stale copy of the target roots it from a dead frame (20's header).
private def freed_holder_on_fiber(&block : ->) : Nil
  done = Channel(Nil).new
  spawn do
    block.call
    freed_holder_scrub
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

describe "Regression: freeing a WeakRef drops the link inside it" do
  it "writes nothing into the block's new owner when the target is freed" do
    heap = Gcry.default_heap
    target = FreedHolderTarget.new
    keep = Array(Pointer(UInt64)).new(REUSE_TRIES)
    ref = WeakRef.new(target)
    links = heap.finalizer_link_count
    address = ref.as(Void*)
    GC.free(address)
    buffer = reuse_block(address, keep)
    heap.finalizer_link_count.should eq(links - 1)

    GC.free(target.as(Void*))
    buffer[0].should eq(PATTERN_LO)
    buffer[1].should eq(PATTERN_HI)
    GC.collect
    buffer[0].should eq(PATTERN_LO)
    buffer[1].should eq(PATTERN_HI)
  end

  it "writes nothing into the block's new owner when a collection reclaims the target" do
    heap = Gcry.default_heap
    holder = [] of FreedHolderTarget
    control = [] of WeakRef(FreedHolderTarget)
    keep = Array(Pointer(UInt64)).new(REUSE_TRIES)
    # The freed `WeakRef`'s address, kept away from any word that would root
    # the target.
    address = Pointer(Void).null
    freed_holder_on_fiber do
      holder << FreedHolderTarget.new
      control << WeakRef.new(holder[0])
      address = WeakRef.new(holder[0]).as(Void*)
    end
    links = heap.finalizer_link_count
    GC.free(address)
    buffer = reuse_block(address, keep)
    heap.finalizer_link_count.should eq(links - 1)

    holder.clear
    3.times { GC.collect }
    # Positive control: the target did die and its live link was cleared.
    control[0].value.should be_nil
    buffer[0].should eq(PATTERN_LO)
    buffer[1].should eq(PATTERN_HI)
  end
end
