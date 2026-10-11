require "../../src/gcry"
require "spec"

# The readability probe under fd pressure. Every `safe: true` range scan asks
# the kernel whether a page is readable before reading it — the collecting
# thread's stack, the other threads' and fibers', static ranges and
# `GC_add_roots` ranges alike. Until 2026-10-10 the probe was a pipe created
# by the first collection, and a `pipe()` that failed there (EMFILE, ENFILE)
# left every page answering "unreadable": the collection dropped every root
# it probes. With RLIMIT_NOFILE 64 and the table full, the first `GC.collect`
# took the process down with SIGSEGV. The pipe was also made without
# O_CLOEXEC, so its two fds went into every child `Process.run` started.
#
# Linux only: the CLOEXEC half reads `/proc/self/fd`, and the scenario needs
# the first collection to come after the table is full, which a fresh process
# arranges the same way on every platform but is only measured here.
{% skip_file unless flag?(:linux) %}

private FD_PRESSURE_LIMIT = 64_u64

# The address of the block, XORed so no scanned word refers to it.
private FD_PRESSURE_MASK = 0x5a5a_5a5a_5a5a_5a5a_u64

# The probe pipe's two ends, as `readlink` spells them. Only these: a CI
# runner hands the process pipes of its own at fds 3 and up, inheritable, and
# every child lists those too (x86_64 CI, `pipe:[12625]` and `pipe:[12626]`).
private def fd_pressure_probe_pipes : Array(String)
  rd, wr = Gcry::Roots.probe_fds
  [rd, wr].compact_map do |fd|
    next if fd < 0
    File.readlink("/proc/self/fd/#{fd}") rescue nil
  end
end

@[NoInline]
private def fd_pressure_collect(hidden : UInt64) : Bool
  GC.collect
  Gcry.live?(Pointer(Void).new(hidden ^ FD_PRESSURE_MASK))
end

# The only reference to the block is this frame's.
@[NoInline]
private def fd_pressure_holder : Bool
  block = GC.malloc(64)
  survived = fd_pressure_collect(block.address ^ FD_PRESSURE_MASK)
  Gcry::Roots.keep_alive(block)
  survived
end

describe "Regression: the readability probe survives fd exhaustion" do
  # In a process of its own: before the fix the collection crashed.
  it "keeps stack roots when the fd table is full at the first collection" do
    captured = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!, ["-e", "fd-pressure child"],
      env: {"GCRY_FD_PRESSURE_CHILD" => "1"}, output: captured, error: captured)
    fail "#{status}\n#{captured}" unless status.success?
    captured.to_s.should contain("1 examples, 0 failures")
  end

  # The run, by the example above in a fresh process; a no-op anywhere else.
  it "fd-pressure child" do
    next unless ENV["GCRY_FD_PRESSURE_CHILD"]? == "1"
    # The scenario is a first collection with no fd to spare.
    Gcry.default_heap.collections.should eq(0)

    LibC.getrlimit(LibC::RLIMIT_NOFILE, out saved).should eq(0)
    lowered = saved
    lowered.rlim_cur = FD_PRESSURE_LIMIT
    LibC.setrlimit(LibC::RLIMIT_NOFILE, pointerof(lowered)).should eq(0)
    held = [] of Int32
    loop do
      fd = LibC.open("/dev/null", LibC::O_RDONLY | LibC::O_CLOEXEC)
      break if fd < 0
      held << fd
    end
    Errno.value.should eq(Errno::EMFILE)

    survived = fd_pressure_holder

    held.each { |fd| LibC.close(fd) }
    LibC.setrlimit(LibC::RLIMIT_NOFILE, pointerof(saved)).should eq(0)
    survived.should be_true

    # The probe's pipe, made at init while fds were free, must not reach a
    # child; on master its fds were in every one.
    rd, wr = Gcry::Roots.probe_fds
    {rd, wr}.each do |fd|
      fd.should be >= 0
      (LibC.fcntl(fd, LibC::F_GETFD) & LibC::FD_CLOEXEC).should_not eq(0)
    end
    ours = fd_pressure_probe_pipes
    ours.size.should eq(2)
    listing = File.tempfile("fd_pressure")
    begin
      # The status is not the check: what the child listed is.
      Process.run("/bin/sh", ["-c", "for f in /proc/self/fd/*; do readlink \"$f\"; done; exit 0"],
        output: listing, error: Process::Redirect::Close).success?.should be_true
      listing.flush
      seen = File.read(listing.path).lines
      seen.should_not be_empty
      (ours & seen).should be_empty
    ensure
      listing.delete
    end
  end
end
