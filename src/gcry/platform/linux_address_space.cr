# Every readable mapping in this process, with its name.
#
# `linux_roots.cr` also parses `/proc/self/maps`, but it is looking for one
# thing — the static-root ranges — and its filter throws away exactly what the
# address-space audit needs: anonymous regions, thread stacks, code, and the
# pathname itself. So this walker filters nothing and names everything, and the
# caller decides what to skip.
#
# Raw syscalls into a stack buffer: no allocation, callable with the world
# stopped. Linux only; `darwin_stubs.cr` answers `false` rather than walking
# nothing and letting a caller read that as "the value is nowhere".
{% skip_file unless flag?(:linux) %}

module Gcry
  module Platform
    # Yields `lo, hi, perms, name, name_len` for every mapping. `perms` points at
    # the four permission characters (`rw-p`), `name` at the pathname or
    # `[stack]`-style label, with `name_len == 0` for an anonymous mapping. Both
    # pointers are into a buffer this method reuses, so they are valid only for
    # the duration of the block.
    #
    # Returns false when `/proc/self/maps` cannot be read, so a caller can tell
    # "walked everything and found nothing" from "could not look".
    def self.each_map_region(& : UInt64, UInt64, UInt8*, UInt8*, Int32 ->) : Bool
      fd = LibC.open("/proc/self/maps".to_unsafe.as(LibC::Char*), 0) # O_RDONLY
      return false if fd < 0

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
              yield_map_line(base + start, i - start) { |a, b, c, d, e| yield a, b, c, d, e }
              start = i + 1
            end
            i += 1
          end

          leftover = total - start
          if leftover >= buf.size
            # A single line longer than the buffer. Drop it rather than spin:
            # a pathname that long is not a region this audit can name anyway.
            leftover = 0
          elsif leftover > 0 && start > 0
            j = 0
            while j < leftover
              base[j] = base[start + j]
              j += 1
            end
          end
        end
      ensure
        LibC.close(fd)
      end

      true
    end

    # `7f8b4c000000-7f8b4c021000 rw-p 00000000 00:00 0    [heap]`
    private def self.yield_map_line(line : UInt8*, len : Int32, & : UInt64, UInt64, UInt8*, UInt8*, Int32 ->) : Nil
      return if len < 20

      dash = -1
      i = 0
      while i < len
        if line[i] == '-'.ord.to_u8
          dash = i
          break
        end
        i += 1
      end
      return if dash <= 0

      space = -1
      i = dash + 1
      while i < len
        if line[i] == ' '.ord.to_u8
          space = i
          break
        end
        i += 1
      end
      return if space < 0

      lo = parse_map_hex(line, dash)
      hi = parse_map_hex(line + dash + 1, space - dash - 1)
      return if hi <= lo
      return if space + 5 > len

      perms = line + space + 1

      # Fields: range, perms, offset, dev, inode, then an optional pathname.
      # Walk five field boundaries and take whatever is left.
      field = 0
      i = space + 1
      name_start = len
      while i < len
        if line[i] == ' '.ord.to_u8
          while i < len && line[i] == ' '.ord.to_u8
            i += 1
          end
          field += 1
          if field == 4
            name_start = i
            break
          end
        else
          i += 1
        end
      end

      name_len = name_start < len ? len - name_start : 0
      yield lo, hi, perms, line + name_start, name_len
    end

    private def self.parse_map_hex(ptr : UInt8*, len : Int32) : UInt64
      value = 0_u64
      i = 0
      while i < len
        c = ptr[i]
        digit =
          if c >= '0'.ord.to_u8 && c <= '9'.ord.to_u8
            (c - '0'.ord.to_u8).to_u64
          elsif c >= 'a'.ord.to_u8 && c <= 'f'.ord.to_u8
            (c - 'a'.ord.to_u8).to_u64 + 10
          elsif c >= 'A'.ord.to_u8 && c <= 'F'.ord.to_u8
            (c - 'A'.ord.to_u8).to_u64 + 10
          else
            return value
          end
        value = (value << 4) | digit
        i += 1
      end
      value
    end
  end
end
