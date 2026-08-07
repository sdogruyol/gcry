require "./spec_helper"

# The low-water skip is a *correctness*-critical optimisation: it narrows the
# parked-fiber scan on the claim that a page with neither the present nor the
# swapped bit has never been faulted and is therefore zero. If that claim is
# ever wrong, roots go missing silently and nothing else in the suite notices.
#
# These pin the claim itself rather than the pause number it buys.
{% if flag?(:linux) %}
  describe "Gcry::Platform.stack_low_water" do
    it "reports the first touched page of a freshly mapped region" do
      len = 1024 * 1024
      map = LibC.mmap(Pointer(Void).null, LibC::SizeT.new(len),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS, -1, LibC::OffT.new(0))
      map.address.should_not eq(0)
      low = map.address
      high = low + len

      begin
        page = Gcry::Roots::PAGE_SIZE
        # Untouched throughout: nothing can hold a pointer, so the whole range
        # may be skipped.
        Gcry::Platform.stack_low_water(low, high).should eq(high)

        # Touch one page in the middle. The mark must not sit above it — that
        # would skip a written word.
        target = low + (len // 2)
        Pointer(UInt8).new(target).value = 0x5a_u8
        mark = Gcry::Platform.stack_low_water(low, high)
        mark.should be <= target
        mark.should be >= low

        # Touching lower moves the mark down, never up.
        lower = low + page
        Pointer(UInt8).new(lower).value = 0x5a_u8
        Gcry::Platform.stack_low_water(low, high).should be <= lower
      ensure
        LibC.munmap(map, LibC::SizeT.new(len))
      end
    end

    it "never reports above a written word, scanning a whole region" do
      len = 512 * 1024
      map = LibC.mmap(Pointer(Void).null, LibC::SizeT.new(len),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS, -1, LibC::OffT.new(0))
      low = map.address
      high = low + len

      begin
        page = Gcry::Roots::PAGE_SIZE
        # Write a marker on every page, then assert the reported mark is at or
        # below the lowest of them — i.e. the scan that starts there still
        # covers every written word.
        addr = low
        while addr < high
          Pointer(UInt8).new(addr).value = 0x7f_u8
          addr += page
        end
        Gcry::Platform.stack_low_water(low, high).should eq(low)
      ensure
        LibC.munmap(map, LibC::SizeT.new(len))
      end
    end

    it "degrades to the full range rather than narrowing it" do
      # An empty or inverted range must never produce something a caller would
      # read as "skip everything below this".
      Gcry::Platform.stack_low_water(4096_u64, 4096_u64).should eq(4096_u64)
      Gcry::Platform.stack_low_water(8192_u64, 4096_u64).should eq(8192_u64)
    end
  end
{% end %}
