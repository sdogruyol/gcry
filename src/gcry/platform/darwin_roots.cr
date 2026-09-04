# Non-allocating static root discovery for Darwin (dyld image walk).
#
# Main executable `__DATA` / `__DATA_CONST` sections hold Crystal class/global
# vars; system dylibs are skipped (same policy as Linux skipping `.so`).
#
# Ranges are cached in a fixed table. There is no `realloc` on this path on
# purpose: `GC.init` resolves the cache eagerly, before `Crystal.main` reaches
# `init_runtime`, and a `raise` there cannot run.

require "c/stdlib"

module Gcry
  module Platform
    {% if flag?(:darwin) %}
      lib LibDyld
        struct MachHeader64
          magic : UInt32
          cputype : Int32
          cpusubtype : Int32
          filetype : UInt32
          ncmds : UInt32
          sizeofcmds : UInt32
          flags : UInt32
          reserved : UInt32
        end

        struct LoadCommand
          cmd : UInt32
          cmdsize : UInt32
        end

        struct SegmentCommand64
          cmd : UInt32
          cmdsize : UInt32
          segname : StaticArray(UInt8, 16)
          vmaddr : UInt64
          vmsize : UInt64
          fileoff : UInt64
          filesize : UInt64
          maxprot : Int32
          initprot : Int32
          nsects : UInt32
          flags : UInt32
        end

        struct Section64
          sectname : StaticArray(UInt8, 16)
          segname : StaticArray(UInt8, 16)
          addr : UInt64
          size : UInt64
          offset : UInt32
          align : UInt32
          reloff : UInt32
          nreloc : UInt32
          flags : UInt32
          reserved1 : UInt32
          reserved2 : UInt32
          reserved3 : UInt32
        end

        fun _dyld_image_count : UInt32
        fun _dyld_get_image_header(image_index : UInt32) : MachHeader64*
        fun _dyld_get_image_vmaddr_slide(image_index : UInt32) : Int64
      end

      LC_SEGMENT_64 =       0x19_u32
      MH_MAGIC_64   = 0xfeedfacf_u32

      # SECTION_TYPE bits that mark thread-local storage — not process-global
      # roots.
      S_THREAD_LOCAL_REGULAR                = 0x11_u32
      S_THREAD_LOCAL_ZEROFILL               = 0x12_u32
      S_THREAD_LOCAL_VARIABLES              = 0x13_u32
      S_THREAD_LOCAL_VARIABLE_POINTERS      = 0x14_u32
      S_THREAD_LOCAL_INIT_FUNCTION_POINTERS = 0x15_u32
      SECTION_TYPE_MASK                     = 0xff_u32

      # A Mach-O executable has a handful of `__DATA*` sections. 32 is well
      # past any linker, and the same bound Linux uses.
      MAX_RANGES = 32

      struct RootRange
        property low : UInt64
        property high : UInt64

        def initialize(@low : UInt64, @high : UInt64)
        end
      end

      # None of these may compile to a `once`-guarded lazy initialiser.
      #
      # `GC.init` resolves this cache eagerly, and `GC.init` runs before
      # `Crystal.main` reaches `init_runtime`. `__crystal_once` reads
      # `Fiber.current` there, which builds a `Thread`, which builds a
      # `Fiber`, which pushes onto `Fiber.@@fibers` — a class variable
      # `Fiber.init` has not created yet. Null receiver, `EXC_BAD_ACCESS` at
      # 0x18, before `main`. Crystal's own `init_runtime` says so in a comment:
      # "__crystal_once directly or indirectly depends on Fiber and Thread".
      # That is CI run 33900305015, attributed on a Darwin host 2026-09-04.
      #
      # The compiler's rule: a *simple literal* initialiser becomes the LLVM
      # global's own initialiser and is read directly, while a call
      # (`Pointer(T).null`) or a constant path (`UInt32::MAX`) also gets a
      # `~var:read` accessor that calls `__crystal_once` on every read — even
      # though the folded value is already sitting in the global, so the
      # guarded store changes nothing. `@@ranges` and `@@cached_generation`
      # were the two, and the accessor for `cached_generation` was
      # `ensure_static_root_cache`'s first instruction. `linux_stw.cr` records
      # the same mechanism for a class-var `Atomic.new`.
      #
      # `make darwin-static-root-init` is the gate. `-Dgcry_static_root_once`
      # is its red arm. It restores the `@@cached_generation` one — the
      # accessor that was `ensure_static_root_cache`'s first instruction. There
      # is no `@@ranges` arm any more because the pointer-plus-`realloc` table
      # it guarded is gone; the fixed `StaticArray` needs no initialiser at all.
      {% if flag?(:gcry_static_root_once) %}
        @@cached_generation = UInt32::MAX
      {% else %}
        # `UInt32::MAX` spelled out, for the reason above. The value only has
        # to differ from `@@maps_generation`'s start, and even that is belt and
        # braces: `@@range_count > 0` is what forces the first resolve.
        @@cached_generation = 4294967295_u32
      {% end %}
      @@ranges = uninitialized StaticArray(RootRange, MAX_RANGES)
      @@range_count = 0
      @@maps_generation = 0_u32
      # Times the dyld walk actually ran. `GC.init` must leave this at 1, which
      # is how `bench/darwin_static_root_init.cr` tells an eager resolve from
      # the lazy one that used to `realloc` inside the first stopped world.
      @@resolves = 0_u64
      # Writable sections the walk saw and refused for lack of a slot, and
      # resolutions that found no writable section at all. Both must read zero;
      # either non-zero is a collection with no class variable rooted. Both
      # were hardcoded `0` before 2026-09-04, which reported soundness rather
      # than measuring it.
      @@overflow = 0_u64
      @@bss_lost = 0_u64

      def self.invalidate_static_root_cache : Nil
        @@maps_generation &+= 1
      end

      def self.scan_static_roots(& : Void*, Void* ->) : Nil
        ensure_static_root_cache
        i = 0
        while i < @@range_count
          r = @@ranges[i]
          yield Pointer(Void).new(r.low), Pointer(Void).new(r.high)
          i += 1
        end
      end

      # Counters `/gc-stats` reports on both platforms; the Linux side reads
      # the ELF program headers, this side the Mach-O sections.
      def self.static_root_bytes : UInt64
        total = 0_u64
        i = 0
        while i < @@range_count
          r = @@ranges[i]
          total += r.high - r.low
          i += 1
        end
        total
      end

      def self.static_root_bss_lost : UInt64
        @@bss_lost
      end

      def self.static_root_overflow : UInt64
        @@overflow
      end

      # How many times the dyld walk ran. Linux counts the same thing over
      # `dl_iterate_phdr`. One after `GC.init` and one forever after is the
      # eager resolve; zero there means the first walk is still happening
      # inside a stopped world, which is what it did until 2026-09-04.
      def self.static_root_resolves : UInt64
        @@resolves
      end

      # Public for the same reason `bss_size_cap=` is: `GC.init` resolves the
      # static roots eagerly on both platforms, and a caller that gates on a
      # platform must not have to ask which one it is on. Private here
      # compiled only because the call site carried a `flag?(:linux)` macro
      # guard — the asymmetry that broke the macOS build on 2026-08-22
      # (Makefile, `darwin-typecheck`).
      # (Written without macro delimiters on purpose: Crystal's lexer reads
      # them inside comments too, and one here swallowed this file's own
      # `end` and left the darwin guard unterminated.)
      def self.ensure_static_root_cache : Nil
        return if @@cached_generation == @@maps_generation && @@range_count > 0

        @@range_count = 0
        @@resolves &+= 1
        scan_dyld_static_roots do |low, high|
          push_range(low.address, high.address)
        end

        # Latch only on success, the same way Linux does: a resolution that
        # came back with nothing must be retried rather than remembered, or
        # the process runs for its whole life with an empty root set while the
        # counter cannot tell one bad collection from all of them.
        if @@range_count > 0
          @@cached_generation = @@maps_generation
          return
        end

        @@bss_lost &+= 1
        if @@bss_lost == 1
          buf = uninitialized UInt8[160]
          len = RawOut.append(buf.to_unsafe, 0,
            "gcry: the executable has no writable __DATA section — no class variable is a root\n")
          RawOut.flush(buf.to_unsafe, len)
        end
      end

      # Fixed table, no `realloc`. This runs inside `GC.init`, where a `raise`
      # cannot unwind and `LibC.realloc` would take the malloc arena before
      # the runtime exists — and where, until 2026-09-04, the failure branch
      # reached `OutOfMemoryError.new` -> managed malloc -> a `once`-guarded
      # trace counter.
      private def self.push_range(lo : UInt64, hi : UInt64) : Nil
        return if hi <= lo
        if @@range_count < MAX_RANGES
          @@ranges[@@range_count] = RootRange.new(lo, hi)
          @@range_count += 1
        else
          @@overflow &+= 1
        end
      end

      private def self.scan_dyld_static_roots(& : Void*, Void* ->) : Nil
        # Image 0 is the main executable — Crystal class/global vars live there.
        mh = LibDyld._dyld_get_image_header(0_u32)
        return if mh.null?
        return unless mh.value.magic == MH_MAGIC_64

        slide = LibDyld._dyld_get_image_vmaddr_slide(0_u32).to_u64!
        p = Pointer(UInt8).new(mh.address + sizeof(LibDyld::MachHeader64))
        cmd_i = 0_u32
        while cmd_i < mh.value.ncmds
          lc = p.as(LibDyld::LoadCommand*)
          if lc.value.cmd == LC_SEGMENT_64
            seg = p.as(LibDyld::SegmentCommand64*)
            if segment_is_data?(seg.value.segname)
              sect = Pointer(LibDyld::Section64).new(p.address + sizeof(LibDyld::SegmentCommand64))
              j = 0_u32
              while j < seg.value.nsects
                maybe_yield_section(sect + j, slide) { |a, b| yield a, b }
                j += 1
              end
            end
          end
          p += lc.value.cmdsize
          cmd_i += 1
        end
      end

      private def self.segment_is_data?(segname : StaticArray(UInt8, 16)) : Bool
        # __DATA, __DATA_CONST, __DATA_DIRTY, …
        segname[0] == '_'.ord.to_u8 &&
          segname[1] == '_'.ord.to_u8 &&
          segname[2] == 'D'.ord.to_u8 &&
          segname[3] == 'A'.ord.to_u8 &&
          segname[4] == 'T'.ord.to_u8 &&
          segname[5] == 'A'.ord.to_u8
      end

      private def self.maybe_yield_section(sect : LibDyld::Section64*, slide : UInt64, & : Void*, Void* ->) : Nil
        size = sect.value.size
        return if size == 0

        typ = sect.value.flags & SECTION_TYPE_MASK
        case typ
        when S_THREAD_LOCAL_REGULAR, S_THREAD_LOCAL_ZEROFILL,
             S_THREAD_LOCAL_VARIABLES, S_THREAD_LOCAL_VARIABLE_POINTERS,
             S_THREAD_LOCAL_INIT_FUNCTION_POINTERS
          return
        end

        return unless section_is_root_candidate?(sect.value.sectname)

        # Never scan __DATA_CONST.__const — pointer-dense literal pools with
        # almost no true GC roots; word-scanning it inflates false retention.
        # Writable / zerofill (__data, __bss, __common) are the real class vars.
        if section_name_eq?(sect.value.sectname, "__const")
          return
        end

        lo = sect.value.addr &+ slide
        hi = lo &+ size
        yield Pointer(Void).new(lo), Pointer(Void).new(hi)
      end

      private def self.section_is_root_candidate?(sectname : StaticArray(UInt8, 16)) : Bool
        section_name_eq?(sectname, "__data") ||
          section_name_eq?(sectname, "__bss") ||
          section_name_eq?(sectname, "__common")
      end

      private def self.section_name_eq?(sectname : StaticArray(UInt8, 16), want : String) : Bool
        i = 0
        while i < want.bytesize
          return false if sectname[i] != want.to_unsafe[i]
          i += 1
        end
        # Section names are fixed 16-byte fields; accept exact or NUL-padded.
        i == want.bytesize && (i == 16 || sectname[i] == 0)
      end

      # Linux reads the executable's writable `PT_LOAD`s and used to refuse a
      # BSS above 1 MiB (`linux_roots.cr`). Darwin reads the Mach-O `__DATA`
      # sections directly, so there is no adjacency guess and nothing to cap —
      # but the knob is wired unconditionally in `GC.init`, and a caller that
      # gates on a platform must not have to ask which one it is on.
      def self.bss_size_cap=(value : Bool) : Bool
        value
      end
    {% end %}
  end
end
