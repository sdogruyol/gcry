# Writable sections of the main PE image hold Crystal's globals/class vars.
# Like the ELF/Mach-O backends, system libraries are outside this root set.
# The PE `.tls` template is not a root — the live block is per thread.
require "./windows_os"
@[Link("kernel32")]
lib LibGcryImage
  fun GetModuleHandleW(name : UInt16*) : Void*
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
    @@tls_lo = 0_u64
    @@tls_hi = 0_u64
    @@resolves &+= 1
    scan_pe_static_roots do |low, high|
      push_range(low.address, high.address)
    end
    take_main_thread_tls

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
    {@@tls_lo, @@tls_hi}
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
  # Same contract as Linux (`PT_TLS` + `/proc/self/maps`) and Darwin
  # (`__thread_data`/`__thread_bss` + `mach_vm_region`). `make tls-roots`.
  private def self.take_main_thread_tls : Nil
    return unless @@tls_roots
    @@tls_lo = 0_u64
    @@tls_hi = 0_u64
    return if @@tls_memsz == 0
    anchor = pointerof(@@tls_anchor).address
    return if anchor == 0
    span = @@tls_memsz
    lo = anchor > span ? (anchor &- span) & ~7_u64 : 0_u64
    hi = (anchor &+ span &+ 7) & ~7_u64
    region = writable_region_containing(anchor)
    return unless region
    rlo, rhi = region
    lo = rlo if lo < rlo
    hi = rhi if hi > rhi
    return if hi <= lo
    i = 0
    while i < @@range_count
      r = @@ranges[i]
      return if r.low <= anchor && anchor < r.high
      i += 1
    end
    push_range(lo, hi)
    @@tls_lo = lo
    @@tls_hi = hi
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
end
