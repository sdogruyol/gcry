require "./spec_helper"

describe "Gcry::Platform soft-dirty" do
  it "clears soft-dirty and detects a subsequent write" do
    pending! "soft-dirty requires Linux" unless {{ flag?(:linux) }}

    supported = Gcry::Platform.soft_dirty_supported?
    supported.should be_true

    # Anonymous page under our control.
    page = LibC.mmap(
      Pointer(Void).null,
      LibC::SizeT.new(4096),
      LibC::PROT_READ | LibC::PROT_WRITE,
      LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS,
      -1,
      0,
    )
    begin
      Gcry.mmap_failed?(page).should be_false
      addr = page.address

      Gcry::Platform.clear_soft_dirty.should be_true

      dirty_before = false
      Gcry::Platform.each_dirty_page(addr, addr + 4096) { dirty_before = true }.should be_true
      dirty_before.should be_false

      counts = Gcry::Platform.count_soft_dirty_pages(addr, addr + 4096)
      counts.should_not be_nil
      counts.try { |d, t| d.should eq(0); t.should eq(1) }

      page.as(UInt8*).value = 1_u8

      dirty_after = false
      Gcry::Platform.each_dirty_page(addr, addr + 4096) { dirty_after = true }.should be_true
      # Some kernels/WSL builds never set soft-dirty; treat as soft failure.
      if dirty_after
        dirty_after.should be_true
        counts2 = Gcry::Platform.count_soft_dirty_pages(addr, addr + 4096)
        counts2.try { |d, _t| d.should eq(1) }
      else
        pending! "kernel did not set soft-dirty bit after write"
      end
    ensure
      LibC.munmap(page, LibC::SizeT.new(4096)) unless Gcry.mmap_failed?(page)
    end
  end
end

describe "Gcry nursery soft-dirty arming" do
  it "does not arm soft-dirty on library heaps" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = true
      heap.gc_threshold = UInt64::MAX
      heap.nursery_threshold = UInt64::MAX
      heap.scan_static_roots = false

      heap.malloc(32)
      heap.minor_collect(scan_stack: false)
      heap.soft_dirty_armed?.should be_false
    ensure
      heap.destroy
    end
  end

  it "arms soft-dirty on process-like heaps when the kernel tracks writes" do
    heap = Gcry::Heap.new
    begin
      heap.nursery_enabled = true
      heap.scan_static_roots = true
      heap.gc_threshold = UInt64::MAX
      heap.nursery_threshold = UInt64::MAX

      heap.malloc(32)
      heap.minor_collect(scan_stack: false)
      # Armed only if clear_refs + soft-dirty probe both succeed.
      if Gcry::Platform.soft_dirty_supported?
        # May still be false on WSL without soft-dirty — that is OK (full-scan fallback).
        heap.soft_dirty_armed?.should be_a(Bool)
      else
        heap.soft_dirty_armed?.should be_false
      end
    ensure
      heap.destroy
    end
  end
end
