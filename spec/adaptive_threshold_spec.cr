require "./spec_helper"

# The process heap sizes itself from the live set after each major
# collection (`Heap#adapt_after_sweep`): next threshold = live × factor,
# floored at 8 MiB (Darwin 16 MiB) and capped at 64 MiB or a third of the
# bytes the mark scanned × factor, whichever is larger; the warm-retention
# budget follows the same live × factor, capped by the threshold, fixed or
# not. A library heap keeps its fixed threshold unless opted in.
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
      # ~20 MiB live in one size class — above the floor on every platform
      # (Darwin's is 16 MiB) — rooted explicitly so the stack is not needed.
      # No auto-major while filling: the roots array lives in the spec's own
      # heap, so an automatic collection would not see it.
      heap.gc_threshold = UInt64::MAX
      roots = Array(Void*).new(5120)
      5120.times { roots << heap.malloc(4096) }
      heap.collect(scan_stack: false, roots: roots)
      live = heap.size_class_live_bytes
      live.should be >= 20_u64 * 1024 * 1024
      heap.gc_threshold.should eq live

      heap.adaptive_threshold_pct = 200_u64
      heap.collect(scan_stack: false, roots: roots)
      heap.gc_threshold.should eq heap.size_class_live_bytes * 2

      heap.adaptive_threshold_pct = 50_u64
      heap.collect(scan_stack: false, roots: roots)
      # ~10 MiB: below Darwin's floor, above Linux's.
      half = heap.size_class_live_bytes // 2
      heap.gc_threshold.should eq(half < min ? min : half)

      # Live × factor past 64 MiB, a third of the scanned live × factor
      # below it: the floor of the cap holds.
      heap.adaptive_threshold_pct = 400_u64
      heap.collect(scan_stack: false, roots: roots)
      (heap.size_class_live_bytes * 4).should be > max
      (heap.mark_scanned_bytes * 4 // 3).should be < max
      heap.gc_threshold.should eq max

      # Past it, the cap is a third of the scanned live × factor, so the
      # schedule stays geometric instead of collecting every 64 MiB.
      heap.adaptive_threshold_pct = 1000_u64
      heap.collect(scan_stack: false, roots: roots)
      heap.mark_scanned_bytes.should eq heap.size_class_live_bytes
      cap = heap.mark_scanned_bytes * 10 // 3
      cap.should be > max
      heap.gc_threshold.should eq cap

      # A raised floor (`GCRY_THRESHOLD_MAX`) lets live × factor through.
      heap.adaptive_threshold_max = 1_u64 << 30
      heap.collect(scan_stack: false, roots: roots)
      heap.gc_threshold.should eq heap.size_class_live_bytes * 10
      heap.adaptive_threshold_max = max

      # Everything dies: back to the floor on the next major.
      heap.adaptive_threshold_pct = 100_u64
      roots.clear
      heap.collect(scan_stack: false)
      heap.gc_threshold.should eq min
    ensure
      heap.destroy
    end
  end

  it "does not grow the cap with a live set the mark never scans" do
    heap = Gcry::Heap.new
    begin
      heap.adaptive_threshold = true
      heap.gc_threshold = UInt64::MAX
      # The same ~20 MiB as above, atomic: marked, never read. Fewer majors
      # would buy it nothing, so it keeps the 64 MiB cap and its RSS.
      roots = Array(Void*).new(5120)
      5120.times { roots << heap.malloc_atomic(4096) }
      heap.adaptive_threshold_pct = 1000_u64
      heap.collect(scan_stack: false, roots: roots)
      heap.size_class_live_bytes.should be >= 20_u64 * 1024 * 1024
      heap.mark_scanned_bytes.should eq 0
      heap.gc_threshold.should eq max

      # Nor does a large atomic object.
      big = heap.malloc_atomic(40 * 1024 * 1024)
      roots << big
      heap.collect(scan_stack: false, roots: roots)
      heap.mark_scanned_bytes.should eq 0
      heap.gc_threshold.should eq max
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

  it "moves the warm-retention budget with the live set only when asked" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.adaptive_threshold = true
      heap.empty_chunk_warm_retain = 0_u64
      heap.collect(scan_stack: false)
      heap.empty_chunk_warm_retain.should eq 0_u64

      heap.warm_retain_follows_live = true
      heap.collect(scan_stack: false)
      heap.empty_chunk_warm_retain.should eq heap.gc_threshold
    ensure
      heap.destroy
    end
  end

  it "caps the warm budget by a fixed threshold and lets it fall with the live set" do
    heap = Gcry::Heap.new
    begin
      heap.bitmap_alloc = true
      heap.nursery_enabled = false
      heap.warm_retain_follows_live = true
      heap.gc_threshold = UInt64::MAX
      roots = Array(Void*).new(5120)
      5120.times { roots << heap.malloc(4096) } # ~20 MiB live, above every floor
      fixed = 128_u64 * 1024 * 1024
      heap.gc_threshold = fixed
      heap.collect(scan_stack: false, roots: roots)
      heap.gc_threshold.should eq fixed
      live = heap.size_class_live_bytes
      heap.empty_chunk_warm_retain.should eq live # live × 100 %, under the cap
      # The live set drops: the budget follows it down to the floor, while
      # the fixed threshold stays.
      roots.clear
      heap.collect(scan_stack: false)
      heap.empty_chunk_warm_retain.should eq min
      heap.gc_threshold.should eq fixed
      # A budget larger than the threshold is capped by it (4 MiB is below
      # every floor, so the floor would otherwise win).
      heap.gc_threshold = 4_u64 * 1024 * 1024
      heap.collect(scan_stack: false)
      heap.empty_chunk_warm_retain.should eq 4_u64 * 1024 * 1024
    ensure
      heap.destroy
    end
  end
end
