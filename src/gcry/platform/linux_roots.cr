require "c/fcntl"
require "c/unistd"

module Gcry
  # Non-allocating static root discovery for Linux.
  module Platform
    def self.scan_static_roots(& : Void*, Void* ->) : Nil
      {% if flag?(:linux) %}
        scan_proc_maps { |low, high| yield low, high }
      {% end %}
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
      return unless perms[0] == 'r'.ord.to_u8 && perms[1] == 'w'.ord.to_u8
      return if includes_name?(line, len, "[stack]")

      yield Pointer(Void).new(lo), Pointer(Void).new(hi)
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
