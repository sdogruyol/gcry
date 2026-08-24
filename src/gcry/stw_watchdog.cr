# A hang with the world stopped is silent. This makes it say something.
#
# When the collector wedges under STW, every mutator is frozen in `sigsuspend`
# and the collector is blocked on whatever it is waiting for, so nothing in the
# process can report anything: no crash, no output, and `/gc-stats` cannot answer
# because its HTTP thread is suspended too. Finding the last one
# (`pthread_getattr_np` on a suspended thread — see
# `bench/log/linux/2026-08-10-stw-startup-hang/FINDINGS.md`) took inserting
# markers and rebuilding. With this armed it takes reading one line.
#
# The watchdog is a raw `LibC.pthread_create` thread, not a `Crystal::Thread`,
# for the same reason the parallel mark helpers are (see parallel_mark.cr): STW
# only signals threads in Crystal's list, so a raw thread keeps running while the
# world is stopped, which is exactly when it has to work.
#
# It holds no reference to any GC object — only the scalars below. That matters:
# its stack is never scanned, so a Crystal object reachable *only* from here
# would be collected out from under it.
#
# `GCRY_STW_WATCHDOG_MS=<ms>` arms it; default off. Off costs two plain stores per
# collection phase (the breadcrumb, which is kept unconditionally so it is also
# available for post-mortem) and creates no thread.

require "c/pthread"

lib LibC
  fun nanosleep(req : Timespec*, rem : Timespec*) : Int
end

# C ABI entry — must not be a Crystal::Thread, or STW would suspend the one
# thread whose job is to notice that STW is stuck.
fun gcry_stw_watchdog_main(arg : Void*) : Void*
  Gcry::StwWatchdog.watch_loop
  Pointer(Void).null
end

module Gcry
  module StwWatchdog
    PHASE_NONE       =  0
    PHASE_SUSPEND    =  1
    PHASE_FLUSH      =  2
    PHASE_CLEAR      =  3
    PHASE_ROOTS      =  4
    PHASE_STATIC     =  5
    PHASE_STACKS     =  6
    PHASE_MARK       =  7
    PHASE_FINALIZERS =  8
    PHASE_SWEEP      =  9
    PHASE_RESUME     = 10
    # The span between the suspend wait finishing and PHASE_FLUSH used to be
    # reported as `suspend`, which is where aarch64 hangs kept landing —
    # "every thread acknowledged, the stall is after the wait loop" is true but
    # covers three different regions. These name them.
    PHASE_STOPPED = 11
    PHASE_QUIESCE = 12

    POLL_NS = 50_000_000_u64 # 50 ms

    @@phase = PHASE_NONE
    # `@@suspend_*` are written only by `note_suspend`, so without this they
    # survive from one stop to the next. A stop that hangs *before* it reaches
    # the wait loop then reports the previous stop's cleared breadcrumb —
    # "every thread acknowledged" — which is the same mistake as reading a
    # cleared id as thread 0, one stop removed. Stamped unset at phase entry.
    SUSPEND_UNSET = 0xffff_ffff_ffff_ffff_u64

    # Where inside `PHASE_SUSPEND` the stop got to. The phase covers a sequence
    # — close the monitor gate, wait for staged threads, take `Thread.lock`,
    # snapshot every stack's bounds, send the signals, wait for the acks — and
    # a stall reported as "suspend" could be any of them. aarch64 has hung here
    # four times without the region ever being named.
    STEP_ENTER        = 0
    STEP_GATE_CLOSED  = 1
    STEP_STAGED_DONE  = 2
    STEP_THREAD_LOCK  = 3
    STEP_BOUNDS_DONE  = 4
    STEP_SIGNALS_SENT = 5
    @@suspend_step = STEP_ENTER

    def self.note_suspend_step(step : Int32) : Nil
      @@suspend_step = step
    end

    def self.step_name(step : Int32) : String
      case step
      when STEP_ENTER        then "entered, monitor gate not yet closed"
      when STEP_GATE_CLOSED  then "monitor gate closed, waiting on staged threads"
      when STEP_STAGED_DONE  then "staged wait done, taking Thread.lock"
      when STEP_THREAD_LOCK  then "Thread.lock held, snapshotting stack bounds"
      when STEP_BOUNDS_DONE  then "bounds taken, sending suspend signals"
      when STEP_SIGNALS_SENT then "signals sent, waiting for acknowledgements"
      else                        "unknown"
      end
    end

    @@since_ns = 0_u64
    @@threshold_ns = 0_u64
    @@started = false
    @@reported = false

    def self.phase_name(id : Int32) : String
      case id
      when PHASE_SUSPEND    then "suspend"
      when PHASE_STOPPED    then "stopped-before-flush"
      when PHASE_QUIESCE    then "quiesce-release"
      when PHASE_FLUSH      then "flush"
      when PHASE_CLEAR      then "clear-marks"
      when PHASE_ROOTS      then "roots"
      when PHASE_STATIC     then "static-roots"
      when PHASE_STACKS     then "thread-stacks"
      when PHASE_MARK       then "mark"
      when PHASE_FINALIZERS then "finalizers"
      when PHASE_SWEEP      then "sweep"
      when PHASE_RESUME     then "resume"
      else                       "none"
      end
    end

    # Who the suspend phase is waiting for.
    #
    # The first legible sighting of the aarch64 hang (2026-08-22, run
    # `32575506486`) said `STALLED 10009 ms in phase=suspend` and stopped there:
    # the collector had signalled every thread and was spinning on
    # `until thread.@suspended.get` for one of them, and the report could not
    # say which. These three are set by that spin, so the next one names it —
    # the same device as `stack_bounds_in_flight`, which exists because a fault
    # that names a thread is worth more than one that names a frame.
    #
    # Plain stores from the collecting thread, read by the watchdog's own
    # pthread. Not a protocol: a torn read costs one confusing line in a report
    # that is already about a process that is not going to finish.
    @@suspend_expected = 0
    @@suspend_acked = 0
    @@suspend_waiting_id = 0_u64

    def self.note_suspend(expected : Int32, acked : Int32, waiting_id : UInt64) : Nil
      @@suspend_expected = expected
      @@suspend_acked = acked
      @@suspend_waiting_id = waiting_id
    end

    def self.threshold_ms=(ms : UInt64) : Nil
      @@threshold_ns = ms * 1_000_000_u64
    end

    def self.threshold_ms : UInt64
      @@threshold_ns // 1_000_000_u64
    end

    def self.armed? : Bool
      @@threshold_ns > 0
    end

    def self.current_phase : Int32
      @@phase
    end

    # Start the watcher. Call with the world *running*: `pthread_create` asks libc
    # for a stack, and asking libc for anything with threads frozen is the class
    # of bug this whole file exists to make visible.
    def self.ensure_started : Nil
      return unless armed?
      return if @@started
      @@started = true

      tid = uninitialized LibC::PthreadT
      ret = LibC.pthread_create(pointerof(tid), Pointer(LibC::PthreadAttrT).null,
        ->gcry_stw_watchdog_main(Void*), Pointer(Void).null)
      if ret != 0
        @@started = false
        write_str("gcry: STW watchdog could not start (pthread_create failed)\n")
        return
      end
      LibC.pthread_detach(tid)
    end

    # Breadcrumb. Two plain stores; kept even when disarmed so a post-mortem has
    # something to read. Not a synchronisation protocol — the watcher re-reads the
    # phase after measuring and drops the sample if it moved.
    def self.enter(id : Int32) : Nil
      @@since_ns = now_ns
      if id == PHASE_SUSPEND
        @@suspend_waiting_id = SUSPEND_UNSET
        @@suspend_expected = 0
        @@suspend_acked = 0
        @@suspend_step = STEP_ENTER
      end
      @@phase = id
    end

    def self.leave : Nil
      @@phase = PHASE_NONE
      @@reported = false
    end

    def self.watch_loop : Nil
      req = uninitialized LibC::Timespec
      req.tv_sec = typeof(req.tv_sec).new(0)
      req.tv_nsec = typeof(req.tv_nsec).new(POLL_NS)
      rem = uninitialized LibC::Timespec

      loop do
        LibC.nanosleep(pointerof(req), pointerof(rem))

        id = @@phase
        next if id == PHASE_NONE || @@reported

        started = @@since_ns
        now = now_ns
        # Phase moved while we were measuring: the sample is meaningless, and the
        # collector is evidently alive.
        next unless @@phase == id
        next if now <= started

        elapsed = now - started
        next if elapsed < @@threshold_ns

        @@reported = true
        report(id, elapsed)
      end
    end

    private def self.report(id : Int32, elapsed_ns : UInt64) : Nil
      buf = uninitialized UInt8[256]
      len = 0
      len = append(buf.to_unsafe, len, "gcry: STOP-THE-WORLD STALLED ")
      len = append_u64(buf.to_unsafe, len, elapsed_ns // 1_000_000_u64)
      len = append(buf.to_unsafe, len, " ms in phase=")
      len = append(buf.to_unsafe, len, phase_name(id))
      len = append(buf.to_unsafe, len, " — every mutator is frozen and the collector is not\n")
      if id == PHASE_SUSPEND && @@suspend_waiting_id == SUSPEND_UNSET
        len = append(buf.to_unsafe, len, "gcry: the stop never reached the suspend wait — ")
        len = append(buf.to_unsafe, len, step_name(@@suspend_step))
        len = append(buf.to_unsafe, len, ". Reported once per stop\n")
      elsif id == PHASE_SUSPEND && @@suspend_waiting_id == 0_u64
        # The wait loop clears the breadcrumb when it finishes, so a zero here
        # does not mean "waiting on thread 0" — it means the loop is done and
        # the stall is after it, before the phase advances. Saying otherwise
        # sent a reader looking at thread handles for a stall that was not
        # there (CI run 32638359761, aarch64).
        len = append(buf.to_unsafe, len, "gcry: every thread acknowledged (")
        len = append_u64(buf.to_unsafe, len, @@suspend_acked.to_u64)
        len = append(buf.to_unsafe, len, " of ")
        len = append_u64(buf.to_unsafe, len, @@suspend_expected.to_u64)
        len = append(buf.to_unsafe, len, "); the stall is after the wait loop, " \
                                         "not in it. Reported once per stop\n")
      elsif id == PHASE_SUSPEND
        # This phase does not wait on a lock — it waits for a thread to
        # acknowledge its suspend signal. Naming it is the whole point.
        len = append(buf.to_unsafe, len, "gcry: waiting for thread 0x")
        len = append_hex(buf.to_unsafe, len, @@suspend_waiting_id)
        len = append(buf.to_unsafe, len, " to acknowledge its suspend signal; ")
        len = append_u64(buf.to_unsafe, len, @@suspend_acked.to_u64)
        len = append(buf.to_unsafe, len, " of ")
        len = append_u64(buf.to_unsafe, len, @@suspend_expected.to_u64)
        len = append(buf.to_unsafe, len, " already have. Reported once per stop\n")
      else
        len = append(buf.to_unsafe, len, "gcry: it is waiting on something a suspended thread holds; " \
                                         "reported once per stop\n")
      end
      LibC.write(2, buf.to_unsafe, LibC::SizeT.new(len))
    end

    private def self.append(buf : UInt8*, len : Int32, str : String) : Int32
      i = 0
      n = str.bytesize
      src = str.to_unsafe
      while i < n && len < 250
        buf[len] = src[i]
        len += 1
        i += 1
      end
      len
    end

    # A `pthread_t` is only useful in the form the rest of gcry prints it in.
    private def self.append_hex(buf : UInt8*, len : Int32, value : UInt64) : Int32
      digits = uninitialized UInt8[16]
      count = 0
      v = value
      if v == 0
        digits[0] = '0'.ord.to_u8
        count = 1
      else
        while v > 0 && count < 16
          nib = (v & 0xf).to_u8
          digits[count] = nib < 10 ? ('0'.ord.to_u8 + nib) : ('a'.ord.to_u8 + (nib - 10))
          v >>= 4
          count += 1
        end
      end
      i = count - 1
      while i >= 0 && len < 250
        buf[len] = digits[i]
        len += 1
        i -= 1
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
      while i >= 0 && len < 250
        buf[len] = digits[i]
        len += 1
        i -= 1
      end
      len
    end

    private def self.write_str(str : String) : Nil
      LibC.write(2, str.to_unsafe, LibC::SizeT.new(str.bytesize))
    end

    private def self.now_ns : UInt64
      Clock.monotonic_ns
    end
  end
end
