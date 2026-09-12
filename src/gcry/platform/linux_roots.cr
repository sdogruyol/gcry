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
    PT_TLS       =          7_u32
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

    # Walks of the program headers that actually ran. Darwin counts its dyld
    # walks the same way, and for the same reason: `GC.init` resolving the
    # roots eagerly must leave this at 1, and a 0 there means the first walk
    # is happening inside a stopped world.
    @@resolves = 0_u64

    def self.static_root_resolves : UInt64
      @@resolves
    end

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
        @@range_count = 0
        @@relro_lo = 0_u64
        @@relro_hi = 0_u64
        @@resolves &+= 1
        LibC.dl_iterate_phdr(->(info : LibC::DlPhdrInfo*, size : LibC::SizeT, data : Void*) {
          if Platform.holds_probe?(info)
            Platform.take_executable_segments(info)
            1
          else
            0
          end
        }, Pointer(Void).null)
        apply_relro
        take_main_thread_tls

        # Latch only on success. Setting this before the walk — which is what
        # it did until 2026-09-04 — meant a resolution that came back with
        # nothing was never retried: the process warned once and then ran for
        # its whole life with an empty root set, sweeping everything held only
        # by a class variable, while `static_root_bss_lost` sat at 1 and could
        # no longer tell "one collection lost the roots" from "every
        # collection since boot had none". `scan_static_roots` calls this per
        # collection, so leaving it unlatched retries and keeps counting.
        if @@range_count > 0
          @@resolved = true
          return
        end

        @@static_root_bss_lost &+= 1
        if @@static_root_bss_lost == 1
          buf = uninitialized UInt8[160]
          len = RawOut.append(buf.to_unsafe, 0,
            "gcry: no object's writable PT_LOAD holds gcry's statics — no class variable is a root\n")
          RawOut.flush(buf.to_unsafe, len)
        end
      {% end %}
    end

    # A gcry-owned thread-local, used only for its **address**: it is inside
    # the running thread's static TLS block, which is the one thing that can
    # locate it portably. `uninitialized` rather than `= 0_u64` — a class
    # variable with an initialiser is set up lazily behind `__crystal_once`,
    # and this one is read from `GC.init` before `Fiber.init` has run, which is
    # the shape that crashed before `main` on Darwin (see
    # `GCRY_STATIC_ROOT_LAZY`). The value is never read, only the address.
    @[ThreadLocal]
    @@tls_anchor = uninitialized UInt64

    # `GCRY_TLS_ROOTS=0` drops this range; `make tls-roots` needs that arm to
    # lose the block.
    @@tls_roots = true
    @@tls_lo = 0_u64
    @@tls_hi = 0_u64
    # The executable's `PT_TLS` geometry, read in the same walk that takes its
    # writable `PT_LOAD`s.
    @@tls_memsz = 0_u64
    @@tls_align = 0_u64

    def self.tls_roots=(value : Bool) : Bool
      @@resolved = false
      @@tls_roots = value
    end

    def self.tls_root_range : {UInt64, UInt64}
      {@@tls_lo, @@tls_hi}
    end

    # The main thread's thread-local storage is a root, and it was not one.
    #
    # `dl_iterate_phdr` gives the executable's writable `PT_LOAD` segments, so
    # every class variable is covered. A **thread-local** is not in those
    # segments: `PT_TLS` is only the template, and the live block is allocated
    # per thread. For a spawned thread glibc puts the descriptor and static
    # TLS at the top of the thread's own stack mapping — inside the bounds
    # `pthread_getattr_np` reports and above the suspend SP, so the ordinary
    # stack scan covers it (measured: tls `0x7f9daf5fe6b0` inside
    # `[0x7f9daedff000, 0x7f9daf5ff000)`). The **main** thread's block is not
    # anywhere near its stack — the loader allocates it with the shared
    # libraries (measured: tls `0x7f9db13e0770` against a stack of
    # `[0x7ffc1e8e9000, 0x7ffc1f0e6000)`) — and nothing scanned it.
    #
    # So a pointer whose only copy was a main-thread thread-local was
    # collected. `make tls-roots` shows it: the block dies with this range
    # dropped and lives with it in, against a control that holds the pointer
    # nowhere and must die either way.
    #
    # That is the third branch of what `GCRY_POISON_HOLDERS=1` says on every
    # use-after-free this heap produces — *"the pointer is in a register, in
    # thread-local storage, or in memory gcry never mapped"* — and the only
    # one that had never been tested. It is **not** the open live-large-object
    # release, which is what prompted looking here: `GCRY_TLS_ROOTS` does not
    # move that rate either (15 of 18 against 14 of 18 on the committed
    # harness), and the 824 KiB first version that appeared to was retaining
    # garbage. `bench/log/linux/2026-09-12-tls-not-a-root/FINDINGS.md`.
    #
    # Sized from the executable's own `PT_TLS`, not from the mapping that
    # contains it. The mapping was the first version and it measured 824 KiB
    # on this binary — the loader shares it with data that has nothing to do
    # with this program's thread-locals, so scanning it per collection would
    # both cost ~100k words and conservatively retain all of it. `PT_TLS`
    # `p_memsz` is exactly the executable's TLS block; the anchor is inside
    # that block, so a window of `memsz` either side of the anchor covers it
    # wherever in the block the anchor happens to sit, without depending on
    # the variant-II rule that the block ends at the thread pointer. Clipped
    # to the containing writable mapping, so a window wider than the block
    # can never reach an unmapped page.
    #
    # Resolved at `GC.init`, on the main thread, which is the only context
    # that can take the address of its own thread-local — and the same
    # context this cache is already built in.
    private def self.take_main_thread_tls : Nil
      {% if flag?(:linux) %}
        return unless @@tls_roots
        @@tls_lo = 0_u64
        @@tls_hi = 0_u64
        # No `PT_TLS` in the executable means it declares no thread-locals,
        # and there is nothing to cover.
        return if @@tls_memsz == 0
        anchor = pointerof(@@tls_anchor).address
        return if anchor == 0
        span = @@tls_memsz
        align = @@tls_align
        span = (span &+ align &- 1) & ~(align &- 1) if align > 1
        lo = anchor > span ? (anchor &- span) & ~7_u64 : 0_u64
        hi = (anchor &+ span &+ 7) & ~7_u64
        # Clip to the mapping the anchor is in: the window is deliberately
        # wider than the block, and the excess must not leave the mapping.
        clipped = false
        Platform.each_map_region do |rlo, rhi, perms, _name, _len|
          next unless anchor >= rlo && anchor < rhi
          next unless perms[1] == 'w'.ord.to_u8
          lo = rlo if lo < rlo
          hi = rhi if hi > rhi
          clipped = true
        end
        return unless clipped
        return if hi <= lo
        # Already covered — a spawned thread's TLS sits in its stack mapping,
        # and on some libcs the main thread's may fall inside a segment the
        # phdr walk already took.
        i = 0
        while i < @@range_count
          r = @@ranges[i]
          return if r.low <= anchor && anchor < r.high
          i += 1
        end
        if @@range_count < MAX_RANGES
          @@ranges[@@range_count] = RootRange.new(lo, hi)
          @@range_count += 1
          @@tls_lo = lo
          @@tls_hi = hi
        else
          @@static_root_overflow &+= 1
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
        if ph.type == PT_TLS
          # Not a range: the segment is the *template*, and the live block is
          # elsewhere. Only its size is wanted - see `take_main_thread_tls`.
          @@tls_memsz = ph.memsz.to_u64
          @@tls_align = ph.align.to_u64
        elsif ph.type == PT_GNU_RELRO
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
