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
# What the dead threads held must stay as reachable as it was at the fork.
# Unlisting them and nothing more swept it: a parked thread's locked
# `Thread::Mutex` was finalized, and `pthread_mutex_destroy` raised "Device
# or resource busy" out of the child's `GC.collect`. Scanning their stacks
# where they had been was not enough either, on the glibc the CI runners
# have (2.39): its child handler puts every dead thread's stack in its stack
# cache, and the child's next new thread is handed one and writes over it,
# or the cache unmaps it — the same EBUSY in every CI process_spec run of
# 2026-10-10. So eight parked threads here each hold a locked mutex and a
# filled buffer, both only in slots of their own frames, the child starts
# threads that dirty their stacks before it collects, and it must find every
# buffer still allocated and intact — read through addresses the threads
# left, masked, in the shared page — after three collections that raise
# nothing. glibc 2.43 keeps the stacks, so there this arm is green either way.
#
# The child runs in its own process by construction and only `_exit`s, so a
# hang costs this example its timeout and not the suite. Its verdict comes
# back through a shared mapping rather than its exit status: once anything
# in the suite has run `Process.run`, Crystal's SIGCHLD handler reaps every
# child and `waitpid` here answers ECHILD (bench/fork_reinit.cr). Linux only:
# the defect is the Linux signal stop, and Windows has no `fork`.
{% skip_file unless flag?(:linux) %}

# Generous for a fork and a few collections of the whole suite's heap on the
# slow aarch64 runner; green takes milliseconds of it, red all of it.
private FORK_CHILD_TIMEOUT = 20.seconds

private FORK_CHILD_PENDING = 0_i64
private FORK_CHILD_OK      = 1_i64
private FORK_CHILD_LOST    = 2_i64
private FORK_CHILD_RAISED  = 3_i64
private FORK_CHILD_SWEPT   = 4_i64
private FORK_CHILD_DAMAGED = 5_i64

private FORK_CHILD_PAGE = 4096
# Parked parent threads, each with its own mutex and buffer: enough stacks
# that glibc's reuse meets some of them whichever it picks. Under glibc 2.39
# eight of them lost 10 of the 16 marker words on their stacks.
private FORK_CHILD_HOLDERS = 8
# The page's last words: holder *k*'s buffer address in word `LAST - k`,
# masked so that nothing reading the page as words could take it for a
# pointer.
private FORK_CHILD_LAST_WORD = FORK_CHILD_PAGE // 8 - 1
private FORK_CHILD_HELD_KEY  = 0x5a5a_a5a5_c3c3_3c3c_u64
private FORK_CHILD_HELD_SIZE =                       256
# Threads the child starts and joins before it collects, and how much of its
# own stack each one writes.
private FORK_CHILD_CHURN       = 8
private FORK_CHILD_CHURN_BYTES = 128 * 1024

private def fork_child_pattern(i : Int32) : UInt8
  (0xa5 ^ (i & 0xff)).to_u8
end

private def fork_child_intact?(bytes : UInt8*) : Bool
  FORK_CHILD_HELD_SIZE.times { |i| return false unless bytes[i] == fork_child_pattern(i) }
  true
end

private def fork_child_nap : Nil
  ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 1_000_000)
  LibC.nanosleep(pointerof(ts), nil)
end

private def fork_child_idle_listed? : Bool
  found = false
  Thread.unsafe_each { |thread| found = true if Gcry::IdleRelease.thread?(thread) }
  found
end

# Writes over *bytes* of this thread's stack, the way a new thread's frames
# would: whatever a dead thread left there is gone.
private def fork_child_dirty_stack : Nil
  dirt = uninitialized UInt8[FORK_CHILD_CHURN_BYTES]
  dirt.to_unsafe.clear(FORK_CHILD_CHURN_BYTES)
  Atomic::Ops.store(dirt.to_unsafe, 1_u8, :sequentially_consistent, true)
end

# Where the child leaves the message of anything it raised, after the verdict
# word: bytes 8 on, NUL-terminated, in the shared page.
private FORK_CHILD_MESSAGE_BYTES = 4000

# The child's whole run. Nothing here may return: unwinding into the spec
# runner in a forked copy of it would run the rest of the suite twice.
private def fork_child_run(verdict : Int64*) : NoReturn
  begin
    GC.collect
    churn = Array(Thread).new(FORK_CHILD_CHURN) { Thread.new { fork_child_dirty_stack } }
    churn.each(&.join)
    GC.collect
    kept = Array(String).new(1_000) { |i| "fork-child-#{i}" }
    GC.collect
    code = kept.size == 1_000 && kept[999] == "fork-child-999" ? FORK_CHILD_OK : FORK_CHILD_LOST
    words = verdict.as(UInt64*)
    FORK_CHILD_HOLDERS.times do |k|
      break unless code == FORK_CHILD_OK
      held = Pointer(UInt8).new(words[FORK_CHILD_LAST_WORD - k] ^ FORK_CHILD_HELD_KEY)
      if !Gcry.default_heap.live?(held.as(Void*))
        code = FORK_CHILD_SWEPT
      elsif !fork_child_intact?(held)
        code = FORK_CHILD_DAMAGED
      end
    end
    Atomic::Ops.store(verdict, code, :sequentially_consistent, true)
    LibC._exit(0)
  rescue ex
    text = "#{ex.class}: #{ex.message}"
    n = Math.min(text.bytesize, FORK_CHILD_MESSAGE_BYTES - 1)
    message = (verdict + 1).as(UInt8*)
    text.to_unsafe.copy_to(message, n)
    message[n] = 0_u8
    Atomic::Ops.store(verdict, FORK_CHILD_RAISED, :sequentially_consistent, true)
    LibC._exit(15)
  end
end

describe "Regression: a forked child collects with the parent's threads gone" do
  it "stops the world in the child without waiting on a parent thread, and keeps what they held" do
    if Gcry::IdleRelease.armed?
      # The idle thread starts at the end of a collection.
      GC.collect
      deadline = Time.instant + 5.seconds
      until fork_child_idle_listed?
        fail "the idle-release thread never appeared on Crystal's list" if Time.instant > deadline
        fork_child_nap
      end
    end

    shared = LibC.mmap(nil, LibC::SizeT.new(FORK_CHILD_PAGE), LibC::PROT_READ | LibC::PROT_WRITE,
      LibC::MAP_SHARED | LibC::MAP_ANON, -1, 0)
    shared.address.should_not eq(UInt64::MAX)
    verdict = shared.as(Int64*)
    verdict.value = FORK_CHILD_PENDING

    started = Atomic(Int32).new(0)
    release = Atomic(Int32).new(0)
    intact = Atomic(Int32).new(0)
    holders = Array(Thread).new(FORK_CHILD_HOLDERS) do |k|
      Thread.new(name: "spec57-held-#{k}") do
        # The mutex and the buffer live in these two volatile slots of this
        # frame and nowhere else, so in the child they are reachable only
        # through this dead thread's stack.
        held = StaticArray(UInt64, 2).new(0_u64)
        slots = pointerof(held).as(UInt64*)
        mutex = Thread::Mutex.new
        mutex.lock
        buffer = Bytes.new(FORK_CHILD_HELD_SIZE) { |i| fork_child_pattern(i) }
        Atomic::Ops.store(slots, mutex.object_id, :sequentially_consistent, true)
        Atomic::Ops.store(slots + 1, buffer.to_unsafe.address, :sequentially_consistent, true)
        shared.as(UInt64*)[FORK_CHILD_LAST_WORD - k] = buffer.to_unsafe.address ^ FORK_CHILD_HELD_KEY
        mutex = nil
        buffer = Bytes.empty
        started.add(1)
        until release.get == 1
          fork_child_nap
        end
        bytes = Pointer(UInt8).new(Atomic::Ops.load(slots + 1, :sequentially_consistent, true))
        intact.add(1) if fork_child_intact?(bytes)
        Pointer(Void).new(Atomic::Ops.load(slots, :sequentially_consistent, true)).as(Thread::Mutex).unlock
      end
    end

    begin
      deadline = Time.instant + 5.seconds
      until started.get == FORK_CHILD_HOLDERS
        fail "the holder threads never started" if Time.instant > deadline
        fork_child_nap
      end

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
      raised = result == FORK_CHILD_RAISED ? String.new((verdict + 1).as(UInt8*)) : ""
      # Reap it if Crystal's handler has not; ECHILD if it has.
      status = 0
      LibC.waitpid(pid, pointerof(status), 0)

      fail "the child hung in its first collection (killed after #{FORK_CHILD_TIMEOUT})" if hung
      fail "the child raised: #{raised}" if result == FORK_CHILD_RAISED
      fail "the child swept a block only a dead parent thread's stack held" if result == FORK_CHILD_SWEPT
      fail "a block a dead parent thread held came out of the child's collections damaged" if result == FORK_CHILD_DAMAGED
      result.should eq(FORK_CHILD_OK)
    ensure
      release.set(1)
      holders.each(&.join)
      LibC.munmap(shared, LibC::SizeT.new(FORK_CHILD_PAGE))
    end
    intact.get.should eq(FORK_CHILD_HOLDERS)
  end
end
