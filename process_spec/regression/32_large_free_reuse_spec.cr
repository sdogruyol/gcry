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
# is mapped and unmapped. The large cache is emptied first: chunks a sweep
# freed in earlier examples are recycled to a fresh address, which the
# counters read as an unmap and a map although no page went back to the
# kernel. In a full aarch64 `process_spec` run (CI, 2026-10-06) the gzip loop
# took 7 such chunks before settling: 500 in-place takes, 2.9 MB "unmapped".
# Returns {bytes unmapped, in-place large takes, recycles}.
private def maps_during(warmup : ->, &) : {UInt64, UInt64, UInt64}
  heap = Gcry.default_heap
  GC.collect
  heap.trim_large_cache(0_u64, defer: false, cap: UInt64::MAX)
  GC.disable
  begin
    # One round first, so the blocks it frees are what the measured rounds
    # find in the cache.
    warmup.call
    unmapped = heap.unmapped_bytes
    hits = heap.large_cache_hits
    recycles = heap.large_recycles
    yield
    {heap.unmapped_bytes - unmapped, heap.large_cache_hits - hits, heap.large_recycles - recycles}
  ensure
    GC.enable
  end
end

describe "a large block freed with GC.free" do
  it "is reused in place by the next large allocation of its size" do
    round = -> { GC.free(GC.malloc(LibC::SizeT.new(256 * 1024))) }
    unmapped, hits, recycles = maps_during(round) do
      100.times { round.call }
    end
    unmapped.should eq(0)
    hits.should eq(100)
    recycles.should eq(0)
  end

  it "is reused across a gzip stream's allocator callbacks" do
    payload = Bytes.new(4096) { |i| (i * 7 % 256).to_u8 }
    gzip = -> {
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io, &.write(payload))
      nil
    }
    unmapped, hits, recycles = maps_during(gzip) do
      100.times { gzip.call }
    end
    unmapped.should eq(0)
    hits.should be >= 100
    recycles.should eq(0)
  end
end
