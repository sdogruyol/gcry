require "../../src/gcry"
require "spec"
require "bit_array"

# Boehm adds a byte to every allocation, and Crystal's stdlib has come to
# depend on it: `BitArray#[](start, count)` on an array over 64 bits writes one
# `UInt32` past the result's `@bits` when `count % 32 == 0` (Crystal 1.21.0
# `src/bit_array.cr`, the word-copy loop), and `String::Builder#to_s` writes
# its terminator one byte past its buffer. gcry's size classes are exact, so
# both landed on the first word of the next block. The process GC now gives
# every atomic block the same one byte of slack (`Heap#atomic_slack`);
# `GCRY_ATOMIC_SLACK=0` restores exact classes and turns this red.
SLACK_PATTERN = 0x5a5a5a5a_u32

describe "atomic slack" do
  it "keeps a BitArray slice's word-past-the-end write off its neighbour" do
    victims = [] of Pointer(UInt32)
    clobbered = 0
    200.times do
      # A freed 16-byte hole with a pattern block right after it: the bitmap
      # allocator hands the lowest free block of a class out first, so the
      # slice's 16-byte `@bits` takes the hole and its stray word lands on
      # the pattern block.
      hole = Pointer(UInt32).malloc(4)
      v = Pointer(UInt32).malloc(4)
      4.times { |i| v[i] = SLACK_PATTERN }
      victims << v
      GC.free(hole.as(Void*))
      slice = BitArray.new(200, true)[0, 128]
      slice.size.should eq(128)
    end
    victims.each do |v|
      4.times { |i| clobbered += 1 unless v[i] == SLACK_PATTERN }
    end
    clobbered.should eq(0)
  end

  it "gives every atomic block one byte past the request" do
    p = GC.malloc_atomic(LibC::SizeT.new(16))
    Gcry.usable_size(p).should be >= 17
  end
end
