require "../../src/gcry"
require "spec"

describe "medium cursor allocations under process collection" do
  it "keeps reused buffers zeroed and owned across peer collections" do
    # This regression targets bitmap cursor ownership. The same pressure on
    # the unchanged header allocator reproduces a separate native ARM defect;
    # preserve it explicitly without corrupting later tests' shared heap.
    # HEADER_MEDIUM_STRESS=1 crystal spec -Dgc_none process_spec
    unless Gcry.default_heap.not_nil!.bitmap_alloc? || ENV["HEADER_MEDIUM_STRESS"]? == "1"
      pending! "requires bitmap allocation; HEADER_MEDIUM_STRESS=1 runs the known header reproducer"
    end
    bad = Atomic(Int32).new(0)
    workers = Array(Thread).new(4) do |worker|
      Thread.new do
        sizes = [2049, 8192, 32768]
        ring = Array(Void*).new(32, Pointer(Void).null)
        lengths = Array(Int32).new(32, 0)
        stamp = (worker + 1).to_u8
        2048.times do |i|
          size = sizes[i % sizes.size]
          atomic = i.odd?
          ptr = atomic ? GC.malloc_atomic(size) : GC.malloc(size)
          bytes = ptr.as(UInt8*)
          unless atomic
            bad.add(1) unless bytes[0] == 0 && bytes[size - 1] == 0
          end
          bytes[0] = stamp
          bytes[size - 1] = stamp
          ring[i % ring.size] = ptr
          lengths[i % ring.size] = size
          GC.collect if i % 256 == 0
          ring.each_with_index do |held, j|
            next if held.null?
            bad.add(1) unless held.as(UInt8*)[0] == stamp && held.as(UInt8*)[lengths[j] - 1] == stamp
          end
        end
      end
    end
    workers.each(&.join)
    bad.get.should eq(0)
  end
end
