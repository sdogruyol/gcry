# Non-allocating static root discovery for Darwin (dyld image walk).
#
# The static roots are every loaded image's writable data: every section of
# a `__DATA*` segment whose `initprot` carries `VM_PROT_WRITE`, minus the
# segments dyld makes read-only once it has applied the fixups (`SG_READ_ONLY`),
# minus thread-local storage. The executable is resolved here, with its TLS
# block; every other image — system dylibs included, as Boehm scans them — is
# reported by dyld's add/remove-image callbacks (see `dyld_image_added`).
#
# That set is **derived**, not named, and the difference is the record of what
# the previous version got wrong. It was a name allow-list — `__data`, `__bss`,
# `__common`, with `__const` explicitly refused — so a linker that renamed a
# section or added one dropped a root class silently, and a dropped root class
# sweeps a live object. Linux has been derived-by-construction since v0.21.x
# (`linux_roots.cr`: writable `PT_LOAD` minus `PT_GNU_RELRO`); this is the same
# rule on Mach-O.
#
# `SG_READ_ONLY` is the term that had to be measured rather than assumed, and
# `bench/darwin_static_root_sections.cr` is what measured it. `__DATA_CONST`
# reports `initprot=0x3` (READ|WRITE) in the load command, so "writable
# `initprot`" alone admits it — but its segment flags carry `SG_READ_ONLY` and
# `mach_vm_region` reports the pages `r--` at runtime. Admitting it would
# word-scan ~18 KiB of pointer-dense literal pool the mutator cannot write:
# false retention, no roots. It is the Mach-O `PT_GNU_RELRO`, and subtracting
# it is what makes the two platforms the same rule rather than two rules that
# happen to agree.
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
        fun _dyld_register_func_for_add_image(func : MachHeader64*, Int64 -> Void)
        fun _dyld_register_func_for_remove_image(func : MachHeader64*, Int64 -> Void)
      end

      # One-region query for the mapping that contains a thread-local. The full
      # `each_map_region` walk is still refused in `darwin_stubs.cr` — nothing
      # has measured it — but clipping one address is what `take_main_thread_tls`
      # needs, and `bench/darwin_static_root_sections.cr` already uses this
      # call for the same reason.
      lib LibMachVM
        alias Port = UInt32
        alias KernReturn = Int32

        $mach_task_self_ : Port

        fun mach_vm_region(
          target_task : Port,
          address : UInt64*,
          size : UInt64*,
          flavor : Int32,
          info : Int32*,
          info_count : UInt32*,
          object_name : Port*,
        ) : KernReturn
      end

      LC_SEGMENT_64 =       0x19_u32
      MH_MAGIC_64   = 0xfeedfacf_u32

      # <mach/vm_prot.h>
      VM_PROT_WRITE   = 0x2
      VM_PROT_EXECUTE = 0x4

      # <mach/vm_region.h>. Same constants `darwin_static_root_sections.cr`
      # transcribes; a wrong count fails the call rather than returning a
      # plausible empty region.
      VM_REGION_BASIC_INFO_64       =      9
      VM_REGION_BASIC_INFO_COUNT_64 = 10_u32

      # <mach-o/loader.h>. dyld mprotects a segment carrying this read-only
      # after applying fixups — the Mach-O `PT_GNU_RELRO`.
      SG_READ_ONLY = 0x10_u32

      # SECTION_TYPE bits that mark thread-local storage — not process-global
      # roots. What these sections hold is the *initialisation template*: the
      # per-thread blocks are allocated by `tlv_allocate_and_initialize` and
      # live elsewhere, so scanning the template finds nothing a thread holds.
      # Measured: `__thread_vars` 48 B, `__thread_data` 4 B, `__thread_bss` 8 B
      # on a fat gcry binary, and no heap-owned word in any of them
      # (`bench/darwin_static_root_sections.cr`).
      S_THREAD_LOCAL_REGULAR                = 0x11_u32
      S_THREAD_LOCAL_ZEROFILL               = 0x12_u32
      S_THREAD_LOCAL_VARIABLES              = 0x13_u32
      S_THREAD_LOCAL_VARIABLE_POINTERS      = 0x14_u32
      S_THREAD_LOCAL_INIT_FUNCTION_POINTERS = 0x15_u32
      SECTION_TYPE_MASK                     = 0xff_u32

      # A Mach-O executable has a handful of writable `__DATA*` sections — two
      # on a default link (`__data`, `__common`), four under `-no_data_const`
      # (`__got` and `__const` join them). 32 is well past any linker, and the
      # same bound Linux uses.
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
      @@bss_size_cap = false

      # A gcry-owned thread-local, used only for its **address**: it is inside
      # the running thread's TLV block, which is the one thing that can locate
      # it. `uninitialized` rather than `= 0_u64` — see the once-guard note
      # above. The value is never read, only the address.
      @[ThreadLocal]
      @@tls_anchor = uninitialized UInt64

      # `GCRY_TLS_ROOTS=0` drops this range; `make tls-roots` needs that arm to
      # lose the block. `true` is a simple literal, so it is the LLVM global's
      # own initialiser and does not go through `__crystal_once`.
      @@tls_roots = true
      @@tls_lo = 0_u64
      @@tls_hi = 0_u64
      @@tls_taken = false
      # Sum of `__thread_data` + `__thread_bss` in the executable — the TLV
      # *payload*, not `__thread_vars` (descriptors). The live block dyld
      # allocates is this size; the template itself is skipped as a root.
      @@tls_memsz = 0_u64
      @@tls_align = 0_u64
      # Load bias and executable segment, for the crash report's writer-frame
      # walk. Zero until `GC.init` resolves the statics.
      @@exe_bias = 0_u64
      @@text_lo = 0_u64
      @@text_hi = 0_u64

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
        scan_image_roots { |low, high| yield low, high }
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
        @@tls_memsz = 0_u64
        @@tls_align = 0_u64
        @@exe_bias = 0_u64
        @@text_lo = 0_u64
        @@text_hi = 0_u64
        @@resolves &+= 1
        scan_dyld_static_roots do |low, high|
          push_range(low.address, high.address)
        end
        take_main_thread_tls
        register_image_callbacks

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
          buf = uninitialized UInt8[RawOut::LIMIT]
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
        @@exe_mh = mh.address

        slide = LibDyld._dyld_get_image_vmaddr_slide(0_u32).to_u64!
        @@exe_bias = slide
        p = Pointer(UInt8).new(mh.address + sizeof(LibDyld::MachHeader64))
        cmd_i = 0_u32
        while cmd_i < mh.value.ncmds
          lc = p.as(LibDyld::LoadCommand*)
          if lc.value.cmd == LC_SEGMENT_64
            seg = p.as(LibDyld::SegmentCommand64*)
            note_text_segment(seg, slide)
            # Walk every `__DATA*` section: root-holding ones are yielded,
            # TLS payload sizes are recorded even when the segment is not a
            # static root (`SG_READ_ONLY` / non-writable), so `PT_TLS`
            # geometry is not lost with the template.
            if segment_is_data?(seg.value.segname)
              sect = Pointer(LibDyld::Section64).new(p.address + sizeof(LibDyld::SegmentCommand64))
              hold = segment_holds_roots?(seg)
              j = 0_u32
              while j < seg.value.nsects
                maybe_yield_section(sect + j, slide, hold) { |a, b| yield a, b }
                j += 1
              end
            end
          end
          p += lc.value.cmdsize
          cmd_i += 1
        end
      end

      # Writable, and not made read-only after the fixups. Linux's exact rule,
      # spelled in Mach-O.
      private def self.segment_holds_roots?(seg : LibDyld::SegmentCommand64*) : Bool
        return false unless segment_is_data?(seg.value.segname)
        return false if (seg.value.initprot & VM_PROT_WRITE) == 0
        (seg.value.flags & SG_READ_ONLY) == 0
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

      private def self.segment_is_text?(segname : StaticArray(UInt8, 16)) : Bool
        segname[0] == '_'.ord.to_u8 &&
          segname[1] == '_'.ord.to_u8 &&
          segname[2] == 'T'.ord.to_u8 &&
          segname[3] == 'E'.ord.to_u8 &&
          segname[4] == 'X'.ord.to_u8 &&
          segname[5] == 'T'.ord.to_u8
      end

      private def self.note_text_segment(seg : LibDyld::SegmentCommand64*, slide : UInt64) : Nil
        return unless segment_is_text?(seg.value.segname)
        return if (seg.value.initprot & VM_PROT_EXECUTE) == 0
        lo = seg.value.vmaddr &+ slide
        hi = lo &+ seg.value.vmsize
        return unless hi > lo
        @@text_lo = lo
        @@text_hi = hi
      end

      def self.exe_bias : UInt64
        @@exe_bias
      end

      def self.exe_text?(addr : UInt64) : Bool
        @@text_hi > @@text_lo && addr >= @@text_lo && addr < @@text_hi
      end

      private def self.maybe_yield_section(sect : LibDyld::Section64*, slide : UInt64, hold : Bool, & : Void*, Void* ->) : Nil
        size = sect.value.size
        return if size == 0

        typ = sect.value.flags & SECTION_TYPE_MASK
        case typ
        when S_THREAD_LOCAL_REGULAR, S_THREAD_LOCAL_ZEROFILL
          # Payload size of the executable's TLV block. Not a root: the
          # template holds initialisers, not the pointer a thread is using.
          @@tls_memsz &+= size
          align_bytes = 1_u64 << sect.value.align.to_u64
          @@tls_align = align_bytes if align_bytes > @@tls_align
          return
        when S_THREAD_LOCAL_VARIABLES, S_THREAD_LOCAL_VARIABLE_POINTERS,
             S_THREAD_LOCAL_INIT_FUNCTION_POINTERS
          return
        end

        return unless hold

        # `GCRY_STATIC_BSS_CAP=1`: refuse a section of 1 MiB or more, which is
        # what the Linux maps parser did to the whole BSS before 2026-08-22.
        # Research only, and the point of it is to be able to *lose* a root
        # class on purpose: `bench/darwin_static_root_sections.cr --control`
        # uses it to show that its lost-root detector fires at all, which is
        # what stops a green run from being vacuous. It was a no-op stub on
        # this platform until 2026-09-04, so the Darwin arm of that argument
        # did not exist.
        return if @@bss_size_cap && size >= 1_u64 * 1024 * 1024

        lo = sect.value.addr &+ slide
        hi = lo &+ size
        yield Pointer(Void).new(lo), Pointer(Void).new(hi)
      end

      # Research only: refuse a writable section of 1 MiB or more.
      def self.bss_size_cap=(value : Bool) : Bool
        @@bss_size_cap = value
        invalidate_static_root_cache
        value
      end

      def self.tls_roots=(value : Bool) : Bool
        @@tls_roots = value
        invalidate_static_root_cache
        value
      end

      def self.tls_roots? : Bool
        @@tls_roots
      end

      def self.tls_root_range : {UInt64, UInt64}
        @@tls_roots ? {@@tls_lo, @@tls_hi} : {0_u64, 0_u64}
      end

      # The main thread's thread-local storage is a root, and on Darwin it was
      # not one.
      #
      # The dyld walk above takes writable `__DATA*` minus `SG_READ_ONLY`
      # minus TLS. TLS is excluded on purpose: those sections are the
      # *template*. The live block is allocated by `_tlv_bootstrap` /
      # `tlv_allocate_and_initialize` into memory that is in no `__DATA`
      # section, typically a libc `malloc`, and the main thread's stack scan
      # does not cover it either (`pthread_get_stackaddr_np` is the stack
      # only). So a pointer whose only copy was a main-thread `@[ThreadLocal]`
      # was collected. Linux closed the same hole on 2026-09-12; this is the
      # Mach-O half. `make tls-roots` is the gate on both.
      #
      # Sized from `__thread_data` + `__thread_bss`, not from the mapping that
      # contains the block. dyld's allocation sits in the malloc zone, and
      # scanning that mapping would retain whatever else the zone holds —
      # the 824 KiB first version of the Linux fix, in a different costume.
      # The window is `memsz` either side of the anchor, clipped to the
      # writable region `mach_vm_region` reports for it, so a window wider
      # than the block cannot leave mapped memory.
      #
      # Taking `pointerof(@@tls_anchor)` materialises the block: Darwin TLV
      # is lazy. That allocation is libc `malloc`, not `GC.malloc`, so it is
      # not a gcry heap object.
      #
      # Taken **once**, in `GC.init` on the main thread, and pushed again from
      # the memo on every refresh. The refresh runs every 64 majors on
      # whichever thread collects, and the anchor's address on a spawned
      # thread is that thread's block: recomputed there, the main thread's
      # thread-locals left the root set. Seen on Windows, which had the same
      # code (`static roots collapsed` at collection 320, 2026-09-29).
      private def self.take_main_thread_tls : Nil
        return unless @@tls_roots
        return if @@tls_memsz == 0
        unless @@tls_taken
          @@tls_taken = true
          @@tls_lo, @@tls_hi = main_thread_tls_window
        end
        push_range(@@tls_lo, @@tls_hi) if @@tls_hi > @@tls_lo
      end

      # The calling thread's block — call it on the main thread only.
      # `{0, 0}` when there is none to add.
      private def self.main_thread_tls_window : {UInt64, UInt64}
        none = {0_u64, 0_u64}
        anchor = pointerof(@@tls_anchor).address
        return none if anchor == 0
        span = @@tls_memsz
        align = @@tls_align
        span = (span &+ align &- 1) & ~(align &- 1) if align > 1
        lo = anchor > span ? (anchor &- span) & ~7_u64 : 0_u64
        hi = (anchor &+ span &+ 7) & ~7_u64
        region = writable_region_containing(anchor)
        return none unless region
        rlo, rhi = region
        lo = rlo if lo < rlo
        hi = rhi if hi > rhi
        return none if hi <= lo
        i = 0
        while i < @@range_count
          r = @@ranges[i]
          return none if r.low <= anchor && anchor < r.high
          i += 1
        end
        {lo, hi}
      end

      # The region containing *addr*, if it is mapped writable. `nil` if the
      # query failed or the region is not writable — both mean "do not add a
      # range", which is the direction that cannot scan unmapped memory.
      private def self.writable_region_containing(addr : UInt64) : {UInt64, UInt64}?
        address = addr
        size = 0_u64
        info = uninitialized Int32[16]
        count = VM_REGION_BASIC_INFO_COUNT_64
        object_name = 0_u32
        kr = LibMachVM.mach_vm_region(
          LibMachVM.mach_task_self_,
          pointerof(address),
          pointerof(size),
          VM_REGION_BASIC_INFO_64,
          info.to_unsafe,
          pointerof(count),
          pointerof(object_name),
        )
        return nil unless kr == 0
        return nil unless address <= addr && addr < address &+ size
        return nil unless (info[0] & VM_PROT_WRITE) != 0
        {address, address &+ size}
      end

      # ----------------------------------------------------------------------
      # Every other image.
      #
      # A dylib's writable data is a root, as it is under Boehm
      # (`GC_dyld_image_add`): a C library or Crystal code in a dylib that
      # keeps a GC pointer in a global must keep the object alive. Found the
      # way Boehm finds it — dyld's add/remove-image callbacks — and not by
      # walking `_dyld_get_image_header` per collection: in dyld4 that call
      # takes the loaders lock, which a thread stopped mid-`dlopen` holds.
      # The callbacks run with that lock held, on whichever thread loads, so
      # they never run concurrently with each other; the collector reads their
      # table only in a stopped world, without a lock, so every record is
      # published by a single store after it is complete:
      #
      # * add: the record is filled while its `live` word is 0 (a reused slot)
      #   or while it is past `@@image_count` (a new one), then `live` is set,
      #   then the count. dyld notifies before it runs the image's
      #   initialisers, so a thread stopped before the publish has run no code
      #   of that image and nothing in it can be lost.
      # * remove: `live` is cleared. dyld notifies before it unmaps, so an
      #   image whose remover is stopped before the store is still mapped.
      #
      # Same section rule as the executable (`segment_holds_roots?`, minus
      # TLS), with the sections of one segment merged into a run — what lies
      # between two sections of a mapped segment is mapped padding.
      IMAGE_RANGES = 8
      MAX_IMAGES   = 4096

      struct DyldImage
        property mh : UInt64
        property live : UInt32
        getter count : Int32

        def initialize(@mh : UInt64)
          @live = 0_u32
          @count = 0
          @ranges = uninitialized StaticArray(RootRange, IMAGE_RANGES)
        end

        def range(j : Int32) : RootRange
          @ranges[j]
        end

        def add(lo : UInt64, hi : UInt64) : Bool
          return true if hi <= lo
          return false if @count >= IMAGE_RANGES
          @ranges[@count] = RootRange.new(lo, hi)
          @count += 1
          true
        end
      end

      # Literal initialisers only — see the once-guard note at the top. The
      # callbacks can also run on a thread Crystal does not know.
      @@exe_mh = 0_u64
      @@images_addr = 0_u64
      @@image_count = 0
      @@images_registered = false
      @@shared_lib_roots = true

      # Library ranges on (the default). `false` scans the executable alone,
      # which is what every build did until 2026-10-05.
      def self.shared_lib_roots=(value : Bool) : Bool
        @@shared_lib_roots = value
      end

      def self.shared_lib_roots? : Bool
        @@shared_lib_roots
      end

      def self.static_root_libraries : Int32
        n = 0
        each_live_image { |img| n += 1 if img.count > 0 }
        n
      end

      def self.static_root_library_bytes : UInt64
        total = 0_u64
        each_live_image do |img|
          j = 0
          while j < img.count
            total += img.range(j).high - img.range(j).low
            j += 1
          end
        end
        total
      end

      # dyld hands over a mapped header, so nothing is ever unresolved here.
      def self.static_root_unresolved : UInt64
        0_u64
      end

      private def self.image_at(i : Int32) : DyldImage*
        Pointer(DyldImage).new(@@images_addr) + i
      end

      private def self.each_live_image(& : DyldImage ->) : Nil
        return if @@images_addr == 0
        n = @@image_count
        Atomic::Ops.fence(LLVM::AtomicOrdering::Acquire, false)
        i = 0
        while i < n
          img = image_at(i).value
          yield img if img.live == 1
          i += 1
        end
      end

      private def self.scan_image_roots(& : Void*, Void* ->) : Nil
        return unless @@shared_lib_roots
        each_live_image do |img|
          j = 0
          while j < img.count
            r = img.range(j)
            yield Pointer(Void).new(r.low), Pointer(Void).new(r.high)
            j += 1
          end
        end
      end

      # Once, from the init-time resolve, after the executable's header is
      # known so the add callback can tell it apart. dyld calls the add
      # callback for every image already loaded before this returns.
      private def self.register_image_callbacks : Nil
        return if @@images_registered
        return if @@exe_mh == 0
        bytes = MAX_IMAGES.to_u64 * sizeof(DyldImage)
        ptr = Gcry.os_map(bytes)
        if Gcry.mmap_failed?(ptr)
          @@overflow &+= 1
          return
        end
        @@images_addr = ptr.address
        @@images_registered = true
        LibDyld._dyld_register_func_for_add_image(->(mh : LibDyld::MachHeader64*, slide : Int64) {
          Platform.dyld_image_added(mh, slide)
        })
        LibDyld._dyld_register_func_for_remove_image(->(mh : LibDyld::MachHeader64*, slide : Int64) {
          Platform.dyld_image_removed(mh)
        })
      end

      # :nodoc:
      def self.dyld_image_added(mh : LibDyld::MachHeader64*, slide : Int64) : Nil
        return if mh.null? || mh.address == @@exe_mh
        return unless mh.value.magic == MH_MAGIC_64
        img = image_ranges(mh, slide.to_u64!)

        n = @@image_count
        i = 0
        while i < n
          break if image_at(i).value.live == 0
          i += 1
        end
        if i == n && n >= MAX_IMAGES
          @@overflow &+= 1
          return
        end
        slot = image_at(i)
        slot.value = img
        Atomic::Ops.fence(LLVM::AtomicOrdering::Release, false)
        (slot.as(UInt8*) + offsetof(DyldImage, @live)).as(UInt32*).value = 1_u32
        if i == n
          Atomic::Ops.fence(LLVM::AtomicOrdering::Release, false)
          @@image_count = n + 1
        end
      end

      # :nodoc:
      def self.dyld_image_removed(mh : LibDyld::MachHeader64*) : Nil
        n = @@image_count
        i = 0
        while i < n
          slot = image_at(i)
          img = slot.value
          if img.live == 1 && img.mh == mh.address
            (slot.as(UInt8*) + offsetof(DyldImage, @live)).as(UInt32*).value = 0_u32
            return
          end
          i += 1
        end
      end

      private def self.image_ranges(mh : LibDyld::MachHeader64*, slide : UInt64) : DyldImage
        img = DyldImage.new(mh.address)
        p = Pointer(UInt8).new(mh.address + sizeof(LibDyld::MachHeader64))
        cmd_i = 0_u32
        while cmd_i < mh.value.ncmds
          lc = p.as(LibDyld::LoadCommand*)
          if lc.value.cmd == LC_SEGMENT_64
            seg = p.as(LibDyld::SegmentCommand64*)
            if segment_holds_roots?(seg)
              sect = Pointer(LibDyld::Section64).new(p.address + sizeof(LibDyld::SegmentCommand64))
              run_lo = 0_u64
              run_hi = 0_u64
              j = 0_u32
              while j < seg.value.nsects
                s = (sect + j).value
                typ = s.flags & SECTION_TYPE_MASK
                lo = s.addr &+ slide
                hi = lo &+ s.size
                tls = typ == S_THREAD_LOCAL_REGULAR || typ == S_THREAD_LOCAL_ZEROFILL ||
                      typ == S_THREAD_LOCAL_VARIABLES || typ == S_THREAD_LOCAL_VARIABLE_POINTERS ||
                      typ == S_THREAD_LOCAL_INIT_FUNCTION_POINTERS
                if tls || lo < run_hi
                  # A TLS template breaks the run; so does a section out of
                  # address order, which no linker emits but costs nothing.
                  @@overflow &+= 1 unless img.add(run_lo, run_hi)
                  run_lo = 0_u64
                  run_hi = 0_u64
                end
                if !tls && s.size > 0
                  run_lo = lo if run_hi == 0
                  run_hi = hi
                end
                j += 1
              end
              @@overflow &+= 1 unless img.add(run_lo, run_hi)
            end
          end
          p += lc.value.cmdsize
          cmd_i += 1
        end
        img
      end
    {% end %}
  end
end
