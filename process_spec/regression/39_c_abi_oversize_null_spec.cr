require "../../src/gcry"
require "spec"

# A request no mapping can hold fails as out of memory, as in Boehm, which
# saturates it and answers `GC_oom_fn(lb)`: NULL through the C ABI. Until
# 2026-10-07 `SizeClasses.fit` and `alloc_large` rounded it up with checked
# arithmetic and raised `OverflowError`, the latter with `@alloc_lock` held.
# The C ABI rescues only `Gcry::OutOfMemoryError`, so `GC_malloc(SIZE_MAX)`
# ended the process with "Unhandled exception: Arithmetic overflow".
describe "C ABI allocation of an impossible size" do
  sizes = {LibC::SizeT::MAX, LibC::SizeT::MAX - 1, LibC::SizeT::MAX - 100, LibC::SizeT::MAX - 4096}

  it "answers null from GC_malloc, GC_malloc_atomic and GC_realloc" do
    sizes.each do |n|
      LibGC.malloc(n).null?.should be_true
      LibGC.malloc_atomic(n).null?.should be_true
      {false, true}.each do |atomic|
        p = atomic ? GC.malloc_atomic(LibC::SizeT.new(16)) : GC.malloc(LibC::SizeT.new(16))
        p.as(UInt8*).value = 42_u8
        LibGC.realloc(p, n).null?.should be_true
        p.as(UInt8*).value.should eq(42_u8)
      end
    end
  end

  it "raises OutOfMemoryError from the Crystal API" do
    sizes.each do |n|
      expect_raises(Gcry::OutOfMemoryError) { GC.malloc(n) }
      expect_raises(Gcry::OutOfMemoryError) { GC.malloc_atomic(n) }
    end
  end

  it "leaves the allocator usable afterwards" do
    LibGC.malloc(LibC::SizeT::MAX).null?.should be_true
    big = GC.malloc(LibC::SizeT.new(1 << 20))
    big.null?.should be_false
    small = GC.malloc(LibC::SizeT.new(32))
    small.null?.should be_false
    GC.collect
    GC.malloc(LibC::SizeT.new(64)).null?.should be_false
  end
end
