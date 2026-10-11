require "../../src/gcry"
require "spec"

# What a stop leaves behind in the thread it stopped. Boehm installs both of
# its stop signals with `SA_RESTART` and saves and restores `errno` around
# its suspend handler, so a collection is invisible to a stopped thread's
# syscalls. Until 2026-10-10 gcry's suspend handler had neither, and the
# stdlib's resume handler is installed with `sa_flags = 0`:
#
#   - a thread blocked in a restartable syscall — `read(2)` on a pipe here,
#     equally `write`, `accept`, `connect`, `flock`, `wait4` — had it fail
#     with EINTR once per collection, which Crystal's blocking IO raises as
#     `IO::Error`; 20 of 20 collections on master, 0 under Boehm;
#   - `sigsuspend` always leaves EINTR in `errno`, so a thread stopped between
#     a failing libc call and its read of `errno` read EINTR instead: 244 of
#     204 866 reads, and `File.info?` on a missing path raised "Interrupted
#     system call" beside 2 000 collections; 0 under Boehm.
#
# The idle-release thread collects on its own, so neither needs a program
# that calls `GC.collect` to happen. Linux only: Darwin stops threads with
# Mach `thread_suspend`, which interrupts no syscall and sends no signal,
# and Windows has neither `pipe` nor `pthread_kill`.
{% skip_file unless flag?(:linux) %}

private RESTART_COLLECTIONS   = 20
private RESTART_STRAY_RESUMES =  5

# The errno check is probabilistic, so it is bounded twice. A stop has to land
# between the failing call and the read; with this window, 44 of 100
# collections did on master.
private ERRNO_COLLECTIONS = 100
private ERRNO_BUDGET      = 2.seconds
private ERRNO_WINDOW      = 20_000

describe "Regression: a stop is invisible to the stopped thread's syscalls" do
  it "restarts a blocking read(2) that a suspend or resume signal interrupted" do
    fds = uninitialized StaticArray(LibC::Int, 2)
    LibC.pipe(fds).should eq(0)
    started = Atomic(Int32).new(0)
    eintr = Atomic(Int32).new(0)
    result = Atomic(Int64).new(0)
    reader = Thread.new do
      byte = 0_u8
      started.set(1)
      loop do
        n = LibC.read(fds[0], pointerof(byte), 1)
        if n < 0 && Errno.value == Errno::EINTR
          eintr.add(1)
          next
        end
        result.set(n.to_i64)
        break
      end
    end
    until started.get == 1
      Thread.yield
    end
    # Long enough that the reader is inside `read`, not on its way to it.
    sleep 50.milliseconds

    RESTART_COLLECTIONS.times { GC.collect }
    # `start_world` resends a resume to a thread slow to drop its
    # acknowledgement, so a running thread can take one outside any stop.
    RESTART_STRAY_RESUMES.times do
      LibC.pthread_kill(reader.to_unsafe, GC.sig_resume.value).should eq(0)
      sleep 5.milliseconds
    end

    byte = 1_u8
    LibC.write(fds[1], pointerof(byte), 1).should eq(1)
    reader.join
    LibC.close(fds[0])
    LibC.close(fds[1])
    result.get.should eq(1)
    eintr.get.should eq(0)
  end

  it "leaves errno as the stopped thread last set it" do
    stop = Atomic(Int32).new(0)
    checks = Atomic(Int64).new(0)
    clobbered = Atomic(Int64).new(0)
    spin = Atomic(Int32).new(0)
    worker = Thread.new do
      path = "/nonexistent/gcry-53-errno".to_unsafe
      until stop.get != 0
        LibC.access(path, LibC::F_OK)
        # Pure computation between the call and the read, so a stop lands in
        # the window far more often than in the libc call itself.
        i = 0
        while i < ERRNO_WINDOW
          spin.get(:relaxed)
          i += 1
        end
        clobbered.add(1) unless Errno.value == Errno::ENOENT
        checks.add(1)
      end
    end
    until checks.get > 0
      Thread.yield
    end

    deadline = Time.instant + ERRNO_BUDGET
    collections = 0
    while collections < ERRNO_COLLECTIONS && Time.instant < deadline
      GC.collect
      collections += 1
    end
    stop.set(1)
    worker.join
    clobbered.get.should eq(0)
  end
end
