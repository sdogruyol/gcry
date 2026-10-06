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
end
