# Writable sections of the main PE image hold Crystal's globals/class vars;
# every other loaded module's writable image pages are roots too (see
# `refresh_module_ranges`), as they are under Boehm.
# The PE `.tls` template is not a root — the live block is per thread.
require "./windows_os"
@[Link("kernel32")]
lib LibGcryImage
  fun GetModuleHandleW(name : UInt16*) : Void*
  fun GetProcAddress(h_module : Void*, name : UInt8*) : Void*
end

module Gcry::Platform
  MAX_RANGES = 96

  # IMAGE_DIRECTORY_ENTRY_TLS. DataDirectory starts at optional-header + 112
  # on PE32+; this is entry 9.
  TLS_DIRECTORY_INDEX          =         9
  OPTIONAL_MAGIC_PE32_PLUS     = 0x20B_u16
  OPTIONAL_DATA_DIRECTORY      =       112
  OPTIONAL_NUMBER_OF_RVA_SIZES =       108
  TLS_DIRECTORY_MIN_SIZE       =        40
  # PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY
  PAGE_WRITABLE_MASK =   0xCC_u32
  MEM_COMMIT         = 0x1000_u32

  struct RootRange
    property low : UInt64
    property high : UInt64

    def initialize(@low : UInt64, @high : UInt64)
    end
  end

  {% if flag?(:gcry_static_root_once) %}
    @@cached_generation = UInt32::MAX
  {% else %}
    @@cached_generation = 4294967295_u32
  {% end %}
  @@ranges = uninitialized StaticArray(RootRange, MAX_RANGES)
  @@range_count = 0
  @@maps_generation = 0_u32
  @@resolves = 0_u64
  @@overflow = 0_u64
  @@bss_lost = 0_u64
  @@bss_size_cap = false

  # A gcry-owned thread-local, used only for its **address**. `uninitialized`
  # rather than `= 0_u64` — a class variable with an initialiser is set up
  # lazily behind `__crystal_once`, and this one is read from `GC.init`.
  @[ThreadLocal]
  @@tls_anchor = uninitialized UInt64

  @@tls_roots = true
  @@tls_lo = 0_u64
  @@tls_hi = 0_u64
  @@tls_taken = false
  @@tls_memsz = 0_u64
  @@tls_tmpl_lo = 0_u64
  @@tls_tmpl_hi = 0_u64

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
    scan_module_roots { |low, high| yield low, high }
  end

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

  def self.static_root_resolves : UInt64
    @@resolves
  end

  def self.ensure_static_root_cache : Nil
    return if @@cached_generation == @@maps_generation && @@range_count > 0

    @@range_count = 0
    @@tls_memsz = 0_u64
    @@tls_tmpl_lo = 0_u64
    @@tls_tmpl_hi = 0_u64
    @@resolves &+= 1
    scan_pe_static_roots do |low, high|
      push_range(low.address, high.address)
    end
    take_main_thread_tls
    register_dll_notification

    if @@range_count > 0
      @@cached_generation = @@maps_generation
      return
    end

    @@bss_lost &+= 1
    if @@bss_lost == 1
      buf = uninitialized UInt8[RawOut::LIMIT]
      len = RawOut.append(buf.to_unsafe, 0,
        "gcry: the executable has no writable PE section — no class variable is a root\n")
      RawOut.flush(buf.to_unsafe, len)
    end
  end

  private def self.push_range(lo : UInt64, hi : UInt64) : Nil
    return if hi <= lo
    if @@range_count < MAX_RANGES
      @@ranges[@@range_count] = RootRange.new(lo, hi)
      @@range_count += 1
    else
      @@overflow &+= 1
    end
  end

  private def self.scan_pe_static_roots(& : Void*, Void* ->) : Nil
    base = LibGcryImage.GetModuleHandleW(nil).as(UInt8*)
    return if base.null? || base.as(UInt16*).value != 0x5A4D
    @@exe_base = base.address
    nt = base + (base + 0x3C).as(UInt32*).value
    return unless nt.as(UInt32*).value == 0x00004550
    count = (nt + 6).as(UInt16*).value
    optional_size = (nt + 20).as(UInt16*).value
    return unless (nt + 24).as(UInt16*).value == OPTIONAL_MAGIC_PE32_PLUS
    image_size = (nt + 24 + 56).as(UInt32*).value.to_u64
    take_tls_directory(base, nt)
    section = nt + 24 + optional_size
    count.times do
      size = (section + 8).as(UInt32*).value.to_u64
      rva = (section + 12).as(UInt32*).value.to_u64
      characteristics = (section + 36).as(UInt32*).value
      # IMAGE_SCN_MEM_WRITE. Use VirtualSize so zero-initialised BSS is covered.
      if characteristics & 0x80000000_u32 != 0 && size > 0 && rva + size <= image_size
        lo = (base + rva).address
        hi = lo &+ size
        # The `.tls` template is the PE equivalent of ELF `PT_TLS` / Mach-O
        # `S_THREAD_LOCAL_*`: initialisers, not the live per-thread block.
        # Skipping it is what makes `GCRY_TLS_ROOTS=0` able to lose the block
        # on the main thread, where the loader uses the template in place.
        unless tls_template_overlap?(lo, hi)
          unless @@bss_size_cap && size >= 1_u64 * 1024 * 1024
            yield (base + rva).as(Void*), (base + rva + size).as(Void*)
          end
        end
      end
      section += 40
    end
  end

  # IMAGE_TLS_DIRECTORY64 of the main image: template VA range and payload
  # size. `StartAddressOfRawData` / `EndAddressOfRawData` are already
  # relocated VAs on a loaded image.
  private def self.take_tls_directory(base : UInt8*, nt : UInt8*) : Nil
    n_rva = (nt + 24 + OPTIONAL_NUMBER_OF_RVA_SIZES).as(UInt32*).value
    return if n_rva <= TLS_DIRECTORY_INDEX
    dir = nt + 24 + OPTIONAL_DATA_DIRECTORY + TLS_DIRECTORY_INDEX * 8
    rva = dir.as(UInt32*).value.to_u64
    dir_size = (dir + 4).as(UInt32*).value.to_u64
    return if rva == 0 || dir_size < TLS_DIRECTORY_MIN_SIZE
    tls = base + rva
    start_va = tls.as(UInt64*).value
    end_va = (tls + 8).as(UInt64*).value
    zero_fill = (tls + 32).as(UInt32*).value.to_u64
    @@tls_tmpl_lo = start_va
    @@tls_tmpl_hi = end_va
    @@tls_memsz = (end_va > start_va ? end_va &- start_va : 0_u64) &+ zero_fill
  end

  private def self.tls_template_overlap?(lo : UInt64, hi : UInt64) : Bool
    return false if @@tls_tmpl_hi <= @@tls_tmpl_lo
    lo < @@tls_tmpl_hi && hi > @@tls_tmpl_lo
  end

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

  # The main thread's thread-local storage is a root.
  #
  # Writable PE sections cover class variables. A `@[ThreadLocal]` is not in
  # those sections as a live value: `.tls` is the template, and Windows copies
  # it per thread through the TEB. The **main** thread often uses the template
  # in place — which is why it has to be *removed* from the PE walk above, or
  # `GCRY_TLS_ROOTS=0` cannot lose it. Spawned threads get a copy that the PE
  # walk never sees. Either way the live block is the one that contains
  # `@@tls_anchor`, sized from the TLS directory, clipped with `VirtualQuery`.
  #
  # Taken **once**, on the thread that runs `GC.init` — the main thread —
  # and pushed again from the memo on every refresh. The refresh runs every
  # 64 majors on whichever thread collects, and `pointerof(@@tls_anchor)` on
  # a spawned thread is *that* thread's block. Recomputed there, the main
  # thread's thread-locals left the root set: `make thread-birth-fiber` on
  # Windows arm64, `static roots collapsed to 16096 bytes from 44944` at
  # collection 320 and a C0000005 after it (2026-09-29).
  #
  # Same contract as Linux (`PT_TLS` + `/proc/self/maps`) and Darwin
  # (`__thread_data`/`__thread_bss` + `mach_vm_region`). `make tls-roots`.
  private def self.take_main_thread_tls : Nil
    return unless @@tls_roots
    return if @@tls_memsz == 0
    unless @@tls_taken
      @@tls_taken = true
      @@tls_lo, @@tls_hi = main_thread_tls_window
    end
    push_range(@@tls_lo, @@tls_hi) if @@tls_hi > @@tls_lo
  end

  # The calling thread's block — call it on the main thread only. `{0, 0}`
  # when there is none to add, including when a writable PE section already
  # covers the anchor.
  private def self.main_thread_tls_window : {UInt64, UInt64}
    none = {0_u64, 0_u64}
    anchor = pointerof(@@tls_anchor).address
    return none if anchor == 0
    span = @@tls_memsz
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

  private def self.writable_region_containing(addr : UInt64) : {UInt64, UInt64}?
    n = LibC.VirtualQuery(Pointer(Void).new(addr), out info, sizeof(LibC::MEMORY_BASIC_INFORMATION))
    return nil if n == 0
    return nil unless info.state == MEM_COMMIT
    return nil unless (info.protect & PAGE_WRITABLE_MASK) != 0
    base = info.baseAddress.address
    hi = base &+ info.regionSize
    return nil unless base <= addr && addr < hi
    {base, hi}
  end

  # --------------------------------------------------------------------------
  # Every other module.
  #
  # A DLL's writable data is a root, as it is under Boehm, which on Windows
  # registers every committed, writable `MEM_IMAGE` region it finds walking
  # the address space with `VirtualQuery` (`GC_register_dynamic_libraries`,
  # win32 branch). This is that walk. It needs no loader lock — the PEB's
  # module list and `EnumProcessModules` both do, and a thread stopped inside
  # `LoadLibrary` holds it — and it reads the pages' current protection, so a
  # module mapped as a resource or data file (read-only) is not taken, and a
  # copy-on-write `.data` is.
  #
  # It costs one query per region, heap chunks included, so it is not run per
  # collection: `LdrRegisterDllNotification` bumps `@@module_generation` on
  # every load and unload, and the walk reruns when that moved (and on the
  # same 64-major refresh as the executable's sections). Where the
  # notification cannot be registered it reruns every collection. A range
  # left over from a DLL unloaded since the walk is harmless: the safe range
  # scan on this platform reads only regions `VirtualQuery` reports readable.
  MEM_IMAGE         = 0x1000000_u32
  PAGE_GUARD        =     0x100_u32
  MAX_MODULE_RANGES =          4096

  @@exe_base = 0_u64
  @@module_ranges_addr = 0_u64
  @@module_range_count = 0
  @@module_count = 0
  @@module_generation = 0_u32
  @@module_built_generation = 4294967295_u32
  @@module_built_maps_generation = 4294967295_u32
  @@module_notify = false
  @@module_notify_tried = false
  @@dll_cookie = 0_u64
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
    @@module_count
  end

  def self.static_root_library_bytes : UInt64
    total = 0_u64
    i = 0
    while i < @@module_range_count
      r = module_range_at(i).value
      total += r.high - r.low
      i += 1
    end
    total
  end

  # The walk reads protections, not headers, so nothing is unresolved.
  def self.static_root_unresolved : UInt64
    0_u64
  end

  # :nodoc:
  def self.note_dll_change : Nil
    @@module_generation &+= 1
  end

  private def self.module_range_at(i : Int32) : RootRange*
    Pointer(RootRange).new(@@module_ranges_addr) + i
  end

  # Once, from the init-time resolve. Resolved through `GetProcAddress`
  # rather than linked: `ntdll.lib` is not on every toolchain's path, and an
  # absent export must cost a fallback, not the build.
  private def self.register_dll_notification : Nil
    return if @@module_notify_tried
    @@module_notify_tried = true
    # "ntdll.dll" as UTF-16 without allocating: this runs inside `GC.init`.
    name = StaticArray(UInt16, 10).new(0_u16)
    i = 0
    "ntdll.dll".each_byte do |b|
      name[i] = b.to_u16
      i += 1
    end
    ntdll = LibGcryImage.GetModuleHandleW(name.to_unsafe)
    return if ntdll.null?
    register = LibGcryImage.GetProcAddress(ntdll, "LdrRegisterDllNotification".to_unsafe)
    return if register.null?
    callback = ->(_reason : UInt32, _data : Void*, _context : Void*) {
      Gcry::Platform.note_dll_change
      nil
    }
    status = Proc(UInt32, Void*, Void*, Void*, Int32).new(register, Pointer(Void).null)
      .call(0_u32, callback.pointer, Pointer(Void).null, pointerof(@@dll_cookie).as(Void*))
    @@module_notify = status >= 0
  end

  private def self.scan_module_roots(& : Void*, Void* ->) : Nil
    return unless @@shared_lib_roots
    if !@@module_notify || @@module_built_generation != @@module_generation ||
       @@module_built_maps_generation != @@maps_generation
      refresh_module_ranges
    end
    i = 0
    while i < @@module_range_count
      r = module_range_at(i).value
      yield Pointer(Void).new(r.low), Pointer(Void).new(r.high)
      i += 1
    end
  end

  private def self.refresh_module_ranges : Nil
    if @@module_ranges_addr == 0
      bytes = MAX_MODULE_RANGES.to_u64 * sizeof(RootRange)
      ptr = Gcry.os_map(bytes)
      if Gcry.mmap_failed?(ptr)
        @@overflow &+= 1
        return
      end
      @@module_ranges_addr = ptr.address
    end
    generation = @@module_generation
    count = 0
    modules = 0
    last_base = 0_u64
    run_lo = 0_u64
    run_hi = 0_u64
    addr = 0x10000_u64
    loop do
      n = LibC.VirtualQuery(Pointer(Void).new(addr), out info, sizeof(LibC::MEMORY_BASIC_INFORMATION))
      break if n == 0
      base = info.baseAddress.address
      size = info.regionSize.to_u64
      break if size == 0
      owner = info.allocationBase.address
      if info.type == MEM_IMAGE && info.state == MEM_COMMIT &&
         (info.protect & PAGE_WRITABLE_MASK) != 0 && (info.protect & PAGE_GUARD) == 0 &&
         owner != @@exe_base
        if owner != last_base
          modules += 1
          last_base = owner
        end
        if base == run_hi
          run_hi = base &+ size
        else
          count = push_module_range(count, run_lo, run_hi)
          run_lo = base
          run_hi = base &+ size
        end
      end
      next_addr = base &+ size
      break if next_addr <= addr
      addr = next_addr
    end
    count = push_module_range(count, run_lo, run_hi)
    @@module_range_count = count
    @@module_count = modules
    @@module_built_generation = generation
    @@module_built_maps_generation = @@maps_generation
  end

  private def self.push_module_range(count : Int32, lo : UInt64, hi : UInt64) : Int32
    return count if hi <= lo
    if count >= MAX_MODULE_RANGES
      @@overflow &+= 1
      return count
    end
    module_range_at(count).value = RootRange.new(lo, hi)
    count + 1
  end
end
