require "./spec_helper"

# Darwin platform parity (Phase 6.1): stubs, stack bounds, RSS reclaim.
# Soft-dirty / mprotect are Linux-only; Darwin must report unsupported cleanly.

{% if flag?(:darwin) %}
  describe "Gcry::Platform Darwin stubs" do
    it "reports soft-dirty unsupported" do
      Gcry::Platform.soft_dirty_supported?.should be_false
      Gcry::Platform.clear_soft_dirty.should be_false
      Gcry::Platform.each_dirty_page(0_u64, 4096_u64) { }.should be_false
      Gcry::Platform.count_soft_dirty_pages(0_u64, 4096_u64).should be_nil
    end

    it "reports mprotect barrier unsupported" do
      Gcry::Platform.install_mprotect_barrier.should be_false
      Gcry::Platform.mprotect_barrier_enabled?.should be_false
      Gcry::Platform.mprotect_hits.should eq(0_u64)
      Gcry::Platform.mprotect_fault(0_u64).should be_false
      dirty, total = Gcry::Platform.count_mprotect_dirty_pages
      dirty.should eq(0_u64)
      total.should eq(0_u64)
    end

    it "reports Darwin process GC supported" do
      Gcry::Platform.darwin_process_gc_supported?.should be_true
    end
  end

  describe "Gcry::Platform Darwin stack bounds" do
    it "returns pthread stack bounds containing the current SP" do
      bounds = Gcry::Platform.current_pthread_stack_bounds
      bounds.should_not be_nil
      low, high = bounds.not_nil!
      low.address.should be < high.address

      local = 0
      sp = pointerof(local).address
      sp.should be >= low.address
      sp.should be < high.address

      self_bounds = Gcry::Platform.pthread_stack_bounds(LibC.pthread_self)
      self_bounds.should_not be_nil
      self_low, self_high = self_bounds.not_nil!
      self_low.address.should eq(low.address)
      self_high.address.should eq(high.address)
    end
  end

  describe "Gcry::Platform Darwin RSS reclaim" do
    it "release_physical_pages accepts host-page-aligned ranges" do
      page = Gcry::Platform.host_page_size
      page.should be > 0

      ptr = LibC.mmap(
        Pointer(Void).null,
        LibC::SizeT.new(page),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS,
        -1,
        0,
      )
      begin
        Gcry.mmap_failed?(ptr).should be_false
        ptr.as(UInt8*).value = 0xab_u8

        Gcry::Platform.release_physical_pages(ptr.address + 1, page).should be_false
        Gcry::Platform.release_physical_pages(ptr.address, page + 1).should be_false
        Gcry::Platform.release_physical_pages(ptr.address, 0_u64).should be_false

        # MADV_FREE_REUSABLE may keep contents until the kernel reclaims under
        # pressure — do not assert zero-fill. Only that the aligned call succeeds.
        Gcry::Platform.release_physical_pages(ptr.address, page).should be_true
        # Page remains mapped and readable.
        _ = ptr.as(UInt8*).value
      ensure
        LibC.munmap(ptr, LibC::SizeT.new(page)) unless Gcry.mmap_failed?(ptr)
      end
    end
  end
{% else %}
  describe "Gcry::Platform Darwin stubs" do
    it "is skipped on non-Darwin hosts" do
      true.should be_true
    end
  end
{% end %}
