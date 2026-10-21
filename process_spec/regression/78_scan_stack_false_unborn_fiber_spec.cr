require "../../src/gcry"
require "spec"

# A collection asked for with `scan_stack: false` skipped every stack, not just
# the caller's: the root phase gated the other threads' stacks, their
# registers, their `Thread` objects and every fiber's stack on that one flag.
# The caller can speak for its own frames only. On the process heap every
# other thread is a mutator the stop froze wherever it was, and gcry starts
# one of its own at the end of the first collection, the idle thread
# (`IdleRelease.ensure_started`).
#
# `Thread#start` pushes the thread onto Crystal's thread list, then
# `Fiber.new` allocates its main fiber and, last, pushes that onto the fiber
# list, whose mutex a stop holds from before the first suspend to after the
# last resume. Between the allocation and the push the new `Fiber` is in that
# thread's frame and nowhere else, and a thread that reaches the push while a
# collection is running waits there with it until the world restarts. A
# `scan_stack: false` collection in that window freed the fiber; the push then
# published the freed block, the next allocation of its class took it, and
# the next fiber walk read the new owner's bytes as `Fiber#next`.
#
# That is the `make nursery-tlab-smoke` crash on macos-latest, CI run
# 38975094005 (job 117222511786): SIGSEGV at 0x6c696665725f6271 in
# `Heap#scan_all_fiber_roots`, a major in `released_chunk_probe`. The address
# is "ab_refil" + 0x10, the load of `Fiber#running?` (`@context.resumable`,
# offset 16) through a `next` (offset 96) that held bytes 84–91 of the line
# the smoke had just printed ("… tlab_refills=10"), a `String` built in the
# block the idle thread's main fiber had been allocated in. The smoke's
# `minor_collect(scan_stack: false)` in `claim_probe` had run while the idle
# thread, started by the smoke's first minor, was in its birth. 1 of about
# 460 Darwin runs of that gate in CI; 19 of 4 000 on the two macOS runners
# and 0 of 4 000 with the fix; never in 1 100 runs on Linux, where the new
# thread is presumably past the push long before
# (bench/log/macos/2026-10-19-tlab-nursery-crash/).
#
# Not specific to the nursery or to the headered layout: any collection with
# `scan_stack: false` on the process heap, a major in the default layout
# included. `GC.collect` and every automatic collection always scan every
# stack and were never exposed.
#
# Forced here rather than waited for: a holder thread takes the fiber list's
# mutex, so a new thread stops in that push with its fiber allocated; the
# collector is told not to take the mutex for its stop
# (`fiber_list_unlocked`, the research knob), and collects with
# `scan_stack: false` while the thread waits. Then the holder lets go and the
# new thread asks whether its own main fiber is still an allocated block
# whose stack is its own. Before the fix it was free in every run, majors in
# both layouts and minors in the headered one (120 of 120 children on Linux,
# 300 of 300 on each macOS runner); after it, allocated in every run.
#
# A process of its own: the walk after a freed fiber's push reads freed
# memory, and the parent's other examples must not inherit that.
# `GCRY_IDLE_RELEASE_MS=0` keeps the idle thread out of it — it would be born
# at the child's first collection and wait in the same push.

private module UnbornFiber
  # Shared with the threads through class state: the process heap lives in
  # libc memory the collector does not scan. `Atomic` is a struct, so it is
  # only ever touched here, through the class variable, never returned.
  @@locked = Atomic(Int32).new(0)
  @@release = Atomic(Int32).new(0)
  # -1 unset, 1 allocated and its own, 0 not an allocated block, 2 an
  # allocated block whose stack is another thread's (freed and reused).
  @@verdict = Atomic(Int32).new(-1)
  @@fiber = Atomic(UInt64).new(0_u64)

  # The holder thread: the fiber list's mutex, until the main thread is done.
  def self.hold_fiber_list : Nil
    fail "the fiber list does not exist yet" unless Fiber.gcry_lock_list
    @@locked.set(1)
    until @@release.get == 1
      Thread.yield
    end
    Fiber.gcry_unlock_list
  end

  # The new thread, once its birth is over: is its main fiber still the
  # allocated block it was given, holding its own stack?
  def self.judge_own_fiber : Nil
    fiber = Fiber.current
    @@fiber.set(fiber.object_id)
    bounds = Gcry::Platform.current_pthread_stack_bounds
    if !Gcry.default_heap.live?(Pointer(Void).new(fiber.object_id))
      @@verdict.set(0)
    elsif bounds && fiber.@stack.bottom.address != bounds[1].address
      @@verdict.set(2)
    else
      @@verdict.set(1)
    end
  end

  def self.deadline_passed?(start : UInt64, seconds : Int32) : Bool
    Gcry::Clock.monotonic_ns &- start > seconds.to_u64 * 1_000_000_000_u64
  end

  def self.child(minor : Bool) : Nil
    heap = Gcry.default_heap
    if minor
      heap.nursery_enabled = true
      unless heap.nursery_enabled
        # Headerless: `nursery_enabled=` is a no-op and a minor returns at
        # once, so there is no minor to test. The major child covers this
        # layout.
        puts "unborn-fiber: no nursery in this layout"
        return
      end
    end

    holder = Thread.new(name: "fiber-list-holder") { UnbornFiber.hold_fiber_list }
    start = Gcry::Clock.monotonic_ns
    until @@locked.get == 1
      fail "the holder never took the fiber list's mutex" if deadline_passed?(start, 10)
      Thread.yield
    end

    # The stop must not wait for the mutex the holder keeps. The walk it does
    # unlocked is safe here: the only thread that could edit the list is the
    # one waiting to.
    heap.fiber_list_unlocked = true
    activity = heap.allocation_activity
    unborn = Thread.new(name: "unborn") { UnbornFiber.judge_own_fiber }

    # In the window once it is on the thread list and has allocated: its main
    # fiber is its first allocation, and it cannot get past the push.
    start = Gcry::Clock.monotonic_ns
    loop do
      listed = false
      Thread.each { |t| listed = true if t.same?(unborn) }
      break if listed && heap.allocation_activity != activity
      fail "the new thread never allocated its main fiber" if deadline_passed?(start, 10)
      Thread.yield
    end

    # Several, spaced out, so that at least one stops the thread inside the
    # push whatever the scheduler did with it before it got there.
    collections = heap.collections
    20.times do
      if minor
        heap.minor_collect(scan_stack: false)
      else
        heap.collect(scan_stack: false)
      end
      pause = Gcry::Clock.monotonic_ns
      until Gcry::Clock.monotonic_ns &- pause > 1_000_000_u64
        Thread.yield
      end
    end
    ran = heap.collections &- collections

    @@release.set(1)
    holder.join
    unborn.join
    heap.fiber_list_unlocked = false

    verdict = @@verdict.get
    puts "unborn-fiber: #{minor ? "minor" : "major"} collections #{ran}, verdict #{verdict}, fiber 0x#{@@fiber.get.to_s(16)}"
    fail "no collection ran while the new thread waited" if ran == 0
    case verdict
    when 0 then fail "the new thread's main fiber was freed by a scan_stack: false collection during its birth"
    when 2 then fail "the new thread's main fiber was freed during its birth and the block reused"
    when 1 # allocated, and its own
    else fail "the new thread never reported"
    end
  end
end

describe "Regression: scan_stack: false skips only the caller's stack" do
  {% for kind in %w[major minor] %}
    it "keeps a thread's main fiber allocated in its birth across a {{kind.id}}" do
      captured = IO::Memory.new
      status = Process.run(Process.executable_path.not_nil!, ["-e", "unborn-fiber child"],
        env: {"GCRY_UNBORN_FIBER_CHILD" => {{kind}}, "GCRY_IDLE_RELEASE_MS" => "0"},
        output: captured, error: captured)
      fail "child #{status.inspect}:\n#{captured}" unless status.success?
      captured.to_s.should contain("1 examples, 0 failures")
    end
  {% end %}

  it "unborn-fiber child" do
    kind = ENV["GCRY_UNBORN_FIBER_CHILD"]?
    next unless kind
    UnbornFiber.child(kind == "minor")
  end
end
