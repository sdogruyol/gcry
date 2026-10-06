require "../../src/gcry"
require "spec"

# The ends of the size range, where gcry's answers had drifted from Boehm's.
#
# The atomic slack (`Heap#atomic_slack`) was added to the request with a
# wrapping `&+`, so `GC.malloc_atomic(SIZE_MAX)` asked for 0 bytes and got a
# 16-byte block, and `GC.realloc(p, SIZE_MAX)` of an atomic block "grew" it
# to nothing and returned a block holding none of its contents. Boehm
# saturates (`SIZET_SAT_ADD`) and the request fails, as it does here for
# `GC.malloc(SIZE_MAX)` and did for both before the slack.
#
# `GC_realloc(p, 0)` frees `p` and answers NULL in Boehm (`mallocx.c`); gcry
# returned a fresh `malloc(0)` and left `p` to the sweep. `realloc(NULL, n)`
# is `malloc(n)` in both.
describe "allocation size edges" do
  it "fails a malloc_atomic whose slack would overflow, as malloc fails" do
    expect_raises(Exception) { GC.malloc(LibC::SizeT::MAX) }
    expect_raises(Exception) { GC.malloc_atomic(LibC::SizeT::MAX) }
  end

  it "fails a realloc of an atomic block to SIZE_MAX instead of dropping its contents" do
    p = GC.malloc_atomic(LibC::SizeT.new(64)).as(UInt8*)
    64.times { |i| p[i] = i.to_u8 }
    expect_raises(Exception) { GC.realloc(p.as(Void*), LibC::SizeT::MAX) }
    64.times { |i| p[i].should eq(i.to_u8) }
  end

  it "frees the block and answers null for realloc to zero bytes" do
    {false, true}.each do |atomic|
      p = atomic ? GC.malloc_atomic(LibC::SizeT.new(64)) : GC.malloc(LibC::SizeT.new(64))
      Gcry.usable_size(p).should be >= 64
      GC.realloc(p, LibC::SizeT.new(0)).null?.should be_true
      Gcry.usable_size(p).should eq(0)
    end
    big = GC.malloc(LibC::SizeT.new(1 << 20))
    LibGC.realloc(big, LibC::SizeT.new(0)).null?.should be_true
    Gcry.usable_size(big).should eq(0)
  end

  it "allocates for realloc of null" do
    {0, 64, 1 << 20}.each do |n|
      p = GC.realloc(Pointer(Void).null, LibC::SizeT.new(n))
      p.null?.should be_false
      Gcry.usable_size(p).should be >= n
      q = LibGC.realloc(Pointer(Void).null, LibC::SizeT.new(n))
      q.null?.should be_false
      Gcry.usable_size(q).should be >= n
    end
  end
end
