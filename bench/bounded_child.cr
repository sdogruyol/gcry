# Run a child with a deadline.
#
# The race gates spawn a child per attempt and wait for it. That is fine while
# the failure mode is a crash, which is what the broken-on-purpose arms were
# built to produce — but undefined behaviour is not obliged to crash. On
# 2026-08-23 the `GCRY_TRIM_UNLOCKED=1` arm of `large_cache_race` hung on
# aarch64 instead, and with no deadline it took the whole CI job down with it
# (run `32645403155`, 13 min, exit 124).
#
# For an arm that must fail, a hang *is* a failure — it just has to be a bounded
# one. For an arm that must survive, a hang is a failure too. Either way the
# caller wants the same answer: did this child finish cleanly inside the budget?
module BoundedChild
  DEFAULT_TIMEOUT = (ENV["BENCH_CHILD_TIMEOUT_S"]?.try(&.to_i?) || 120).seconds

  # `capture` is set only for a child that outlived its deadline: what
  # `bench/stall_capture.sh` saw before the kill — every thread's state and,
  # if the child declared itself traceable, a gdb backtrace of each. A hang
  # killed with nothing said about it cost a day twice (2026-09-25); callers
  # decide where it goes, since it runs to thousands of lines.
  record Result, ok : Bool, timed_out : Bool, output : String, capture : String? = nil

  CAPTURE_SCRIPT = "#{__DIR__}/stall_capture.sh"

  # Runs *exe* with *args*, capturing stdout+stderr. `ok` is false if the child
  # exited non-zero **or** outlived the deadline.
  def self.run(exe : String,
               args : Array(String),
               env : Hash(String, String) = {} of String => String,
               timeout : Time::Span = DEFAULT_TIMEOUT) : Result
    tmp = File.tempfile("bench-child")
    begin
      process = Process.new(exe, args, env: env, output: tmp, error: tmp)
      deadline = Time.instant + timeout
      timed_out = false
      loop do
        break if process.terminated?
        if Time.instant >= deadline
          timed_out = true
          break
        end
        sleep 20.milliseconds
      end

      capture = nil
      if timed_out
        {% if flag?(:linux) %}
          if File.exists?(CAPTURE_SCRIPT)
            capture = String.build do |io|
              Process.run(CAPTURE_SCRIPT, [process.pid.to_s], output: io, error: io) rescue nil
            end
          end
        {% end %}
        # Force termination (SIGKILL on Unix, TerminateProcess on Windows):
        # a process wedged inside the allocator cannot run an allocating handler.
        process.terminate(graceful: false) rescue nil
      end
      status = process.wait
      tmp.flush
      output = File.read(tmp.path)
      output += "\nbench: child exceeded #{timeout.total_seconds.to_i}s and was killed\n" if timed_out
      Result.new(ok: status.success? && !timed_out, timed_out: timed_out, output: output, capture: capture)
    ensure
      tmp.delete rescue nil
    end
  end
end
