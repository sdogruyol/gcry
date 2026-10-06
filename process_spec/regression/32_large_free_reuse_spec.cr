require "../../src/gcry"
require "spec"
require "compress/gzip"

# A large block the program frees with `GC.free` is kept, where it is, for
# the next large allocation of its size, as it was before large-object
# recycling. Recycling (Linux process GC, 2026-10-06) let the cache hold only
# what the last major left, and between majors that is nothing, so every
# freed large block was unmapped at once and the next one mapped and faulted
# in fresh. zlib's stream state lives and dies that way (`Compress::Deflate`
# hands zlib `GC.malloc` and `GC.free`): a 20 000-iteration gzip loop ran
# 752 ms against 310 ms with `GCRY_LARGE_RECYCLE=0`, unmapping 5.4 GB
# (`bench/gzip_free_loop.cr`). Kept but handed out through the recycler's
# fresh mapping, it still ran 615 ms.
#
# Collections are held off so only the allocation and free paths decide what
# is mapped and unmapped. Returns {bytes unmapped, chunks mapped}.
private def maps_during(&) : {UInt64, UInt64}
  GC.disable
  begin
    heap = Gcry.default_heap
    unmapped = heap.unmapped_bytes
    mapped = heap.chunks_mapped
    yield
    {heap.unmapped_bytes - unmapped, heap.chunks_mapped - mapped}
  ensure
    GC.enable
  end
end

describe "a large block freed with GC.free" do
  it "is reused in place by the next large allocation of its size" do
    GC.free(GC.malloc(LibC::SizeT.new(256 * 1024)))
    unmapped, mapped = maps_during do
      100.times { GC.free(GC.malloc(LibC::SizeT.new(256 * 1024))) }
    end
    unmapped.should eq(0)
    mapped.should eq(0)
  end

  it "is reused across a gzip stream's allocator callbacks" do
    payload = Bytes.new(4096) { |i| (i * 7 % 256).to_u8 }
    gzip = -> {
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io, &.write(payload))
      io.bytesize
    }
    gzip.call
    unmapped, _ = maps_during do
      100.times { gzip.call }
    end
    unmapped.should eq(0)
  end
end
