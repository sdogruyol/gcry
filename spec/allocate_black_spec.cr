require "./spec_helper"

# The mark a mutator writes when it allocates during a collection goes through
# a compare-and-swap that re-reads the generation, because the plain
# read-modify-write could be suspended by the stop-the-world between its read
# and its write and then overwrite the collector's mark with a stale copy.
# This pins the observable contract: the mark lands, other flags survive, and
# a generation bump before the write is honoured.
{% unless flag?(:gcry_headerless) %}
  describe "allocate-black mark" do
    it "marks with the current generation and keeps the other flags" do
      header = Pointer(Gcry::BlockHeader).malloc(1)
      header.value = Gcry::BlockHeader.new(64_u32, Gcry::BlockHeader::Flags::ATOMIC, Pointer(Void).null)
      Gcry::BlockHeader.marked?(header).should be_false
      Gcry::BlockHeader.set_mark_allocating(header)
      Gcry::BlockHeader.marked?(header).should be_true
      (header.value.flags & Gcry::BlockHeader::Flags::ATOMIC).should eq(Gcry::BlockHeader::Flags::ATOMIC)
      header.value.size.should eq(64_u32)
    end

    it "agrees with the collector's own mark" do
      a = Pointer(Gcry::BlockHeader).malloc(1)
      b = Pointer(Gcry::BlockHeader).malloc(1)
      a.value = Gcry::BlockHeader.new(32_u32, 0_u32, Pointer(Void).null)
      b.value = Gcry::BlockHeader.new(32_u32, 0_u32, Pointer(Void).null)
      Gcry::BlockHeader.set_mark(a)
      Gcry::BlockHeader.set_mark_allocating(b)
      a.value.flags.should eq(b.value.flags)
    end

    it "is current after a generation bump" do
      header = Pointer(Gcry::BlockHeader).malloc(1)
      header.value = Gcry::BlockHeader.new(32_u32, 0_u32, Pointer(Void).null)
      before = Gcry::BlockHeader.mark_gen
      begin
        Gcry::BlockHeader.mark_gen = before &+ 1_u8
        Gcry::BlockHeader.set_mark_allocating(header)
        Gcry::BlockHeader.marked?(header).should be_true
        Gcry::BlockHeader.mark_gen = before
        # The mark from the bumped generation is stale now, as it should be.
        Gcry::BlockHeader.marked?(header).should be_false
      ensure
        Gcry::BlockHeader.mark_gen = before
      end
    end
  end
{% end %}
