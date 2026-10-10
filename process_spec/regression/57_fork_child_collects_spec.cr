require "../../src/gcry"
require "spec"

# A forked child has one thread, the one that called `fork`, and Crystal's
# thread list still names every thread the parent had. Boehm drops the rest
# in its child handler (`GC_remove_all_threads_but_me`); until 2026-10-10
# gcry's reset its own tables and left the list alone. The child's first
# stop then signalled a thread that does not exist, waited for an
# acknowledgement nothing could send, and never gave up on it: in a fork
# child glibc answers `pthread_kill(id, 0)` for such a handle with EINVAL,
# not the ESRCH the abandonment asked for. The idle-release thread, on by
# default and started by the parent's first collection, was enough: the
# child printed `SUSPEND STALLED … pthread_kill(0) → 22` and spun for good.
# Any user `Thread` does the same, so the parent here has both.
#
# The child runs in its own process by construction and only `_exit`s, so a
# hang costs this example its timeout and not the suite. Its verdict comes
# back through a shared mapping rather than its exit status: once anything
# in the suite has run `Process.run`, Crystal's SIGCHLD handler reaps every
# child and `waitpid` here answers ECHILD (bench/fork_reinit.cr). Linux only:
# the defect is the Linux signal stop, and Windows has no `fork`.
{% skip_file unless flag?(:linux) %}

# Generous for a fork and two collections of the whole suite's heap on the
# slow aarch64 runner; green takes milliseconds of it, red all of it.
private FORK_CHILD_TIMEOUT = 20.seconds

private FORK_CHILD_PENDING = 0_i64
private FORK_CHILD_OK      = 1_i64
private FORK_CHILD_LOST    = 2_i64
private FORK_CHILD_RAISED  = 3_i64

private def fork_child_nap : Nil
  ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 1_000_000)
  LibC.nanosleep(pointerof(ts), nil)
end

private def fork_child_idle_listed? : Bool
  found = false
  Thread.unsafe_each { |thread| found = true if Gcry::IdleRelease.thread?(thread) }
  found
end

# The child's whole run. Nothing here may return: unwinding into the spec
# runner in a forked copy of it would run the rest of the suite twice.
private def fork_child_run(verdict : Int64*) : NoReturn
  begin
    GC.collect
    GC.collect
    kept = Array(String).new(1_000) { |i| "fork-child-#{i}" }
    GC.collect
    ok = kept.size == 1_000 && kept[999] == "fork-child-999"
    Atomic::Ops.store(verdict, ok ? FORK_CHILD_OK : FORK_CHILD_LOST, :sequentially_consistent, true)
    LibC._exit(0)
  rescue
    Atomic::Ops.store(verdict, FORK_CHILD_RAISED, :sequentially_consistent, true)
    LibC._exit(15)
  end
end

describe "Regression: a forked child collects with the parent's threads gone" do
  it "stops the world in the child without waiting on a parent thread" do
    if Gcry::IdleRelease.armed?
      # The idle thread starts at the end of a collection.
      GC.collect
      deadline = Time.instant + 5.seconds
      until fork_child_idle_listed?
        fail "the idle-release thread never appeared on Crystal's list" if Time.instant > deadline
        fork_child_nap
      end
    end

    started = Atomic(Int32).new(0)
    release = Atomic(Int32).new(0)
    parked = Thread.new(name: "spec57-parked") do
      started.set(1)
      until release.get == 1
        fork_child_nap
      end
    end

    begin
      deadline = Time.instant + 5.seconds
      until started.get == 1
        fail "the parked thread never started" if Time.instant > deadline
        fork_child_nap
      end

      shared = LibC.mmap(nil, LibC::SizeT.new(4096), LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_SHARED | LibC::MAP_ANON, -1, 0)
      shared.address.should_not eq(UInt64::MAX)
      verdict = shared.as(Int64*)
      verdict.value = FORK_CHILD_PENDING

      pid = LibC.fork
      pid.should be >= 0
      fork_child_run(verdict) if pid == 0

      deadline = Time.instant + FORK_CHILD_TIMEOUT
      hung = false
      while Atomic::Ops.load(verdict, :sequentially_consistent, true) == FORK_CHILD_PENDING
        status = 0
        # Exited without a verdict: a crash, not a hang. Stop waiting.
        break if LibC.waitpid(pid, pointerof(status), LibC::WNOHANG) == pid
        if Time.instant > deadline
          hung = true
          LibC.kill(pid, LibC::SIGKILL)
          break
        end
        fork_child_nap
      end
      result = Atomic::Ops.load(verdict, :sequentially_consistent, true)
      # Reap it if Crystal's handler has not; ECHILD if it has.
      status = 0
      LibC.waitpid(pid, pointerof(status), 0)
      LibC.munmap(shared, LibC::SizeT.new(4096))

      fail "the child hung in its first collection (killed after #{FORK_CHILD_TIMEOUT})" if hung
      result.should eq(FORK_CHILD_OK)
    ensure
      release.set(1)
      parked.join
    end
  end
end
