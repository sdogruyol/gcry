require "c/link"

module Gcry
  # Non-allocating static root discovery for Linux.
  #
  # The static roots are the executable's writable segments: every `PT_LOAD`
  # program header carrying `PF_W`, which is `.data` and `.bss` together
  # (`p_memsz` covers the zero-fill), minus the `PT_GNU_RELRO` window the
  # loader makes read-only before `main`. They come from `dl_iterate_phdr`,
  # whose first callback is the main program — the same headers the kernel
  # built the mappings from, read once at `GC.init` and never again.
  #
  # This replaces a `/proc/self/maps` parser, and the reasons are the record
  # of what that parser got wrong. It named the executable's `.data` by
  # pathname — first "not a `.so`", which admitted any file the program
  # `mmap`ed and scanned it after it was `munmap`ed (issue #29); then
  # "equals `/proc/self/exe`", which lost the executable the moment a
  # redeploy renamed its maps lines to `… (deleted)`. It found the BSS by
  # adjacency to that line, so losing `.data` lost the BSS with it. And the
  # file is not a snapshot: a mapping changing between two `read`s can drop a
  # line. Each of those is a collection in which no class variable is a root.
  # None of them can happen to a program header.
  module Platform
    struct RootRange
      property low : UInt64
      property high : UInt64

      def initialize(@low : UInt64, @high : UInt64)
      end
    end

    PT_LOAD      =          1_u32
    PT_GNU_RELRO = 0x6474e552_u32
    PF_W         =          2_u32
    PAGE_MASK    = ~4095_u64

    # An executable has a handful of `PT_LOAD`s; 32 is well past any linker.
    MAX_RANGES = 32

    @@ranges = uninitialized StaticArray(RootRange, MAX_RANGES)
    @@range_count = 0
    @@resolved = false
    @@bss_size_cap = false

    # `RELRO` window of the executable, as the loader protected it: both ends
    # rounded down to a page, which is what `_dl_protect_relro` does.
    @@relro_lo = 0_u64
    @@relro_hi = 0_u64

    # Writable segments the callback saw and refused for lack of a slot, and
    # resolutions that found no writable segment at all. Both must read zero;
    # either non-zero is a collection with no class variable rooted.
    @@static_root_overflow = 0_u64
    @@static_root_bss_lost = 0_u64

    def self.static_root_bss_lost : UInt64
      @@static_root_bss_lost
    end

    def self.static_root_overflow : UInt64
      @@static_root_overflow
    end

    def self.static_root_bytes : UInt64
      total = 0_u64
      i = 0
      while i < @@range_count
        total += @@ranges[i].high - @@ranges[i].low
        i += 1
      end
      total
    end

    # The executable's headers do not change, so there is nothing to refresh.
    # Kept because the collector and the fork handler call it on the same
    # schedule as Darwin's cache.
    def self.invalidate_static_root_cache : Nil
    end

    def self.scan_static_roots(& : Void*, Void* ->) : Nil
      {% if flag?(:linux) %}
        ensure_static_root_cache
        i = 0
        while i < @@range_count
          yield Pointer(Void).new(@@ranges[i].low), Pointer(Void).new(@@ranges[i].high)
          i += 1
        end
      {% end %}
    end

    # Resolve at `GC.init`, on the main thread, before any other thread exists:
    # `dl_iterate_phdr` takes the loader's lock, and a stopped world may hold
    # it. The executable is the object whose segments contain one of this
    # module's own words — not "the first object visited", which on some
    # loaders is the dynamic linker.
    def self.ensure_static_root_cache : Nil
      {% if flag?(:linux) %}
        return if @@resolved
        @@resolved = true
        @@range_count = 0
        @@relro_lo = 0_u64
        @@relro_hi = 0_u64
        LibC.dl_iterate_phdr(->(info : LibC::DlPhdrInfo*, size : LibC::SizeT, data : Void*) {
          if Platform.holds_probe?(info)
            Platform.take_executable_segments(info)
            1
          else
            0
          end
        }, Pointer(Void).null)
        apply_relro

        if @@range_count == 0
          @@static_root_bss_lost &+= 1
          buf = uninitialized UInt8[160]
          len = RawOut.append(buf.to_unsafe, 0,
            "gcry: no object's writable PT_LOAD holds gcry's statics — no class variable is a root\n")
          RawOut.flush(buf.to_unsafe, len)
        end
      {% end %}
    end

    # :nodoc:
    def self.holds_probe?(info : LibC::DlPhdrInfo*) : Bool
      probe = pointerof(@@resolved).address
      base = info.value.addr.to_u64
      phdr = info.value.phdr
      n = info.value.phnum.to_i32
      i = 0
      while i < n
        ph = (phdr + i).value
        if ph.type == PT_LOAD
          lo = base &+ ph.vaddr.to_u64
          return true if lo <= probe && probe < lo &+ ph.memsz.to_u64
        end
        i += 1
      end
      false
    end

    # :nodoc:
    def self.take_executable_segments(info : LibC::DlPhdrInfo*) : Nil
      base = info.value.addr.to_u64
      phdr = info.value.phdr
      n = info.value.phnum.to_i32
      i = 0
      while i < n
        ph = (phdr + i).value
        lo = base &+ ph.vaddr.to_u64
        hi = lo &+ ph.memsz.to_u64
        if ph.type == PT_GNU_RELRO
          @@relro_lo = lo & PAGE_MASK
          @@relro_hi = hi & PAGE_MASK
        elsif ph.type == PT_LOAD && (ph.flags & PF_W) != 0 && hi > lo
          # `GCRY_STATIC_BSS_CAP=1`: refuse the segment above 1 MiB, as the
          # maps parser did before 2026-08-22, so `make static-bss-roots` can
          # show the block dying.
          if @@bss_size_cap && hi - lo >= 1_u64 * 1024 * 1024
            i += 1
            next
          end
          if @@range_count < MAX_RANGES
            @@ranges[@@range_count] = RootRange.new(lo, hi)
            @@range_count += 1
          else
            @@static_root_overflow &+= 1
          end
        end
        i += 1
      end
    end

    # Cut the read-only-after-relocation window out of whichever segment holds
    # it. Nothing the mutator can write lives there, and on a fat Crystal
    # binary it is megabytes of type tables.
    private def self.apply_relro : Nil
      return if @@relro_hi <= @@relro_lo
      i = 0
      while i < @@range_count
        r = @@ranges[i]
        if @@relro_lo <= r.low && r.high <= @@relro_hi
          # Whole segment is RELRO: drop it.
          @@range_count -= 1
          @@ranges[i] = @@ranges[@@range_count]
          next
        elsif @@relro_lo <= r.low && r.low < @@relro_hi
          @@ranges[i] = RootRange.new(@@relro_hi, r.high)
        elsif r.low < @@relro_lo && @@relro_hi < r.high
          # RELRO strictly inside: keep both sides.
          @@ranges[i] = RootRange.new(r.low, @@relro_lo)
          if @@range_count < MAX_RANGES
            @@ranges[@@range_count] = RootRange.new(@@relro_hi, r.high)
            @@range_count += 1
          else
            @@static_root_overflow &+= 1
          end
        elsif r.low < @@relro_lo && @@relro_lo < r.high
          @@ranges[i] = RootRange.new(r.low, @@relro_lo)
        end
        i += 1
      end
    end

    # Research only: refuse a writable segment larger than 1 MiB, as the maps
    # parser did before 2026-08-22.
    def self.bss_size_cap=(value : Bool) : Bool
      @@resolved = false
      @@bss_size_cap = value
    end
  end
end
