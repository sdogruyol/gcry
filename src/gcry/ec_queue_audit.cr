# Reporting half of the execution-context queue audit. The walk itself lives in
# `collect_scan.cr`, next to the heap internals it needs (`is_heap_ptr`,
# `live?`); only the diagnostic is here.
#
# Printed from inside the stopped world, so it must not allocate: a stack
# buffer and `RawOut`, like `StwWatchdog#report`.
module Gcry
  module EcQueueAudit
    KIND_RUNNABLES   = 0
    KIND_GLOBAL_LIST = 1

    # `scheduler` is negative for the context-wide global queue, which has no
    # scheduler index.
    def self.report(kind : Int32, scheduler : Int32, index : UInt32, bits : UInt64) : Nil
      buf = uninitialized UInt8[RawOut::LIMIT]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: EC QUEUE SLOT CORRUPT ")
      len = RawOut.append(buf.to_unsafe, len, kind == KIND_RUNNABLES ? "runnables" : "global_queue")
      if scheduler >= 0
        len = RawOut.append(buf.to_unsafe, len, " scheduler=")
        len = RawOut.append_u64(buf.to_unsafe, len, scheduler.to_u64)
      end
      len = RawOut.append(buf.to_unsafe, len, " index=")
      len = RawOut.append_u64(buf.to_unsafe, len, index.to_u64)
      len = RawOut.append(buf.to_unsafe, len, " value=0x")
      len = RawOut.append_hex(buf.to_unsafe, len, bits)
      len = RawOut.append(buf.to_unsafe, len, " — not a live Fiber\n")
      len = RawOut.append(buf.to_unsafe, len, "gcry: this is the first collection that saw it; the write is earlier " \
                                              "and the dequeue that would SEGV on it has not run yet\n")
      RawOut.flush(buf.to_unsafe, len)
    end

    # A structure the context points at that is no longer that structure — the
    # shape a freed-and-reissued block has. Reported separately from a slot
    # because the consequence is different: a bad slot loses one fiber, a bad
    # structure means every slot it holds is being read out of some other
    # object's bytes.
    def self.report_struct(owner : String, ivar : String, bits : UInt64) : Nil
      buf = uninitialized UInt8[RawOut::LIMIT]
      len = 0
      len = RawOut.append(buf.to_unsafe, len, "gcry: EC STRUCTURE CORRUPT ")
      len = RawOut.append(buf.to_unsafe, len, owner)
      len = RawOut.append(buf.to_unsafe, len, "@")
      len = RawOut.append(buf.to_unsafe, len, ivar)
      len = RawOut.append(buf.to_unsafe, len, " = 0x")
      len = RawOut.append_hex(buf.to_unsafe, len, bits)
      len = RawOut.append(buf.to_unsafe, len, " — not a live object of the declared type\n")
      len = RawOut.append(buf.to_unsafe, len, "gcry: the slots it holds are being read out of whatever that block " \
                                              "became; the walk below cannot be trusted\n")
      RawOut.flush(buf.to_unsafe, len)
    end
  end
end
