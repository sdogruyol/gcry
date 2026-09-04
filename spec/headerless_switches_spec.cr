require "./spec_helper"

# What `-Dgcry_headerless` refuses, and the large-object layout it keeps. All
# of it is compiled out on the header build, where the switches are live and
# covered by their own specs.
{% if flag?(:gcry_headerless) %}
  describe "headerless switches" do
    it "has no block header" do
      Gcry::BlockHeader::SIZE.should eq(0)
      p = Pointer(Void).new(0x1000_u64)
      Gcry::BlockHeader.from_user(p).address.should eq(p.address)
      Gcry::BlockHeader.user_from(p.as(Gcry::BlockHeader*)).should eq(p)
    end

    it "keeps the bitmap representation whatever the caller asks" do
      heap = Gcry::Heap.new
      begin
        heap.bitmap_marks?.should be_true
        heap.bitmap_alloc?.should be_true
        heap.bitmap_marks = false
        heap.bitmap_alloc = false
        heap.bitmap_marks?.should be_true
        heap.bitmap_alloc?.should be_true
        keep = heap.malloc(64)
        heap.add_root(keep)
        heap.collect(scan_stack: false)
        heap.live?(keep).should be_true
      ensure
        heap.destroy
      end
    end

    it "keeps the nursery off and soundness intact" do
      heap = Gcry::Heap.new
      begin
        heap.nursery_enabled.should be_false
        heap.nursery_enabled = true
        heap.nursery_enabled.should be_false
        Gcry.sound_barriers?(heap).should be_true
        Gcry::Observability.json_stats(heap).should contain(%("nursery_enabled":false))
      ensure
        heap.destroy
      end
    end

    it "keeps a real header behind every large object" do
      heap = Gcry::Heap.new
      begin
        big = heap.malloc(200_000)
        big.as(UInt8*)[0] = 1_u8
        big.as(UInt8*)[199_999] = 2_u8
        found = false
        heap.each_chunk do |chunk|
          next unless Gcry::ChunkHeader.large?(chunk)
          next unless Gcry::ChunkHeader.large_user(chunk) == big
          header = Gcry::ChunkHeader.large_header(chunk)
          found = true
          Gcry::BlockHeader.large_user_from_header(header).should eq(big)
          Gcry::BlockHeader.large_header_from_user(big).should eq(header)
          (big.address - chunk.address).should eq(Gcry::ChunkHeader.large_data_offset)
          Gcry::ChunkHeader.contains?(chunk, header.address).should be_true
          Gcry::ChunkHeader.contains?(chunk, big.address).should be_true
          heap.diag_payload(header).should be >= 200_000_u64
          heap.diag_user(header).should eq(big)
        end
        found.should be_true
        heap.add_root(big)
        heap.collect(scan_stack: false)
        heap.live?(big).should be_true
        big.as(UInt8*)[0].should eq(1_u8)
        big.as(UInt8*)[199_999].should eq(2_u8)
      ensure
        heap.destroy
      end
    end
  end
{% end %}
