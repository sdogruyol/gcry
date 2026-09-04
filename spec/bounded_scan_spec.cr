require "./spec_helper"

# Review finding (PR #1): `clamped_scan_size` had stopped clamping small blocks
# on the header path, so a corrupted header size drove the scan length — a
# SIGSEGV instead of a bounded scan. On this branch every scan derives its
# length from the *chunk* (`block_payload(chunk, header)`), never from the
# header, so a corrupted size cannot lengthen a scan. This pins that: garbage in
# a small block's header size field must neither crash the collector nor
# change what survives.
describe "scan length is chunk-derived" do
  it "survives a corrupted header size on the header path" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.nursery_enabled = false
      keep = [] of Void*
      # A small pointer-bearing object whose payload references a neighbour.
      a = heap.malloc(64)
      b = heap.malloc(64)
      a.as(Void**)[0] = b
      keep << a
      # Corrupt a's header size to something absurd. If the collector trusted
      # it, scanning `a` would walk far past the block — and past the chunk.
      {% unless flag?(:gcry_headerless) %}
        header = Gcry::BlockHeader.from_user(a)
        h = header.value
        h.size = 0x7FFF_FFFF_u32
        header.value = h
      {% end %}
      3.times { heap.collect(scan_stack: false, roots: keep) }
      # `b` is reachable only through `a`'s first word, which lies within the
      # chunk-derived scan length; it must still be live and intact.
      heap.live?(b).should be_true
      heap.live?(a).should be_true
      a.as(Void**)[0].should eq(b)
    ensure
      heap.destroy
    end
  end
end
