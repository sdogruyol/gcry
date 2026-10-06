require "../../src/gcry"
require "spec"

# Readiness B4: the Crystal compiler built with gcry emitted calls to
# `…\01`-suffixed functions and failed to link. Its 116-byte mangled names
# come out of `String::Builder`, which lets the content fill a grown buffer
# exactly (12-byte header + 116 = `Math.pw2ceil` = 128) and then writes the
# terminator at `@buffer[128]`, one past the allocation. Boehm adds a byte to
# every request (`GC_malloc_atomic(128)` is a 144-byte object), so the store
# lands in slack; gcry's 128-byte class is exact, so it lands on the next
# block, whose first byte (a `String`'s type id, 1) later overwrites it, and
# LLVM read the name up to the next NUL. `src/gcry/crystal_string_builder_compat.cr`.
#
# The process GC has since given atomic blocks Boehm's byte of slack
# (`Heap#atomic_slack`), which absorbs the terminator by itself, so with it on
# these examples pass without the compat patch. They run with the slack off,
# on exact classes, where only the patch keeps them green.

# The lengths whose header and content fill a size class or a power of two
# exactly — every capacity `String::Builder` grows to, and every class an
# initial `String.build(capacity)` can land in — and one byte either side.
private def boundary_lengths : Array(Int32)
  ends = [] of Int32
  Gcry::SizeClasses::COUNT.times { |i| ends << Gcry::SizeClasses.payload(i).to_i }
  (6..20).each { |shift| ends << (1 << shift) }
  lengths = [] of Int32
  ends.uniq.each do |real|
    content = real - String::HEADER_SIZE
    {content - 1, content, content + 1}.each { |n| lengths << n if n > 0 }
  end
  lengths
end

private def terminator_owned?(s : String) : Bool
  s.to_unsafe[s.bytesize] == 0_u8 &&
    Gcry.usable_size(s.as(Void*)) >= (String::HEADER_SIZE + s.bytesize + 1).to_u64
end

describe "String::Builder under gcry's exact size classes" do
  slack = 0_u64
  before_all do
    slack = Gcry.default_heap.atomic_slack
    Gcry.default_heap.atomic_slack = 0_u64
  end
  after_all { Gcry.default_heap.atomic_slack = slack }

  it "keeps the terminator inside the string's own block when the content fills a grown buffer" do
    boundary_lengths.each do |n|
      s = String.build { |io| io << "x" * n }
      s.bytesize.should eq(n)
      terminator_owned?(s).should be_true, failure_message: "String.build of #{n} bytes"
    end
  end

  it "keeps it there when the content fills the initial capacity" do
    boundary_lengths.each do |n|
      # The initial buffer is `capacity + 13` bytes; n + 1 bytes of content fill it.
      s = String.build(n - 1) { |io| n.times { io << 'y' } }
      terminator_owned?(s).should be_true, failure_message: "String.build(#{n - 1}) of #{n} bytes"
    end
  end

  it "is not ended early by a write to the next block" do
    # The shape the compiler hit: a 116-byte string, then a same-class block
    # whose first byte is 0x01.
    strings = Array(String).new(512)
    neighbours = Array(Pointer(UInt8)).new(512)
    512.times do |i|
      strings << String.build { |io| io << "*Array(Crystal::DWARF)@Array(T)#unsafe_fetch<Int32>:" << i.to_s.rjust(64, '0') }
      neighbour = GC.malloc_atomic(128).as(UInt8*)
      neighbour.fill(128) { 1_u8 }
      neighbours << neighbour
    end
    strings.each do |s|
      s.bytesize.should eq(116)
      LibC.strlen(s.to_unsafe).should eq(116)
    end
  end
end
