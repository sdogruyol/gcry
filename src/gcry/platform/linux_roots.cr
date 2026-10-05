require "c/link"

module Gcry
  # Non-allocating static root discovery for Linux.
  #
  # The static roots are the executable's writable segments: every `PT_LOAD`
  # program header carrying `PF_W`, which is `.data` and `.bss` together
  # (`p_memsz` covers the zero-fill), minus the `PT_GNU_RELRO` window the
  # loader makes read-only before `main`. They come from `dl_iterate_phdr`,
  # whose first callback is the main program — the same headers the kernel
  # built the mappings from, read once at `GC.init` and never again. Every
  # other loaded object's writable segments are roots by the same rule; see
  # "Shared objects" below for how that set follows `dlopen` and `dlclose`.
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
    PF_X         =          1_u32
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
        scan_loaded_object_roots { |low, high| yield low, high }
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
        take_loaded_objects

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
          buf = uninitialized UInt8[RawOut::LIMIT]
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
    # The executable's load bias and executable segment, for the crash
    # report's writer-frame walk. Zero until `GC.init` resolves the statics.
    @@exe_bias = 0_u64
    @@text_lo = 0_u64
    @@text_hi = 0_u64

    def self.exe_bias : UInt64
      @@exe_bias
    end

    # Is *addr* a plausible return address, i.e. inside the executable's own
    # text? A frame walk that prints every word it finds is noise; one that
    # prints only these is a call chain.
    def self.exe_text?(addr : UInt64) : Bool
      @@text_hi > @@text_lo && addr >= @@text_lo && addr < @@text_hi
    end

    @@tls_align = 0_u64

    def self.tls_roots=(value : Bool) : Bool
      @@resolved = false
      @@tls_roots = value
    end

    def self.tls_roots? : Bool
      @@tls_roots
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
      # The load bias and the executable segment, for the crash report. A
      # faulting PC is only actionable as `exe + offset`: on a PIE the runtime
      # address differs every run, and `addr2line` wants the link-time one.
      # Taken here because this is the walk that already identifies *which*
      # object is the executable, and it runs once at `GC.init`.
      @@exe_bias = base
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
        elsif ph.type == PT_LOAD && (ph.flags & PF_X) != 0 && hi > lo
          # Executable and not writable: the text the crash report validates
          # return addresses against.
          @@text_lo = lo
          @@text_hi = hi
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

    # ----------------------------------------------------------------------
    # Shared objects.
    #
    # Every loaded object's writable data is a root, not only the
    # executable's: Boehm registers each one (`GC_register_dynamic_libraries`),
    # so a C library — or Crystal code in a `.so` — that keeps a GC pointer in
    # one of its own globals keeps the object alive under Boehm, and until
    # 2026-10-05 lost it under gcry. Same rule as the executable: writable
    # `PT_LOAD` minus that object's `PT_GNU_RELRO`.
    # `process_spec/regression/16_shared_library_static_roots_spec.cr`.
    #
    # The set changes while the program runs (`dlopen`, `dlclose`), and the
    # one place it cannot be re-read with `dl_iterate_phdr` is where it is
    # needed: inside the stopped world. That call takes the loader's lock, and
    # a mutator stopped inside any `dl_iterate_phdr` callback (Crystal's
    # backtrace loader runs one) or in the middle of `dlopen` holds it.
    # Before stopping the world is no better: the collector holds `@gc_lock`
    # for writing by then, and a callback that allocates blocks on it — the
    # deadlock Crystal already met against Boehm's lock and fixed on its own
    # side only (crystal#10084, `exception/call_stack/elf.cr`). So
    # `dl_iterate_phdr` runs once, at `GC.init`, before any other thread
    # exists, exactly like the executable walk above, and every collection
    # afterwards reads the loader's debugger interface instead — `r_debug`
    # and its `link_map` list, which glibc and musl both keep for `gdb` and
    # which is read without a lock by design.
    #
    # What makes that list safe to read in a stopped world is `r_state`. The
    # loader sets `RT_ADD` / `RT_DELETE` before it touches the list and
    # `RT_CONSISTENT` after, and three facts of glibc's order decide the rest
    # (`elf/dl-open.c` `dl_open_worker`, `elf/dl-close.c`
    # `_dl_close_worker`, 2.39):
    #
    # * `dlopen` restores `RT_CONSISTENT` *before* it runs the new object's
    #   constructors (relocation happens under `RT_ADD`, and writes link-time
    #   addresses, not anything the program allocated). An object first seen
    #   in the `RT_ADD` state has run no constructor and not been returned to
    #   the program, so no global of it can hold a GC pointer yet; it is left
    #   for the next collection.
    # * `dlclose` unmaps an object *before* unlinking it. One stopped in
    #   between is still on the list and no longer mapped, so in any state
    #   but `RT_CONSISTENT` every library range is scanned only where the
    #   kernel says a page is readable, instead of trusted.
    # * An object no longer on the list is already unmapped: it is dropped.
    #
    # A newly loaded object's program headers are found from the list entry
    # alone — `l_addr` is the load base, and an `ET_DYN` built by any current
    # linker maps its ELF header there — and only believed when they agree
    # with the entry: the header's `PT_DYNAMIC` must land on `l_ld`. One that
    # does not is counted in `static_root_unresolved` and reported once.
    PT_DYNAMIC      =  2_u32
    DT_NULL         =  0_i64
    DT_DEBUG        = 21_i64
    AT_SYSINFO_EHDR = 33_u64
    RT_CONSISTENT   =      0

    # A writable `PT_LOAD` split once by `RELRO` is two ranges; six is any
    # linker's layout with room to spare.
    OBJECT_RANGES = 6
    # Loaded objects tracked. The table is `mmap`ed and touched only as far
    # as it is used, so the bound costs address space, not memory.
    MAX_OBJECTS = 4096
    # A `link_map` walk longer than this is a corrupted or cyclic list.
    MAX_LINK_MAPS = 65536

    struct LoadedObject
      property addr : UInt64
      property ld : UInt64
      property epoch : UInt32
      getter count : Int32

      def initialize(@addr : UInt64, @ld : UInt64)
        @epoch = 0_u32
        @count = 0
        @ranges = uninitialized StaticArray(RootRange, OBJECT_RANGES)
      end

      def range(j : Int32) : RootRange
        @ranges[j]
      end

      # False when the object already has `OBJECT_RANGES`.
      def add(lo : UInt64, hi : UInt64) : Bool
        return true if hi <= lo
        return false if @count >= OBJECT_RANGES
        @ranges[@count] = RootRange.new(lo, hi)
        @count += 1
        true
      end

      def clear_ranges : Nil
        @count = 0
      end
    end

    lib LibGcryAuxv
      fun getauxval(type : LibC::ULong) : LibC::ULong
    end

    # All literal initialisers, for the reason `darwin_roots.cr` records: this
    # state is first touched inside `GC.init`, before `__crystal_once` works.
    @@objects_addr = 0_u64
    @@object_count = 0
    @@object_epoch = 0_u32
    @@r_debug = 0_u64
    @@vdso = 0_u64
    # `false` until a walk of the list found it consistent: no `r_debug` at
    # all (a static binary) also leaves it `false`, which costs nothing there
    # because such a binary has no library ranges to probe.
    @@objects_trusted = false
    @@static_root_unresolved = 0_u64
    @@shared_lib_roots = true

    # Library ranges on (the default). `false` scans the executable alone,
    # which is what every build did until 2026-10-05 — kept as a switch so a
    # program can measure what the libraries cost it.
    def self.shared_lib_roots=(value : Bool) : Bool
      @@shared_lib_roots = value
    end

    def self.shared_lib_roots? : Bool
      @@shared_lib_roots
    end

    # Loaded objects that contribute at least one range.
    def self.static_root_libraries : Int32
      n = 0
      i = 0
      while i < @@object_count
        n += 1 if object_at(i).value.count > 0
        i += 1
      end
      n
    end

    def self.static_root_library_bytes : UInt64
      total = 0_u64
      i = 0
      while i < @@object_count
        o = object_at(i).value
        j = 0
        while j < o.count
          total += o.range(j).high - o.range(j).low
          j += 1
        end
        i += 1
      end
      total
    end

    # Loaded objects whose program headers could not be located from their
    # `link_map` entry; their globals are not roots. Must read zero.
    def self.static_root_unresolved : UInt64
      @@static_root_unresolved
    end

    private def self.object_at(i : Int32) : LoadedObject*
      Pointer(LoadedObject).new(@@objects_addr) + i
    end

    # Called from the init-time resolve, after the executable's walk.
    private def self.take_loaded_objects : Nil
      if @@objects_addr == 0
        bytes = LibC::SizeT.new(MAX_OBJECTS * sizeof(LoadedObject))
        ptr = Gcry::OS.mmap(Pointer(Void).null, bytes,
          Gcry::OS::PROT_READ | Gcry::OS::PROT_WRITE,
          Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, 0)
        if Gcry.mmap_failed?(ptr)
          @@static_root_overflow &+= 1
          return
        end
        @@objects_addr = ptr.address
      end
      @@object_count = 0
      @@r_debug = 0_u64
      @@objects_trusted = false
      @@vdso = LibGcryAuxv.getauxval(AT_SYSINFO_EHDR).to_u64
      LibC.dl_iterate_phdr(->(info : LibC::DlPhdrInfo*, size : LibC::SizeT, data : Void*) {
        Platform.take_loaded_object(info)
        0
      }, Pointer(Void).null)
      if @@r_debug == 0
        # No `DT_DEBUG` in the executable: ask the loader for its symbol.
        # Still `GC.init`, still one thread, so `dlsym`'s lock is free.
        @@r_debug = LibC.dlsym(Pointer(Void).null, "_r_debug").address
      end
      @@objects_trusted = @@r_debug != 0
    end

    # :nodoc:
    def self.take_loaded_object(info : LibC::DlPhdrInfo*) : Nil
      base = info.value.addr.to_u64
      phdr = info.value.phdr
      n = info.value.phnum.to_i32
      exe = holds_probe?(info)
      take_r_debug(base, phdr, n) if exe
      # The executable's ranges are the table above, taken with its TLS and
      # bias; the vDSO is the kernel's and has nothing writable. Both are
      # still recorded, with no ranges, so the per-collection walk knows them
      # and does not re-parse them as new.
      record_object(base, phdr, n, exe || (base == @@vdso && base != 0))
    end

    # The executable's `DT_DEBUG` entry, which the loader fills with the
    # address of its `r_debug` at startup — on glibc and musl alike, and the
    # same way a debugger finds it.
    private def self.take_r_debug(base : UInt64, phdr : LibC::Elf_Phdr*, n : Int32) : Nil
      i = 0
      while i < n
        ph = (phdr + i).value
        if ph.type == PT_DYNAMIC
          dyn = Pointer(Int64).new(base &+ ph.vaddr.to_u64)
          entries = ph.memsz.to_u64 // 16
          k = 0_u64
          while k < entries
            tag = dyn[k * 2]
            break if tag == DT_NULL
            if tag == DT_DEBUG
              @@r_debug = dyn[k * 2 + 1].to_u64!
              return
            end
            k += 1
          end
        end
        i += 1
      end
    end

    # Appends one object: its key (`l_addr`, `l_ld`) and its writable
    # `PT_LOAD`s minus its own `PT_GNU_RELRO`, the executable's rule.
    private def self.record_object(base : UInt64, phdr : LibC::Elf_Phdr*, n : Int32, no_ranges : Bool) : LoadedObject*?
      if @@object_count >= MAX_OBJECTS
        @@static_root_overflow &+= 1
        return nil
      end
      ld = 0_u64
      relro_lo = 0_u64
      relro_hi = 0_u64
      obj = LoadedObject.new(base, 0_u64)
      i = 0
      while i < n
        ph = (phdr + i).value
        lo = base &+ ph.vaddr.to_u64
        hi = lo &+ ph.memsz.to_u64
        if ph.type == PT_DYNAMIC
          ld = lo
        elsif ph.type == PT_GNU_RELRO
          relro_lo = lo & PAGE_MASK
          relro_hi = hi & PAGE_MASK
        elsif !no_ranges && ph.type == PT_LOAD && (ph.flags & PF_W) != 0 && hi > lo
          @@static_root_overflow &+= 1 unless obj.add(lo, hi)
        end
        i += 1
      end
      obj.ld = ld
      obj = cut_window(obj, relro_lo, relro_hi) if relro_hi > relro_lo
      obj.epoch = @@object_epoch
      slot = object_at(@@object_count)
      slot.value = obj
      @@object_count += 1
      slot
    end

    # `apply_relro` for one object's ranges.
    private def self.cut_window(obj : LoadedObject, wlo : UInt64, whi : UInt64) : LoadedObject
      out = obj
      out.clear_ranges
      j = 0
      while j < obj.count
        r = obj.range(j)
        if r.low < wlo
          @@static_root_overflow &+= 1 unless out.add(r.low, r.high < wlo ? r.high : wlo)
        end
        if r.high > whi
          @@static_root_overflow &+= 1 unless out.add(r.low > whi ? r.low : whi, r.high)
        end
        j += 1
      end
      out
    end

    # Inside the stopped world, every collection: bring the table in line
    # with the loader's list without taking any lock, then hand out the
    # ranges — trusted when the list was consistent, probed page by page when
    # it was not.
    private def self.scan_loaded_object_roots(& : Void*, Void* ->) : Nil
      return unless @@shared_lib_roots
      return if @@objects_addr == 0
      # The probe pipe is created lazily by the first safe range scan. Make
      # sure of it here: without it every page reads as unreadable and an
      # untrusted pass would skip every library.
      Roots.ensure_probe_pipe
      sync_loaded_objects
      i = 0
      while i < @@object_count
        o = object_at(i).value
        j = 0
        while j < o.count
          r = o.range(j)
          if @@objects_trusted
            yield Pointer(Void).new(r.low), Pointer(Void).new(r.high)
          else
            each_readable_run(r.low, r.high) { |lo, hi| yield Pointer(Void).new(lo), Pointer(Void).new(hi) }
          end
          j += 1
        end
        i += 1
      end
    end

    private def self.each_readable_run(lo : UInt64, hi : UInt64, & : UInt64, UInt64 ->) : Nil
      page = lo & PAGE_MASK
      while page < hi
        while page < hi && !Roots.page_readable?(page)
          page &+= 4096
        end
        break if page >= hi
        run_lo = page < lo ? lo : page
        while page < hi && Roots.page_readable?(page)
          page &+= 4096
        end
        run_hi = page < hi ? page : hi
        yield run_lo, run_hi if run_hi > run_lo
      end
    end

    # `struct r_debug` / `struct link_map` (<link.h>): the public prefix both
    # glibc and musl lay out the same way, and that debuggers rely on.
    #   r_debug:  int r_version; link_map* r_map; addr r_brk; int r_state;
    #             addr r_ldbase; [version >= 2: r_debug_extended* r_next]
    #   link_map: addr l_addr; char* l_name; dyn* l_ld; link_map* l_next; ...
    private def self.sync_loaded_objects : Nil
      rd = @@r_debug
      return if rd == 0
      @@object_epoch &+= 1
      epoch = @@object_epoch
      consistent = true
      complete = true
      hint = 0
      ns = rd
      namespaces = 0
      while ns != 0 && namespaces < 64
        version = Pointer(Int32).new(ns).value
        ns_consistent = Pointer(Int32).new(ns &+ 24).value == RT_CONSISTENT
        consistent = false unless ns_consistent
        map = Pointer(UInt64).new(ns &+ 8).value
        steps = 0
        while map != 0
          if steps >= MAX_LINK_MAPS
            complete = false
            break
          end
          addr = Pointer(UInt64).new(map).value
          ld = Pointer(UInt64).new(map &+ 16).value
          idx = find_object(addr, ld, hint)
          if idx >= 0
            slot = object_at(idx)
            o = slot.value
            o.epoch = epoch
            slot.value = o
            hint = idx + 1
          elsif ns_consistent
            # Mid-`dlopen` (`RT_ADD`) the new object has run no code: it is
            # taken by the first collection that finds the list consistent.
            add_new_object(addr, ld)
          end
          map = Pointer(UInt64).new(map &+ 24).value
          steps += 1
        end
        ns = version >= 2 ? Pointer(UInt64).new(ns &+ 40).value : 0_u64
        namespaces += 1
      end
      drop_unseen(epoch) if complete
      @@objects_trusted = consistent && complete
    end

    private def self.find_object(addr : UInt64, ld : UInt64, hint : Int32) : Int32
      if hint < @@object_count
        o = object_at(hint).value
        return hint if o.addr == addr && o.ld == ld
      end
      i = 0
      while i < @@object_count
        o = object_at(i).value
        return i if o.addr == addr && o.ld == ld
        i += 1
      end
      -1
    end

    # Not on any list any more means unlinked, and `dlclose` unlinks only
    # after it unmaps. Order is kept so the walk's hint keeps hitting.
    private def self.drop_unseen(epoch : UInt32) : Nil
      kept = 0
      i = 0
      while i < @@object_count
        o = object_at(i).value
        if o.epoch == epoch
          object_at(kept).value = o if kept != i
          kept += 1
        end
        i += 1
      end
      @@object_count = kept
    end

    # An object loaded after `GC.init`. Its program headers are read from its
    # own mapping — every page probed before it is read — and believed only
    # when they put `PT_DYNAMIC` exactly at the entry's `l_ld` and map file
    # offset 0 at the load base.
    private def self.add_new_object(addr : UInt64, ld : UInt64) : Nil
      if phdr_n = object_headers(addr, ld)
        phdr, n = phdr_n
        if slot = record_object(addr, phdr, n, addr == @@vdso)
          o = slot.value
          o.epoch = @@object_epoch
          slot.value = o
        end
        return
      end
      # Recorded without ranges so it is not re-parsed every collection.
      if slot = record_object(addr, Pointer(LibC::Elf_Phdr).null, 0, true)
        o = slot.value
        o.ld = ld
        o.epoch = @@object_epoch
        slot.value = o
      end
      @@static_root_unresolved &+= 1
      if @@static_root_unresolved == 1
        buf = uninitialized UInt8[RawOut::LIMIT]
        len = RawOut.append(buf.to_unsafe, 0,
          "gcry: a loaded object's ELF header is not at its load base — its globals are not roots\n")
        RawOut.flush(buf.to_unsafe, len)
      end
    end

    private def self.object_headers(addr : UInt64, ld : UInt64) : {LibC::Elf_Phdr*, Int32}?
      return nil if addr == 0 || (addr & 4095) != 0
      return nil unless Roots.page_readable?(addr)
      e = Pointer(UInt8).new(addr)
      return nil unless e[0] == 0x7f_u8 && e[1] == 'E'.ord.to_u8 && e[2] == 'L'.ord.to_u8 && e[3] == 'F'.ord.to_u8
      return nil unless e[4] == 2_u8 # ELFCLASS64
      phoff = (e + 32).as(UInt64*).value
      phentsize = (e + 54).as(UInt16*).value
      phnum = (e + 56).as(UInt16*).value.to_i32
      return nil unless phentsize == sizeof(LibC::Elf_Phdr) && phnum > 0 && phnum <= 1024
      return nil if phoff > 1_u64 << 20
      ph_lo = addr &+ phoff
      ph_hi = ph_lo &+ phnum.to_u64 * sizeof(LibC::Elf_Phdr)
      page = ph_lo & PAGE_MASK
      while page < ph_hi
        return nil unless Roots.page_readable?(page)
        page &+= 4096
      end
      phdr = Pointer(LibC::Elf_Phdr).new(ph_lo)
      header_at_base = false
      dynamic_matches = ld == 0
      i = 0
      while i < phnum
        ph = (phdr + i).value
        if ph.type == PT_LOAD && ph.offset == 0
          header_at_base = ph.vaddr == 0
        elsif ph.type == PT_DYNAMIC
          dynamic_matches = addr &+ ph.vaddr.to_u64 == ld
        end
        i += 1
      end
      return nil unless header_at_base && dynamic_matches
      {phdr, phnum}
    end

    # Research only: refuse a writable segment larger than 1 MiB, as the maps
    # parser did before 2026-08-22.
    def self.bss_size_cap=(value : Bool) : Bool
      @@resolved = false
      @@bss_size_cap = value
    end
  end
end
