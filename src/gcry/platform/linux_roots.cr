require "c/fcntl"
require "c/unistd"

module Gcry
  # Non-allocating static root discovery for Linux.
  #
  # Ranges are cached in LibC memory after the first scan. Refresh is cheap to
  # skip when maps are stable (typical for long-running servers).
  module Platform
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

    # Bump when dlopen/mmap of new libraries is expected; collect also bumps
    # occasionally so caches do not go forever stale.
    def self.invalidate_static_root_cache : Nil
      @@maps_generation &+= 1
    end

    def self.scan_static_roots(& : Void*, Void* ->) : Nil
      {% if flag?(:linux) %}
        ensure_static_root_cache
        i = 0
        while i < @@range_count
          r = (@@ranges + i).value
          yield Pointer(Void).new(r.low), Pointer(Void).new(r.high)
          i += 1
        end
      {% end %}
    end

    private def self.ensure_static_root_cache : Nil
      return if @@cached_generation == @@maps_generation && @@range_count > 0

      @@range_count = 0
      scan_proc_maps do |low, high|
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

    private def self.scan_proc_maps(& : Void*, Void* ->) : Nil
      fd = LibC.open("/proc/self/maps", LibC::O_RDONLY)
      return if fd < 0

      begin
        buf = uninitialized UInt8[8192]
        base = buf.to_unsafe
        leftover = 0
        loop do
          n = LibC.read(fd, (base + leftover).as(Void*), LibC::SizeT.new(buf.size - leftover))
          break if n <= 0

          total = leftover + n.to_i32
          start = 0
          i = 0
          while i < total
            if base[i] == 0x0a_u8
              parse_maps_line(base + start, i - start) { |lo, hi| yield lo, hi }
              start = i + 1
            end
            i += 1
          end

          leftover = total - start
          if leftover > 0 && start > 0
            j = 0
            while j < leftover
              base[j] = base[start + j]
              j += 1
            end
          elsif leftover == total
            leftover = 0
          end
        end
      ensure
        LibC.close(fd)
      end
    end

    private def self.parse_maps_line(line : UInt8*, len : Int32, & : Void*, Void* ->) : Nil
      return if len < 20

      dash = index_of(line, len, '-'.ord.to_u8)
      return unless dash

      rest = len - dash - 1
      space = index_of(line + dash + 1, rest, ' '.ord.to_u8)
      return unless space
      space_abs = dash + 1 + space

      lo = parse_hex(line, dash)
      hi = parse_hex(line + dash + 1, space_abs - dash - 1)
      return if lo == 0 || hi <= lo

      return if space_abs + 4 >= len
      perms = line + space_abs + 1
      # Need readable private data. Writable BSS holds class vars; RELRO .data.rel.ro
      # is r-- after relocation and may still hold heap pointers.
      return unless perms[0] == 'r'.ord.to_u8
      return if perms[2] == 'x'.ord.to_u8 # skip code

      path = pathname_start(line, len)
      size = hi - lo

      if path < 0
        # Anonymous RW: ELF BSS zero-fill pages after the file-backed .data page
        # (e.g. Exception::CallStack::@@skip). Skip large anon regions — fiber
        # stacks (8 MiB) and similar — those are covered by push_stack / STW.
        return unless perms[1] == 'w'.ord.to_u8
        return if size >= 1_u64 * 1024 * 1024
        yield Pointer(Void).new(lo), Pointer(Void).new(hi)
        return
      end

      return if includes_name?(line + path, len - path, "[stack]")
      return if includes_name?(line + path, len - path, "[heap]")
      return if includes_name?(line + path, len - path, "[vvar]")
      return if includes_name?(line + path, len - path, "[vdso]")

      # Skip bulky library data segments — they almost never hold Crystal
      # object pointers and dominate static-root scan time under HTTP.
      return if includes_name?(line + path, len - path, "libcrypto")
      return if includes_name?(line + path, len - path, "libssl")
      return if includes_name?(line + path, len - path, "libpcre")
      return if includes_name?(line + path, len - path, "libxml")
      return if includes_name?(line + path, len - path, "libyaml")
      return if includes_name?(line + path, len - path, "libgmp")
      return if includes_name?(line + path, len - path, "libicu")

      # File-backed: scan rw-p (BSS/.data) and r--p (RELRO).
      yield Pointer(Void).new(lo), Pointer(Void).new(hi)
    end

    private def self.pathname_start(line : UInt8*, len : Int32) : Int32
      i = 0
      fields = 0
      while i < len
        while i < len && line[i] == 0x20_u8
          i += 1
        end
        break if i >= len || line[i] == 0x0a_u8
        fields += 1
        if fields == 6
          return i
        end
        while i < len && line[i] != 0x20_u8 && line[i] != 0x0a_u8
          i += 1
        end
      end
      -1
    end

    private def self.index_of(ptr : UInt8*, len : Int32, byte : UInt8) : Int32?
      i = 0
      while i < len
        return i if ptr[i] == byte
        i += 1
      end
      nil
    end

    private def self.parse_hex(ptr : UInt8*, len : Int32) : UInt64
      value = 0_u64
      i = 0
      while i < len
        c = ptr[i]
        break if c == ' '.ord.to_u8
        value <<= 4
        if c >= '0'.ord.to_u8 && c <= '9'.ord.to_u8
          value |= (c - '0'.ord.to_u8).to_u64
        elsif c >= 'a'.ord.to_u8 && c <= 'f'.ord.to_u8
          value |= (c - 'a'.ord.to_u8 + 10).to_u64
        elsif c >= 'A'.ord.to_u8 && c <= 'F'.ord.to_u8
          value |= (c - 'A'.ord.to_u8 + 10).to_u64
        else
          break
        end
        i += 1
      end
      value
    end

    private def self.includes_name?(line : UInt8*, len : Int32, name : String) : Bool
      return false if name.bytesize > len
      limit = len - name.bytesize
      i = 0
      while i <= limit
        match = true
        j = 0
        while j < name.bytesize
          if line[i + j] != name.to_unsafe[j]
            match = false
            break
          end
          j += 1
        end
        return true if match
        i += 1
      end
      false
    end
  end
end
