# A fatal exception on Windows must end the process, and under gcry it could
# hang it instead.
#
# Crystal's Windows handler for an access violation or a stack overflow
# (`Crystal::System::Signal.setup_seh_handler`) prints a backtrace and then
# `_exit(1)`s. On MSVC it prints through DbgHelp, and that allocates through
# the GC: `load_debug_info` the first time, then a `SYMBOL_INFOW` buffer and
# a `String` for every frame. A thread that faults *inside* gcry's allocator
# holds the size class's freelist lock, so the handler's first allocation of
# that class spins on it forever, on the thread that holds it.
#
# Found on Windows x86_64 CI, where `make parallel-mark-termination`'s red arm
# hung a job for 29 minutes on 2026-10-08, and captured with `cdb` on
# 2026-10-14 (bench/log/windows/2026-10-14-pmt-hang/): 18 hangs in 81 runs of
# that bench, each with the main thread and SYSMON at 100% of a core. The arm
# loses live objects on purpose. The main thread faults on one in the bench's
# own check and starts Crystal's report. SYSMON, scheduling over the same
# damaged heap, faults too and runs the handler beside it. It waits on the
# report's `Crystal.once` for `load_debug_info`; `Fiber.suspend` on a thread
# with no execution context raises, the raise builds a backtrace, and that
# waits on the same `once`, until the stack overflows. In 14 of the 18 hangs
# the overflow lands inside the allocator under a freelist lock, and the
# overflow's own report spins on that lock, with the main thread spinning
# behind it. In the other 4 it lands inside `Crystal::Once`'s spin lock, which
# the overflow's report then takes again. With this guard: 0 hangs in 923
# runs of the bench and 6 509 of its red child alone (run 38567822241).
#
# Two rules, both in a vectored handler that runs ahead of Crystal's:
#
#   - The thread being reported allocates from the C heap (`GC.malloc` and the
#     rest route there while `reporting?`), so a crash report never takes a
#     gcry lock or starts a collection. Nothing it allocates is freed: the
#     process is about to exit.
#   - One report at a time. A second thread that faults while a report is
#     running prints one line and waits for that report to `_exit`, instead
#     of running Crystal's handler beside it.
#
# Only access violations and stack overflows, the two codes Crystal's handler
# turns into an exit. Every other exception, including each `raise`'s, is
# passed on after one comparison.
module Gcry
  module CrashGuard
    {% if flag?(:win32) %}
      # Windows thread id of the thread whose fault is being reported; 0 while
      # none is. Literals, so nothing here runs a `__crystal_once` from inside
      # an exception dispatch.
      @@owner = 0_u32
      # Times the owner has entered the handler. A second entry is the report
      # itself faulting or overflowing, and Crystal's handler still gets it. A
      # third is a report that cannot finish, and gets one line and an exit.
      @@entries = 0_u32
      @@installed = false

      # Must run after Crystal's `setup_crash_handler`, since the last handler
      # added first is the first called. `src/gcry.cr` calls this from its top
      # level, which runs after the prelude's.
      def self.install : Nil
        return if @@installed
        @@installed = true
        LibC.AddVectoredExceptionHandler(1, ->(info : LibC::EXCEPTION_POINTERS*) { CrashGuard.on_exception(info) })
      end

      # Whether the calling thread is the one being reported. Reads one word
      # while no report is running.
      @[AlwaysInline]
      def self.reporting? : Bool
        owner = Atomic::Ops.load(pointerof(@@owner), LLVM::AtomicOrdering::Monotonic, false)
        owner != 0_u32 && owner == LibC.GetCurrentThreadId
      end

      protected def self.on_exception(info : LibC::EXCEPTION_POINTERS*) : LibC::LONG
        record = info.value.exceptionRecord
        code = record.value.exceptionCode
        unless code == LibC::EXCEPTION_ACCESS_VIOLATION || code == LibC::EXCEPTION_STACK_OVERFLOW
          return LibC::EXCEPTION_CONTINUE_SEARCH
        end
        me = LibC.GetCurrentThreadId
        owner, won = Atomic::Ops.cmpxchg(pointerof(@@owner), 0_u32, me,
          LLVM::AtomicOrdering::SequentiallyConsistent, LLVM::AtomicOrdering::SequentiallyConsistent)
        if won || owner == me
          @@entries &+= 1
          return LibC::EXCEPTION_CONTINUE_SEARCH if @@entries <= 2
          say(me, code, record, "faulted a third time while reporting its fault; exiting without the report\n", owner)
          LibC._exit(1)
        end
        say(me, code, record, "faulted while thread 0x", owner)
        loop { LibC.Sleep(LibC::INFINITE) }
      end

      # `gcry: thread 0x<me> <C0000005 at 0x<addr>> <what>[<owner> reports
      # one; it waits for that report to end the process]`. Through `RawOut`:
      # this runs inside an exception dispatch, possibly on the last page of a
      # stack.
      private def self.say(me : UInt32, code : UInt32, record : LibC::EXCEPTION_RECORD64*, what : String, owner : UInt32) : Nil
        buf = uninitialized UInt8[RawOut::LIMIT]
        len = RawOut.append(buf.to_unsafe, 0, "gcry: thread 0x")
        len = RawOut.append_hex(buf.to_unsafe, len, me.to_u64)
        len = RawOut.append(buf.to_unsafe, len, code == LibC::EXCEPTION_STACK_OVERFLOW ? " (stack overflow) " : " (C0000005 at 0x")
        if code == LibC::EXCEPTION_ACCESS_VIOLATION
          len = RawOut.append_hex(buf.to_unsafe, len, record.value.exceptionInformation[1])
          len = RawOut.append(buf.to_unsafe, len, ") ")
        end
        len = RawOut.append(buf.to_unsafe, len, what)
        if owner != me
          len = RawOut.append_hex(buf.to_unsafe, len, owner.to_u64)
          len = RawOut.append(buf.to_unsafe, len, " reports one; it waits for that report to end the process\n")
        end
        RawOut.flush(buf.to_unsafe, len)
      end
    {% else %}
      # Crystal's SIGSEGV handler on Unix is written not to allocate through
      # the GC (`unsafe_decode_frame`, exception/call_stack/libunwind.cr), so
      # there is nothing to route.
      def self.install : Nil
      end

      @[AlwaysInline]
      def self.reporting? : Bool
        false
      end
    {% end %}
  end
end
