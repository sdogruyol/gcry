require "../../src/gcry"
require "spec"

# The idle collector is exempt from the suspend signal, on the grounds that
# between collections it only reads. Until 2026-10-12 it was exempt from its
# birth, and its birth is a mutator's: `Thread#start` pushes the thread onto
# Crystal's list and then allocates its main `Fiber`. Started at the end of
# one collection, it raced the next stop, which let it run on: in the
# window-free arm of `make chunk-list-drift` it inserted a chunk into the
# index during the stop in 69 of 100 children, with the collector reading
# that index unlocked. It is exempt now only once it has stored itself as
# such (`IdleRelease.signal_exempt?`), under `Thread.lock`.
#
# The thread is held in its birth, before that store, counting as it spins,
# and a collection watches the count from inside the stopped world. A stop
# that suspends it sees the count stand still; the pre-fix rule — exempt as
# soon as `@@thread` names it — leaves it running, and the count moves.
# The hold is released from inside that stop, so the thread's store then
# waits on the `Thread.lock` the stop holds until the world restarts.
#
# A process of its own: the idle thread is born once per process, and
# `GCRY_IDLE_RELEASE_MS=0` keeps the collections before the hold is armed
# from starting it. Linux only: the exemption is the Linux signal path's,
# Darwin suspends the thread with the rest.
{% skip_file unless flag?(:linux) %}

private IDLE_BIRTH_WATCH_NS = 20_000_000_u64

# Class state and a proc that captures nothing: the process heap lives in libc
# memory the collector does not scan, so a closure only it held would be swept.
private module IdleBirthWatch
  @@watched = 0
  @@moved = UInt64::MAX

  def self.call(event : Gcry::Heap::CollectionEvent) : Nil
    return unless event.post_stop_world?
    before = Gcry::IdleRelease.birth_spins
    t0 = Gcry::Clock.monotonic_ns
    while Gcry::Clock.monotonic_ns &- t0 < IDLE_BIRTH_WATCH_NS
      Intrinsics.pause
    end
    @@moved = Gcry::IdleRelease.birth_spins &- before
    @@watched += 1
    Gcry::IdleRelease.release_birth_hold
  end

  def self.watched : Int32
    @@watched
  end

  def self.moved : UInt64
    @@moved
  end
end

describe "Regression: the idle thread is stopped until its birth is over" do
  it "in a process of its own" do
    captured = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!, ["-e", "idle-birth-stopped child"],
      env: {"GCRY_IDLE_BIRTH_CHILD" => "1", "GCRY_IDLE_RELEASE_MS" => "0"},
      output: captured, error: captured)
    fail "child #{status.inspect}:\n#{captured}" unless status.success?
    captured.to_s.should contain("1 examples, 0 failures")
  end

  it "idle-birth-stopped child" do
    next unless ENV["GCRY_IDLE_BIRTH_CHILD"]? == "1"
    heap = Gcry.default_heap
    fail "the idle thread is armed already; it may have been born before the hold" if Gcry::IdleRelease.armed?
    Gcry::IdleRelease.test_birth_hold = true
    Gcry::IdleRelease.idle_ms = 3_600_000_u64
    # Ends by starting the idle thread, which stops at the hold.
    GC.collect
    deadline = Time.instant + 10.seconds
    until Gcry::IdleRelease.birth_spins > 0
      fail "the idle thread never reached its birth hold" if Time.instant > deadline
      sleep 1.millisecond
    end

    heap.collection_event_hook = ->(event : Gcry::Heap::CollectionEvent) { IdleBirthWatch.call(event) }
    GC.collect
    heap.collection_event_hook = nil
    IdleBirthWatch.watched.should eq(1)
    IdleBirthWatch.moved.should eq(0)

    # Released inside that stop: the thread goes on to exempt itself, and a
    # stop from then on leaves it asleep without waiting on it.
    idle = nil
    Thread.each { |t| idle = t if t.name == "gc-idle" }
    idle = idle.not_nil!
    deadline = Time.instant + 10.seconds
    until Gcry::IdleRelease.signal_exempt?(idle)
      fail "the idle thread never became exempt" if Time.instant > deadline
      sleep 1.millisecond
    end
    2.times { GC.collect }
  end
end
