# Writable sections of the main PE image hold Crystal's globals/class vars.
# Like the ELF/Mach-O backends, system libraries are outside this root set.
require "./windows_os"
@[Link("kernel32")]
lib LibGcryImage
  fun GetModuleHandleW(name : UInt16*) : Void*
end

module Gcry::Platform
  MAX_RANGES = 96

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
    @@resolves &+= 1
    scan_pe_static_roots do |low, high|
      push_range(low.address, high.address)
    end

    if @@range_count > 0
      @@cached_generation = @@maps_generation
      return
    end

    @@bss_lost &+= 1
    if @@bss_lost == 1
      buf = uninitialized UInt8[160]
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
    return unless (nt + 24).as(UInt16*).value == 0x20B
    image_size = (nt + 24 + 56).as(UInt32*).value.to_u64
    section = nt + 24 + optional_size
    count.times do
      size = (section + 8).as(UInt32*).value.to_u64
      rva = (section + 12).as(UInt32*).value.to_u64
      characteristics = (section + 36).as(UInt32*).value
      # IMAGE_SCN_MEM_WRITE. Use VirtualSize so zero-initialised BSS is covered.
      if characteristics & 0x80000000_u32 != 0 && size > 0 && rva + size <= image_size
        unless @@bss_size_cap && size >= 1_u64 * 1024 * 1024
          yield (base + rva).as(Void*), (base + rva + size).as(Void*)
        end
      end
      section += 40
    end
  end

  def self.bss_size_cap=(value : Bool) : Bool
    @@bss_size_cap = value
    invalidate_static_root_cache
    value
  end
end
