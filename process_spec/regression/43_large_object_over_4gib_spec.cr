require "../../src/gcry"
require "spec"

# A large object past 4 GiB is scanned, sized and reallocated at its whole
# size. Its header kept the size in 32 bits (`BlockHeader#size`) and both
# allocation paths stored `payload.to_u32!`, so a block of 4 GiB + 1 MiB
# recorded 1 MiB: the mark scanned its first 1 MiB and swept what it held
# beyond, `GC_size` answered 1 MiB (0 for a pointer past it), and `realloc` to
# its own size moved it and copied 1 MiB. Bits 32–47 of the size now ride in
# the header's flags word (`BlockHeader.large`).
#
# Only the words the examples need are written: a fresh mapping reads zero.
# The mark still reads every page, which commits them on Windows. A host that
# cannot map the block marks the examples pending.

private FAR_BIG_BYTES = (4_u64 << 30) + (1_u64 << 20)
private FAR_OFFSET    = (4_u64 << 30) + (64_u64 << 10)
private FAR_TAG       = 0x0FA2_C41D_5EED_0043_u64

private class FarChild
  @@finalized = 0

  def self.finalized : Int32
    @@finalized
  end

  getter tag : UInt64

  def initialize(@tag : UInt64)
  end

  def finalize
    @@finalized += 1
  end
end

private def far_slot(big : Void*) : FarChild*
  (big.as(UInt8*) + FAR_OFFSET).as(FarChild*)
end

@[NoInline]
private def far_store_child(big : Void*) : Nil
  far_slot(big).value = FarChild.new(FAR_TAG)
end

@[NoInline]
private def far_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

# The child is made on a fiber of its own, as in
# `26_pending_finalizer_root_spec`, so the slot past 4 GiB is its only
# reference.
private def far_store_on_fiber(big : Void*) : Nil
  done = Channel(Nil).new
  spawn do
    far_store_child(big)
    far_scrub
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

# Yields a pointerful block of `FAR_BIG_BYTES`, freed and unmapped afterwards
# so the examples that follow are not starved.
private def with_far_block(& : Void* ->) : Nil
  big = begin
    GC.malloc(LibC::SizeT.new(FAR_BIG_BYTES))
  rescue ex : Gcry::OutOfMemoryError
    pending! "cannot map #{FAR_BIG_BYTES} bytes here: #{ex.message}"
  end
  begin
    yield big
  ensure
    GC.free(big)
    Gcry.default_heap.trim_large_cache(0_u64, defer: false, cap: UInt64::MAX)
  end
end

describe "Regression: a large object over 4 GiB" do
  it "keeps an object it holds past 4 GiB alive" do
    with_far_block do |big|
      before = FarChild.finalized
      far_store_on_fiber(big)
      3.times { GC.collect }
      FarChild.finalized.should eq(before)
      child = far_slot(big).value
      Gcry.default_heap.live?(child.as(Void*)).should be_true
      child.tag.should eq(FAR_TAG)
    end
  end

  it "reports its whole size and reallocates in place at that size" do
    with_far_block do |big|
      (big.as(UInt8*) + FAR_OFFSET).as(UInt64*).value = FAR_TAG
      Gcry.usable_size(big).should be >= FAR_BIG_BYTES
      LibGC.size(big).should be >= FAR_BIG_BYTES
      Gcry.usable_size((big.as(UInt8*) + FAR_OFFSET).as(Void*)).should be >= FAR_BIG_BYTES
      GC.realloc(big, LibC::SizeT.new(FAR_BIG_BYTES)).should eq(big)
      (big.as(UInt8*) + FAR_OFFSET).as(UInt64*).value.should eq(FAR_TAG)
    end
  end
end
