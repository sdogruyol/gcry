require "./spec_helper"

# The process heap sizes itself from the live set after each major
# collection (`Heap#adapt_threshold_after_sweep`): next threshold =
# live × factor, clamped to [8 MiB, 64 MiB], with the warm-retention budget
# following it under the bitmap allocator. A library heap keeps its fixed
# threshold unless opted in.
describe "adaptive collection threshold" do
  min = Gcry::Heap::ADAPTIVE_THRESHOLD_MIN
  max = Gcry::Heap::ADAPTIVE_THRESHOLD_MAX

  it "is off by default and leaves a fixed threshold alone" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = 123_456_u64
      heap.adaptive_threshold.should be_false
      heap.collect(scan_stack: false)
      heap.gc_threshold.should eq 123_456_u64
    ensure
      heap.destroy
    end
  end

  it "clamps a small live set up to the floor" do
    heap = Gcry::Heap.new
    begin
      heap.adaptive_threshold = true
      heap.gc_threshold = 1024_u64
      heap.collect(scan_stack: false)
      heap.gc_threshold.should eq min
    ensure
      heap.destroy
    end
  end

  it "sets the threshold from the live bytes the sweep measured, times the factor" do
    heap = Gcry::Heap.new
    begin
      heap.adaptive_threshold = true
      # ~12 MiB live in one size class, rooted explicitly so the stack is
      # not needed. No auto-major while filling: the roots array lives in the
      # spec's own heap, so an automatic collection would not see it.
      heap.gc_threshold = UInt64::MAX
      roots = Array(Void*).new(3072)
      3072.times { roots << heap.malloc(4096) }
      heap.collect(scan_stack: false, roots: roots)
      live = heap.size_class_live_bytes
      live.should be >= 12_u64 * 1024 * 1024
      heap.gc_threshold.should eq live

      heap.adaptive_threshold_pct = 200_u64
      heap.collect(scan_stack: false, roots: roots)
      heap.gc_threshold.should eq heap.size_class_live_bytes * 2

      heap.adaptive_threshold_pct = 50_u64
      heap.collect(scan_stack: false, roots: roots)
      # 6 MiB is below the floor.
      heap.gc_threshold.should eq min

      heap.adaptive_threshold_pct = 100_000_u64
      heap.collect(scan_stack: false, roots: roots)
      heap.gc_threshold.should eq max

      # Everything dies: back to the floor on the next major.
      heap.adaptive_threshold_pct = 100_u64
      roots.clear
      heap.collect(scan_stack: false)
      heap.gc_threshold.should eq min
    ensure
      heap.destroy
    end
  end

  it "counts live large objects" do
    heap = Gcry::Heap.new
    begin
      heap.adaptive_threshold = true
      big = heap.malloc(20 * 1024 * 1024)
      heap.collect(scan_stack: false, roots: [big])
      heap.gc_threshold.should be >= 20_u64 * 1024 * 1024
      heap.gc_threshold.should be <= max
      heap.collect(scan_stack: false)
      heap.gc_threshold.should eq min
    ensure
      heap.destroy
    end
  end

  it "moves the warm-retention budget with the threshold only when asked" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.adaptive_threshold = true
      heap.empty_chunk_warm_retain = 0_u64
      heap.collect(scan_stack: false)
      heap.empty_chunk_warm_retain.should eq 0_u64

      heap.warm_retain_follows_threshold = true
      heap.collect(scan_stack: false)
      heap.empty_chunk_warm_retain.should eq heap.gc_threshold
    ensure
      heap.destroy
    end
  end
end
