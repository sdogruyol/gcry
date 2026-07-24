# Non-allocating static root discovery for Darwin (dyld image walk).
#
# Ranges are cached in LibC memory after the first scan. Main executable
# `__DATA` / `__DATA_CONST` sections hold Crystal class/global vars; system
# dylibs are skipped (same policy as Linux skipping `.so`).

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

      # SECTION_TYPE bits that mark thread-local storage — not process-global roots.
      S_THREAD_LOCAL_REGULAR                = 0x11_u32
      S_THREAD_LOCAL_ZEROFILL               = 0x12_u32
      S_THREAD_LOCAL_VARIABLES              = 0x13_u32
      S_THREAD_LOCAL_VARIABLE_POINTERS      = 0x14_u32
      S_THREAD_LOCAL_INIT_FUNCTION_POINTERS = 0x15_u32
      SECTION_TYPE_MASK                     = 0xff_u32

      struct RootRange
        property low : UInt64
        property high : UInt64

        def initialize(@low : UInt64, @high : UInt64)
        end
      end

      @@ranges : RootRange* = Pointer(RootRange).null
      @@range_count = 0
      @@range_cap = 0
      @@maps_generation = 0_u32
      @@cached_generation = UInt32::MAX

      def self.invalidate_static_root_cache : Nil
        @@maps_generation &+= 1
      end

      def self.scan_static_roots(& : Void*, Void* ->) : Nil
        ensure_static_root_cache
        i = 0
        while i < @@range_count
          r = (@@ranges + i).value
          yield Pointer(Void).new(r.low), Pointer(Void).new(r.high)
          i += 1
        end
      end

      private def self.ensure_static_root_cache : Nil
        return if @@cached_generation == @@maps_generation && @@range_count > 0

        @@range_count = 0
        scan_dyld_static_roots do |low, high|
          push_range(low.address, high.address)
        end
        @@cached_generation = @@maps_generation
      end

      private def self.push_range(lo : UInt64, hi : UInt64) : Nil
        return if hi <= lo
        if @@range_count >= @@range_cap
          new_cap = @@range_cap == 0 ? 32 : @@range_cap * 2
          bytes = (sizeof(RootRange) * new_cap).to_u64
          ptr = LibC.realloc(@@ranges.as(Void*), LibC::SizeT.new(bytes)).as(RootRange*)
          raise OutOfMemoryError.new("static root cache realloc failed") if ptr.null?
          @@ranges = ptr
          @@range_cap = new_cap
        end
        (@@ranges + @@range_count).value = RootRange.new(lo, hi)
        @@range_count += 1
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

        # Mirror Linux: skip large read-only const blobs (word-scan tax).
        # Writable / zerofill (__data, __bss, __common) always scanned.
        if section_name_eq?(sect.value.sectname, "__const") && size >= 64_u64 * 1024
          return
        end

        lo = sect.value.addr &+ slide
        hi = lo &+ size
        yield Pointer(Void).new(lo), Pointer(Void).new(hi)
      end

      private def self.section_is_root_candidate?(sectname : StaticArray(UInt8, 16)) : Bool
        section_name_eq?(sectname, "__data") ||
          section_name_eq?(sectname, "__bss") ||
          section_name_eq?(sectname, "__common") ||
          section_name_eq?(sectname, "__const")
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
    {% end %}
  end
end
