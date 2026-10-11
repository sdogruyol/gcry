require "../../src/gcry"
require "spec"

# `GC.realloc` shrinks in place and keeps the block's size, so growing it back
# returns the same block. Until 2026-10-11 it did that without clearing what
# the shrink cut off: a block filled with 0xFF, shrunk to 8 bytes and grown
# back held 56, 4 088 and 99 992 bytes of 0xFF past the first 8, at 64,
# 4 096 and 100 000 — a small class, a medium one and a large chunk. `gc.h`
# promises the grown part of an object zeroed ("not guaranteed for atomic
# object type"), Boehm's `GC_realloc` clears it on the in-place return, and
# the stale words were scanned as pointers besides.

private SHRINK_GROW_SIZES = [64, 4096, 100_000]
private SHRINK_GROW_KEEP  = 8

private def shrink_grow(p : Void*, n : Int32) : UInt8*
  Slice.new(p.as(UInt8*), n).fill(0xff_u8)
  p = GC.realloc(p, LibC::SizeT.new(SHRINK_GROW_KEEP))
  GC.realloc(p, LibC::SizeT.new(n)).as(UInt8*)
end

describe "Regression: realloc shrink then grow" do
  SHRINK_GROW_SIZES.each do |n|
    it "zeroes what a shrink cut off once a #{n}-byte block grows back" do
      q = shrink_grow(GC.malloc(LibC::SizeT.new(n)), n)
      Slice.new(q, SHRINK_GROW_KEEP).all?(0xff_u8).should be_true
      Slice.new(q + SHRINK_GROW_KEEP, n - SHRINK_GROW_KEEP).count { |b| b != 0_u8 }.should eq(0)
    end

    # Boehm's contract for an atomic block is the kept prefix and the size,
    # nothing past them.
    it "keeps the prefix of a #{n}-byte atomic block across the same round trip" do
      q = shrink_grow(GC.malloc_atomic(LibC::SizeT.new(n)), n)
      Slice.new(q, SHRINK_GROW_KEEP).all?(0xff_u8).should be_true
      Gcry.usable_size(q.as(Void*)).should be >= n
    end
  end
end
