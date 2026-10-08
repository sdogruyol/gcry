require "../../src/gcry"
require "spec"

# Crystal's stdlib reads a buffer it has just grown from: `IO::Memory#write`
# of its own `to_slice` grows `@buffer` with `realloc`, then copies from the
# slice, which still points at the old block (`io.write(io.to_slice)`).
# `String::Builder#write` and `Array#concat` of a slice over their own buffer
# do the same. So the old block's contents must stay readable after `realloc`
# returns, as they do under Boehm. The `realloc` page move
# (`Heap#move_large_contents`, on by default until 2026-10-06) left everything
# past the old block's first page reading zero: 303 152 of 307 200 bytes of a
# 300 KiB self-copy came out wrong. It is opt-in now (`GCRY_REALLOC_MOVE=1`).
private def pattern(i : Int) : UInt8
  (i % 251 + 1).to_u8
end

describe "realloc of a large buffer" do
  it "leaves the old block readable for an IO::Memory self-write" do
    n = 300 * 1024
    io = IO::Memory.new
    io.write(Bytes.new(n) { |i| pattern(i) })
    io.write(io.to_slice)
    s = io.to_slice
    s.size.should eq(2 * n)
    wrong = 0
    s.each_with_index { |b, i| wrong += 1 unless b == pattern(i % n) }
    wrong.should eq(0)
  end

  it "leaves it readable for a String::Builder that writes its own bytes" do
    n = 300 * 1024
    str = String.build do |sb|
      n.times { |i| sb.write_byte(pattern(i)) }
      sb.write(Slice.new(sb.buffer, sb.bytesize))
    end
    bytes = str.to_slice
    bytes.size.should eq(2 * n)
    wrong = 0
    bytes.each_with_index { |b, i| wrong += 1 unless b == pattern(i % n) }
    wrong.should eq(0)
  end

  it "leaves it readable for an Array that concatenates a view of its own buffer" do
    n = 300_000
    a = Array(Int32).new(n) { |i| i }
    a.concat(a.to_unsafe.to_slice(a.size))
    a.size.should eq(2 * n)
    wrong = 0
    a.each_with_index { |v, i| wrong += 1 unless v == i % n }
    wrong.should eq(0)
  end
end
