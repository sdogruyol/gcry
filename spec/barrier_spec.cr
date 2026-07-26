require "./spec_helper"

describe "Gcry page-dirty barrier" do
  it "reports backend none on library heaps by default" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = true
      heap.scan_static_roots = false
      heap.gc_threshold = UInt64::MAX
      heap.nursery_threshold = UInt64::MAX
      heap.add_root(heap.malloc(32))
      heap.minor_collect(scan_stack: false)
      heap.barrier_backend_name.should eq("none")
      heap.soft_dirty_armed?.should be_false
    ensure
      heap.destroy
    end
  end

  it "arms soft-dirty on process-like nursery heaps when kernel supports it" do
    pending! "Linux only" unless {{ flag?(:linux) }}
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = true
      heap.scan_static_roots = true
      heap.allow_mprotect_barrier = false
      heap.gc_threshold = UInt64::MAX
      heap.nursery_threshold = UInt64::MAX
      heap.add_root(heap.malloc(32))
      heap.minor_collect(scan_stack: false)
      if Gcry::Platform.soft_dirty_supported? && heap.soft_dirty_armed?
        heap.barrier_backend_name.should eq("soft_dirty")
      else
        # Soft-dirty unavailable → none (mprotect disabled in this test).
        heap.barrier_backend.none?.should be_true
      end
    ensure
      heap.destroy
    end
  end

  it "keeps nursery child reachable from old parent via dirty/full scan" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = true
      heap.scan_static_roots = true
      heap.gc_threshold = UInt64::MAX
      heap.nursery_threshold = UInt64::MAX

      parent = heap.malloc(16)
      heap.add_root(parent)
      heap.minor_collect(scan_stack: false)

      child = heap.malloc(32)
      parent.as(Void**).value = child
      heap.minor_collect(scan_stack: false)
      heap.live?(child).should be_true
    ensure
      heap.destroy
    end
  end
end

describe "Gcry mprotect barrier" do
  it "installs, tracks a write, and uninstalls" do
    pending! "Linux only" unless {{ flag?(:linux) }}

    Gcry::Platform.install_mprotect_barrier.should be_true
    begin
      page = LibC.mmap(
        Pointer(Void).null,
        LibC::SizeT.new(4096),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS,
        -1,
        0,
      )
      Gcry.mmap_failed?(page).should be_false
      begin
        addr = page.address
        Gcry::Platform.mprotect_set_heap_range(addr, addr + 4096)
        Gcry::Platform.clear_mprotect_dirty_bits
        Gcry::Platform.mprotect_protect_range(addr, addr + 4096)

        before = Gcry::Platform.mprotect_hits
        page.as(UInt8*).value = 0xAB_u8 # SEGV → dirty + unprotect
        page.as(UInt8*).value.should eq(0xAB_u8)
        Gcry::Platform.mprotect_hits.should be > before

        dirty, total = Gcry::Platform.count_mprotect_dirty_pages
        total.should eq(1)
        dirty.should eq(1)
      ensure
        LibC.munmap(page, LibC::SizeT.new(4096)) unless Gcry.mmap_failed?(page)
      end
    ensure
      Gcry::Platform.disable_mprotect_barrier
    end
  end

  it "can prefer mprotect on a process-like heap" do
    pending! "Linux only" unless {{ flag?(:linux) }}
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = true
      heap.scan_static_roots = true
      heap.prefer_mprotect_barrier = true
      heap.allow_mprotect_barrier = true
      heap.gc_threshold = UInt64::MAX
      heap.nursery_threshold = UInt64::MAX
      heap.add_root(heap.malloc(64))
      heap.minor_collect(scan_stack: false)
      heap.barrier_backend_name.should eq("mprotect")
      # Second minor should still keep rooted object.
      child = heap.malloc(32)
      heap.add_root(child)
      heap.minor_collect(scan_stack: false)
      heap.live?(child).should be_true
    ensure
      heap.destroy
      Gcry::Platform.disable_mprotect_barrier
    end
  end
end

describe "Gcry sound incremental (dirty re-scan)" do
  it "completes incremental cycle with barrier preferred" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = false
      heap.scan_static_roots = true
      heap.allow_mprotect_barrier = false
      heap.gc_threshold = UInt64::MAX
      root = heap.malloc(64)
      heap.add_root(root)
      80.times { heap.malloc(32) }

      finished = false
      10_000.times do
        finished = heap.collect_a_little(64)
        break if finished
      end
      finished.should be_true
      heap.live?(root).should be_true
      heap.major_collections.should be > 0
    ensure
      heap.destroy
    end
  end

  it "gracefully skips sweep when process-GC has no barrier" do
    # Regression: when incremental cycles start but no page-dirty barrier can
    # be armed (Darwin), collect_a_little must avoid sweeping live objects.
    # This test verifies the guard: begin_incremental bails early, so
    # collect_a_little returns false and the caller falls through to full STW.
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = false
      heap.scan_static_roots = true
      # Simulate process-GC mode (Darwin): stop_the_world = true signals the
      # incremental guard that a concurrent mutator may write between slices.
      # We do NOT actually run stop_world here (single-threaded spec would
      # deadlock) — the guard only checks @stop_the_world, it doesn't invoke it.
      heap.stop_the_world = true
      heap.incremental_auto = true
      heap.incremental_work = 64
      heap.gc_threshold = UInt64::MAX
      heap.allow_mprotect_barrier = false

      root = heap.malloc(64)
      heap.add_root(root)
      80.times { heap.malloc(32) }

      # collect_a_little must bail — no barrier -> no inc_active.
      # Returning false without sweeping means no major_collection was
      # credited + root stays alive.
      finished = heap.collect_a_little(64)
      finished.should be_false
      heap.live?(root).should be_true
      heap.major_collections.should eq(0)

      # Full STW collect still works correctly.
      # Temporarily disable stop_the_world since this is a single-threaded spec
      # (the guard only checks the flag, suspend/signal would hang on Linux).
      heap.stop_the_world = false
      heap.collect(scan_stack: false)
      heap.stop_the_world = true
      heap.live?(root).should be_true
      heap.major_collections.should eq(1)
    ensure
      heap.stop_the_world = false
      heap.destroy
    end
  end

  it "exposes pause percentiles via Gcry.pause_stats" do
    saved = Gcry.default_heap
    heap = Gcry::Heap.new
    Gcry.default_heap = heap
    begin
      heap.nursery_enabled = false
      heap.gc_threshold = UInt64::MAX
      heap.add_root(heap.malloc(16))
      4.times do
        100.times { heap.malloc(48) }
        heap.collect(scan_stack: false)
      end
      ps = Gcry.pause_stats
      ps.count.should eq(4)
      ps.p50_ns.should be > 0
      ps.p99_ns.should be >= ps.p50_ns
    ensure
      Gcry.default_heap = saved
    end
  end
end
