require "./spec_helper"

# How a fault outside the heap span is read.
#
# The line this gates said, for three CI failures on 2026-08-20, "never a gcry
# allocation, so a swept object is not the explanation" — while the collector
# was inside `pthread_getattr_np` and the fault was the in-flight thread id plus
# `0x418`, i.e. libc reading a field of the descriptor that a stale
# `@system_handle` pointed at. That is the use-after-free being hunted, excluded
# by name in its own crash report.
#
# The decision is pure so it can be gated without faking a signal: the branch
# that matters fires only while the query is in flight, which no harness can
# enter (`bench/log/linux/2026-08-20-dying-thread-holder/FINDINGS.md`).
describe Gcry::SegvReport do
  describe ".out_of_span_reading" do
    it "keeps the plain reading when no stack-bounds query is in flight" do
      Gcry::SegvReport.out_of_span_reading(0x7f00_0000_0000_u64, 0_u64)
        .should eq(Gcry::SegvReport::OutOfSpan::NoQuery)
    end

    it "names a descriptor field at glibc's +0x418, the shape every sighting took" do
      id = 0xff6d_bcbf_ff40_u64
      Gcry::SegvReport.out_of_span_reading(id + 0x418, id)
        .should eq(Gcry::SegvReport::OutOfSpan::DescriptorField)
    end

    it "does not call a distant address a field of the descriptor" do
      id = 0xff6d_bcbf_ff40_u64
      Gcry::SegvReport.out_of_span_reading(id + Gcry::SegvReport::OUT_OF_SPAN_FIELD_MAX, id)
        .should eq(Gcry::SegvReport::OutOfSpan::QueryFar)
    end

    it "does not read an address below the id as an offset into it" do
      id = 0xff6d_bcbf_ff40_u64
      Gcry::SegvReport.out_of_span_reading(id - 0x418, id)
        .should eq(Gcry::SegvReport::OutOfSpan::QueryFar)
    end

    it "does not treat the id itself as a field of its own descriptor" do
      id = 0xff6d_bcbf_ff40_u64
      Gcry::SegvReport.out_of_span_reading(id, id)
        .should eq(Gcry::SegvReport::OutOfSpan::QueryFar)
    end
  end
end
