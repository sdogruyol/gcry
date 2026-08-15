# Formatting for places that must not allocate: signal handlers, and anything
# running inside the stopped world.
#
# `write(2)` into a caller-owned stack buffer, no `String` interpolation, no
# `IO`. Three copies of these helpers had accumulated (`StwWatchdog`,
# `EcQueueAudit`, and the SIGSEGV report) before this existed; the watchdog keeps
# its own for now because it is older than this module and works.
module Gcry
  module RawOut
    LIMIT = 480

    def self.append(buf : UInt8*, len : Int32, str : String) : Int32
      i = 0
      n = str.bytesize
      src = str.to_unsafe
      while i < n && len < LIMIT
        buf[len] = src[i]
        len += 1
        i += 1
      end
      len
    end

    def self.append_u64(buf : UInt8*, len : Int32, value : UInt64) : Int32
      digits = uninitialized UInt8[20]
      count = 0
      v = value
      if v == 0
        digits[0] = '0'.ord.to_u8
        count = 1
      else
        while v > 0 && count < 20
          digits[count] = ('0'.ord.to_u8 + (v % 10).to_u8)
          v //= 10
          count += 1
        end
      end
      i = count - 1
      while i >= 0 && len < LIMIT
        buf[len] = digits[i]
        len += 1
        i -= 1
      end
      len
    end

    def self.append_hex(buf : UInt8*, len : Int32, value : UInt64) : Int32
      digits = uninitialized UInt8[16]
      count = 0
      v = value
      if v == 0
        digits[0] = '0'.ord.to_u8
        count = 1
      else
        while v > 0 && count < 16
          nibble = (v & 0xF_u64).to_u8
          digits[count] = nibble < 10 ? ('0'.ord.to_u8 + nibble) : ('a'.ord.to_u8 + (nibble - 10))
          v >>= 4
          count += 1
        end
      end
      i = count - 1
      while i >= 0 && len < LIMIT
        buf[len] = digits[i]
        len += 1
        i -= 1
      end
      len
    end

    def self.flush(buf : UInt8*, len : Int32) : Nil
      LibC.write(2, buf, LibC::SizeT.new(len))
    end
  end
end
