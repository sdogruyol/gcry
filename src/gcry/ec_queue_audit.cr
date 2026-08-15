# Reporting half of the execution-context queue audit. The walk itself lives in
# `collect_scan.cr`, next to the heap internals it needs (`is_heap_ptr`,
# `live?`); only the diagnostic is here.
#
# Printed from inside the stopped world, so it must not allocate — same
# constraint as `StwWatchdog#report`, and the same shape of answer: a stack
# buffer and `write(2)`.
module Gcry
  module EcQueueAudit
    KIND_RUNNABLES   = 0
    KIND_GLOBAL_LIST = 1

    # `scheduler` is negative for the context-wide global queue, which has no
    # scheduler index.
    def self.report(kind : Int32, scheduler : Int32, index : UInt32, bits : UInt64) : Nil
      buf = uninitialized UInt8[320]
      len = 0
      len = append(buf.to_unsafe, len, "gcry: EC QUEUE SLOT CORRUPT ")
      len = append(buf.to_unsafe, len, kind == KIND_RUNNABLES ? "runnables" : "global_queue")
      if scheduler >= 0
        len = append(buf.to_unsafe, len, " scheduler=")
        len = append_u64(buf.to_unsafe, len, scheduler.to_u64)
      end
      len = append(buf.to_unsafe, len, " index=")
      len = append_u64(buf.to_unsafe, len, index.to_u64)
      len = append(buf.to_unsafe, len, " value=0x")
      len = append_hex(buf.to_unsafe, len, bits)
      len = append(buf.to_unsafe, len, " — not a live Fiber\n")
      len = append(buf.to_unsafe, len, "gcry: this is the first collection that saw it; the write is earlier " \
                                       "and the dequeue that would SEGV on it has not run yet\n")
      LibC.write(2, buf.to_unsafe, LibC::SizeT.new(len))
    end

    private def self.append(buf : UInt8*, len : Int32, str : String) : Int32
      i = 0
      n = str.bytesize
      src = str.to_unsafe
      while i < n && len < 300
        buf[len] = src[i]
        len += 1
        i += 1
      end
      len
    end

    private def self.append_u64(buf : UInt8*, len : Int32, value : UInt64) : Int32
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
      while i >= 0 && len < 300
        buf[len] = digits[i]
        len += 1
        i -= 1
      end
      len
    end

    private def self.append_hex(buf : UInt8*, len : Int32, value : UInt64) : Int32
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
      while i >= 0 && len < 300
        buf[len] = digits[i]
        len += 1
        i -= 1
      end
      len
    end
  end
end
