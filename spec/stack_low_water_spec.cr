require "./spec_helper"

# The low-water skip is a *correctness*-critical optimisation: it narrows the
# parked-fiber scan on the claim that a page with neither the present nor the
# swapped bit has never been faulted and is therefore zero. If that claim is
# ever wrong, roots go missing silently and nothing else in the suite notices.
#
# These pin the claim itself rather than the pause number it buys — on Darwin
# too, where the same claim rests on `mach_vm_page_range_query` instead of
# `/proc/self/pagemap` (`src/gcry/platform/darwin_low_water.cr`): a second
# implementation has to earn the assertion on its own.
private def low_water_page : UInt64
  Gcry::Roots.runtime_page_size
end

{% if flag?(:linux) || flag?(:darwin) %}
  describe "Gcry::Platform.stack_low_water" do
    it "reports the first touched page of a freshly mapped region" do
      len = 1024 * 1024
      map = Gcry::OS.mmap(Pointer(Void).null, LibC::SizeT.new(len),
        Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE,
        Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, LibC::OffT.new(0))
      map.address.should_not eq(0)
      low = map.address
      high = low + len

      begin
        page = low_water_page
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
        Gcry::OS.munmap(map, LibC::SizeT.new(len))
      end
    end

    it "never reports above a written word, scanning a whole region" do
      len = 512 * 1024
      map = Gcry::OS.mmap(Pointer(Void).null, LibC::SizeT.new(len),
        Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE,
        Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, LibC::OffT.new(0))
      low = map.address
      high = low + len

      begin
        page = low_water_page
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
        Gcry::OS.munmap(map, LibC::SizeT.new(len))
      end
    end

    it "degrades to the full range rather than narrowing it" do
      # An empty or inverted range must never produce something a caller would
      # read as "skip everything below this".
      Gcry::Platform.stack_low_water(4096_u64, 4096_u64).should eq(4096_u64)
      Gcry::Platform.stack_low_water(8192_u64, 4096_u64).should eq(8192_u64)
    end

    {% if flag?(:darwin) %}
      # Past 64 pages Darwin answers from the VM object's resident count, and
      # falls back to the per-page query whenever it cannot vouch for the
      # answer. Either way the answer must be the same as the per-page one, so
      # pin that on a stack-shaped region — 8 MiB, the first 4096 bytes
      # protected, as Crystal allocates a fiber stack — and require the
      # resident path to have answered at least once, or this pins nothing.
      it "answers a whole stack from the resident count, and the same as the per-page query" do
        page = low_water_page
        len = 8 * 1024 * 1024
        map = Gcry::OS.mmap(Pointer(Void).null, LibC::SizeT.new(len),
          Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE,
          Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, LibC::OffT.new(0))
        LibC.mprotect(map, LibC::SizeT.new(4096), LibC::PROT_NONE)
        low = map.address + 4096
        high = map.address + len
        begin
          hits = Gcry::Platform.resident_hits
          Gcry::Platform.stack_low_water(low, high).should eq(high)

          3.times { |k| Pointer(UInt8).new(high - (k + 1).to_u64 * page).value = 0x5a_u8 }
          Gcry::Platform.stack_low_water(low, high).should eq(high - 3 * page)

          # A written page far below an untouched gap: the count must send the
          # walk all the way down to it rather than stop under the top run.
          deep = map.address + 6 * page
          Pointer(UInt8).new(deep).value = 0x5a_u8
          Gcry::Platform.stack_low_water(low, high).should eq(deep)

          Gcry::Platform.resident_hits.should be > hits
        ensure
          Gcry::OS.munmap(map, LibC::SizeT.new(len))
        end
      end
    {% end %}
  end
{% end %}

# Windows has no page-level "was this touched" answer to pin; its mark is the
# base of the first region `VirtualQuery` reports committed and readable
# (`src/gcry/platform/windows_low_water.cr`). What has to hold is the same
# claim in that unit: nothing a scan could read lies below the mark, and the
# mark never sits above a word a fiber wrote.
{% if flag?(:win32) %}
  private def win_region(addr : UInt64) : LibC::MEMORY_BASIC_INFORMATION
    LibC.VirtualQuery(Pointer(Void).new(addr), out info, sizeof(LibC::MEMORY_BASIC_INFORMATION)).should_not eq(0)
    info
  end

  # Committed with no `PAGE_GUARD` and not `PAGE_NOACCESS` (1): a word in it can
  # be read, so it may hold a pointer.
  private def win_readable?(info : LibC::MEMORY_BASIC_INFORMATION) : Bool
    info.state == LibC::MEM_COMMIT && (info.protect & (LibC::PAGE_GUARD | 1)) == 0
  end

  # A KiB per frame, written, so the stack grows through its guard band one
  # page at a time the way a real call chain grows it.
  private def win_touch_stack(depth : Int32, deepest : UInt64*) : Nil
    buf = uninitialized UInt8[1024]
    buf.to_unsafe.clear(1024)
    addr = buf.to_unsafe.address
    deepest.value = addr if addr < deepest.value
    win_touch_stack(depth - 1, deepest) if depth > 0
    Gcry::Roots.keep_alive(buf.to_unsafe.as(Void*))
  end

  describe "Gcry::Platform.stack_low_water (win32)" do
    it "starts a fresh fiber stack above its reserved and guard head" do
      done = Channel(Nil).new
      fiber = spawn { done.send(nil) }
      begin
        stack = fiber.@stack
        guard = stack.pointer.address + Gcry::Roots.runtime_page_size
        bottom = stack.bottom.address
        top = fiber.@context.stack_top.address

        lw = Gcry::Platform.stack_low_water(guard, bottom)
        lw.should be > guard
        lw.should be <= top
        lw.should be < bottom
        win_readable?(win_region(lw)).should be_true

        # Nothing below the mark can be read, and the `PAGE_GUARD` band Crystal
        # commits under the top page is part of what was skipped — committed,
        # but never touched, or it would no longer be a guard.
        saw_guard = false
        cursor = guard
        while cursor < lw
          info = win_region(cursor)
          win_readable?(info).should be_false
          saw_guard = true if info.state == LibC::MEM_COMMIT && (info.protect & LibC::PAGE_GUARD) != 0
          cursor = info.baseAddress.address + info.regionSize
        end
        saw_guard.should be_true
      ensure
        done.receive
      end
    end

    it "stays at or below the deepest word a parked fiber wrote" do
      ready = Channel(Nil).new
      release = Channel(Nil).new
      deepest = Pointer(UInt64).malloc(1, UInt64::MAX)
      fiber = spawn do
        win_touch_stack(256, deepest)
        ready.send(nil)
        release.receive
      end
      ready.receive
      begin
        stack = fiber.@stack
        guard = stack.pointer.address + Gcry::Roots.runtime_page_size
        bottom = stack.bottom.address
        deepest.value.should be < bottom - 256_u64 * 1024

        lw = Gcry::Platform.stack_low_water(guard, bottom)
        lw.should be <= deepest.value
        lw.should be > guard
      ensure
        release.send(nil)
      end
    end

    it "skips reserved and guard regions, and never a committed read-write one" do
      page = Gcry::Platform.host_page_size
      len = 64_u64 * page
      base = LibC.VirtualAlloc(nil, LibC::SizeT.new(len), LibC::MEM_RESERVE, LibC::PAGE_READWRITE)
      base.null?.should be_false
      low = base.address
      high = low + len
      begin
        # Crystal's fiber layout in miniature: the top page committed, a guard
        # band under it, the rest reserved.
        LibC.VirtualAlloc(Pointer(Void).new(high - page), LibC::SizeT.new(page),
          LibC::MEM_COMMIT, LibC::PAGE_READWRITE).null?.should be_false
        LibC.VirtualAlloc(Pointer(Void).new(high - 3 * page), LibC::SizeT.new(2 * page),
          LibC::MEM_COMMIT, LibC::PAGE_READWRITE | LibC::PAGE_GUARD).null?.should be_false
        Gcry::Platform.stack_low_water(low, high).should eq(high - page)

        # A committed page far below the guard band, never written. Its
        # attributes cannot tell it from a written one, so the mark is there.
        mid = low + 8 * page
        LibC.VirtualAlloc(Pointer(Void).new(mid), LibC::SizeT.new(page),
          LibC::MEM_COMMIT, LibC::PAGE_READWRITE).null?.should be_false
        Gcry::Platform.stack_low_water(low, high).should eq(mid)

        # A range that starts inside a readable region skips nothing; one with
        # no readable region at all may be skipped whole.
        Gcry::Platform.stack_low_water(mid + 64, high).should eq(mid + 64)
        Gcry::Platform.stack_low_water(low, mid).should eq(mid)
      ensure
        LibC.VirtualFree(base, 0, LibC::MEM_RELEASE)
      end
    end

    it "degrades to the full range rather than narrowing it" do
      Gcry::Platform.stack_low_water(4096_u64, 4096_u64).should eq(4096_u64)
      Gcry::Platform.stack_low_water(8192_u64, 4096_u64).should eq(8192_u64)
      # Above the user address space `VirtualQuery` answers nothing, and the
      # probe must not read that as "untouched".
      kernel = 0xFFFF_8000_0000_0000_u64
      Gcry::Platform.stack_low_water(kernel, kernel + 8192).should eq(kernel)
    end
  end
{% end %}
