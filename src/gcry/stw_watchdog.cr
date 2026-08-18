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

    POLL_NS = 50_000_000_u64 # 50 ms

    @@phase = PHASE_NONE
    @@since_ns = 0_u64
    @@threshold_ns = 0_u64
    @@started = false
    @@reported = false

    def self.phase_name(id : Int32) : String
      case id
      when PHASE_SUSPEND    then "suspend"
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
      len = append(buf.to_unsafe, len, "gcry: it is waiting on something a suspended thread holds; " \
                                       "reported once per stop\n")
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
