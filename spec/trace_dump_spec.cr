require "./spec_helper"
require "json"

describe "Gcry.dump_heap" do
  it "matches live_objects and independent address set" do
    heap = Gcry::Heap.new
    begin
      roots = [] of Void*
      8.times do
        p = heap.malloc(48)
        heap.add_root(p)
        roots << p
      end
      heap.collect

      addrs = Gcry.dump_heap_addresses(heap)
      io = IO::Memory.new
      n = Gcry.dump_heap(io, heap)

      n.should eq(heap.live_objects)
      addrs.size.to_u64.should eq(n)

      io.to_s.each_line.count { |l| !l.empty? }.should eq(n.to_i)
    ensure
      heap.destroy
    end
  end

  it "diff helpers detect reclaimed addresses" do
    heap = Gcry::Heap.new
    begin
      a = heap.malloc(32)
      b = heap.malloc(32)
      heap.add_root(a)
      heap.add_root(b)
      before = Gcry.dump_heap_addresses(heap)

      heap.delete_root(b)
      heap.free(b)
      heap.collect
      after = Gcry.dump_heap_addresses(heap)

      Gcry.heap_dump_gone(before, after).should contain(b.address)
      after.should contain(a.address)
    ensure
      heap.destroy
    end
  end
end

describe "Gcry::Trace" do
  it "emits parseable NDJSON for collect" do
    io = IO::Memory.new
    Gcry::Trace.enable(io, alloc_sample: 1_u64)
    begin
      heap = Gcry::Heap.new
      begin
        p = heap.malloc(16)
        heap.add_root(p)
        heap.collect
      ensure
        heap.destroy
      end
    ensure
      Gcry::Trace.disable
    end

    events = [] of String
    io.to_s.each_line do |line|
      next if line.empty?
      obj = JSON.parse(line)
      events << obj["event"].as_s
      obj["ts_ns"].as_i64 # must exist
    end
    events.should contain("alloc")
    events.should contain("collect_start")
    events.should contain("collect_end")
  end
end
