require "../../src/gcry"
require "spec"

# `GC.stop_world` / `GC_stop_world_external` beside collections, thread churn
# and `add_root` / `delete_root` (review of 2026-10-11). Boehm's external stop
# is `LOCK(); ENTER_GC(); STOP_WORLD()`, so it excludes collections and root
# edits for as long as it holds the world. gcry's called the bare stop and took
# none of the locks a collection takes first, which broke two things:
#
#   * `stop_world` drops dead threads' birth roots with `@roots.delete`,
#     trusting the caller to hold `@roots_lock`. Linux does it before any
#     thread is signalled, so a mutator inside `@roots_lock.sync { @roots.add
#     / delete }` ran beside it, and `Roots::Set` is a malloc'd list: a node
#     added there was dropped, or one being walked was freed. The reviewer's
#     version crashed in `Roots::Set#delete` under `GC::stop_world` 2 of 2.
#   * A collection and an external stop both passed `return if
#     @world_stopped`, and whichever restarted first opened the Monitor gate
#     and cleared `@stw_owner` under the other's stopped world: 395 of 401
#     collections reached MarkStart with another thread as the owner.
#
# The hook checks the second at every MarkStart, the ring of explicit roots
# the first, and the child's exit status the crash.

# Spec 62 only: the gate's state, read from inside a collection, which has no
# public reader because nothing outside the gate needs one.
module Gcry::MonitorGate
  def self.closed_for_external_stop_spec? : Bool
    @@stopped.get != 0
  end
end

private EXTERNAL_STOP_RUN_MS = 1500
# The child takes a few seconds. Before the fix it also hung, 1 of 5 runs:
# two stops racing for one world.
private EXTERNAL_STOP_CHILD_LIMIT_S = 60
# Roots each root thread keeps registered. Deleted oldest first, so every
# `delete_root` walks most of the list, which keeps the two root threads inside
# `@roots_lock` for most of the run.
private EXTERNAL_STOP_RING  = 256
private EXTERNAL_STOP_CHURN =  32
# Root threads store their objects XORed with this, so the only thing keeping
# one alive is the root, never a word the conservative scan can read.
private EXTERNAL_STOP_MASK  = 0x5a5a_5a5a_5a5a_5a5a_u64
private EXTERNAL_STOP_WORDS =                         8

private module ExternalStopCounters
  @@marks = Atomic(Int32).new(0)
  @@gate_open = Atomic(Int32).new(0)
  @@foreign_owner = Atomic(Int32).new(0)

  # The collecting thread at MarkStart, with every other thread stopped: no
  # allocation, no lock.
  def self.mark_start : Nil
    heap = Gcry.default_heap
    @@marks.add(1)
    if Gcry::MonitorGate.enabled? && !Gcry::MonitorGate.closed_for_external_stop_spec?
      @@gate_open.add(1)
    end
    owner = heap.@stw_owner
    unless owner && owner.same?(Thread.current) && heap.@stw_owner_pthread == Gcry::Platform.current_thread_id
      @@foreign_owner.add(1)
    end
  end

  def self.marks : Int32
    @@marks.get
  end

  def self.gate_open : Int32
    @@gate_open.get
  end

  def self.foreign_owner : Int32
    @@foreign_owner.get
  end
end

private def external_stop_fill(object : Void*) : Nil
  words = object.as(UInt64*)
  EXTERNAL_STOP_WORDS.times { |i| words[i] = object.address ^ EXTERNAL_STOP_MASK ^ i.to_u64 }
end

private def external_stop_intact?(object : Void*) : Bool
  words = object.as(UInt64*)
  EXTERNAL_STOP_WORDS.times do |i|
    return false unless words[i] == object.address ^ EXTERNAL_STOP_MASK ^ i.to_u64
  end
  true
end

describe "Regression: an external stop takes the locks a collection takes" do
  # In a process of its own: before the fix the race corrupted the root list,
  # and a crash or a hang there would take the whole suite down.
  it "excludes collections and root edits for the whole stop" do
    captured = IO::Memory.new
    child = Process.new(Process.executable_path.not_nil!, ["-e", "external-stop child"],
      env: {"GCRY_EXTERNAL_STOP_CHILD" => "1"}, output: captured, error: captured)
    exited = Channel(Process::Status).new(1)
    spawn { exited.send(child.wait) }
    select
    when status = exited.receive
      fail captured.to_s unless status.success?
    when timeout(EXTERNAL_STOP_CHILD_LIMIT_S.seconds)
      child.terminate(graceful: false)
      exited.receive
      fail "the child hung for #{EXTERNAL_STOP_CHILD_LIMIT_S} s:\n#{captured}"
    end
    captured.to_s.should contain("1 examples, 0 failures")
  end

  # The run, by the example above in a fresh process; a no-op anywhere else.
  it "external-stop child" do
    next unless ENV["GCRY_EXTERNAL_STOP_CHILD"]? == "1"
    heap = Gcry.default_heap
    heap.collection_event_hook = ->(event : Gcry::Heap::CollectionEvent) do
      ExternalStopCounters.mark_start if event.mark_start?
      nil
    end

    done = Atomic(Int32).new(0)
    stops = Atomic(Int32).new(0)
    births = Atomic(Int32).new(0)
    roots_cycled = Atomic(Int32).new(0)
    lost = Atomic(Int32).new(0)
    broken = Atomic(Int32).new(0)
    workers = [] of Thread

    2.times do
      workers << Thread.new do
        until done.get != 0
          GC.collect
        end
      end
    end
    workers << Thread.new do
      until done.get != 0
        GC.stop_world
        GC.start_world
        stops.add(1)
      end
    end
    # Joined threads are what the stop's birth-root release has to drop.
    workers << Thread.new do
      batch = Array(Thread).new(EXTERNAL_STOP_CHURN)
      until done.get != 0
        EXTERNAL_STOP_CHURN.times { batch << Thread.new { } }
        batch.each(&.join)
        births.add(batch.size)
        batch.clear
      end
    end
    rings = Array(UInt64*).new(2)
    2.times do
      ring = LibC.malloc(EXTERNAL_STOP_RING * sizeof(UInt64)).as(UInt64*)
      ring.clear(EXTERNAL_STOP_RING)
      rings << ring
      workers << Thread.new do
        i = 0
        until done.get != 0
          object = GC.malloc(EXTERNAL_STOP_WORDS * sizeof(UInt64))
          external_stop_fill(object)
          heap.add_root(object)
          if (old = ring[i]) != 0
            previous = Pointer(Void).new(old ^ EXTERNAL_STOP_MASK)
            broken.add(1) unless external_stop_intact?(previous)
            lost.add(1) unless heap.delete_root(previous)
            roots_cycled.add(1)
          end
          ring[i] = object.address ^ EXTERNAL_STOP_MASK
          i = (i + 1) % EXTERNAL_STOP_RING
        end
      end
    end

    sleep EXTERNAL_STOP_RUN_MS.milliseconds
    done.set(1)
    workers.each(&.join)
    heap.collection_event_hook = nil

    # One more collection with the stress over: every root still registered
    # must have kept its object through it, and must still be in the list.
    GC.collect
    rings.each do |ring|
      EXTERNAL_STOP_RING.times do |i|
        next if (word = ring[i]) == 0
        object = Pointer(Void).new(word ^ EXTERNAL_STOP_MASK)
        broken.add(1) unless external_stop_intact?(object)
        lost.add(1) unless heap.delete_root(object)
      end
      LibC.free(ring.as(Void*))
    end

    summary = "marks=#{ExternalStopCounters.marks} gate_open=#{ExternalStopCounters.gate_open} " \
              "foreign_owner=#{ExternalStopCounters.foreign_owner} stops=#{stops.get} births=#{births.get} " \
              "roots_cycled=#{roots_cycled.get} lost=#{lost.get} broken=#{broken.get}"
    # Enough of each for the run to have been the race it is meant to be.
    fail "too little overlap: #{summary}" if ExternalStopCounters.marks < 10 || stops.get < 10 ||
                                             births.get < EXTERNAL_STOP_CHURN || roots_cycled.get < EXTERNAL_STOP_RING
    {ExternalStopCounters.gate_open, ExternalStopCounters.foreign_owner, lost.get, broken.get}.should eq({0, 0, 0, 0}), summary
  end

  # The stopping thread may still switch fibers between the two calls: the
  # execution context takes `GC.lock_read` around every switch, and the stop
  # holds that lock's write side. With nothing to tell it apart the first
  # `sleep` spun on its own lock for good; Boehm, which does not take
  # Crystal's lock there, and master let it through. In a child, because a
  # red run hangs.
  it "lets the stopping thread switch fibers inside the stop" do
    captured = IO::Memory.new
    child = Process.new(Process.executable_path.not_nil!, ["-e", "external-stop switch child"],
      env: {"GCRY_EXTERNAL_STOP_SWITCH_CHILD" => "1"}, output: captured, error: captured)
    exited = Channel(Process::Status).new(1)
    spawn { exited.send(child.wait) }
    select
    when status = exited.receive
      fail captured.to_s unless status.success?
    when timeout(20.seconds)
      child.terminate(graceful: false)
      exited.receive
      fail "the child hung on a fiber switch inside GC.stop_world:\n#{captured}"
    end
    captured.to_s.should contain("1 examples, 0 failures")
  end

  # A fiber may not start or end inside the stop — that touches the fiber
  # list the stop holds — so only switches: a `sleep` and a yield.
  it "external-stop switch child" do
    next unless ENV["GCRY_EXTERNAL_STOP_SWITCH_CHILD"]? == "1"
    started = Time.instant
    GC.stop_world
    begin
      sleep 1.millisecond
      Fiber.yield
    ensure
      GC.start_world
    end
    (Time.instant - started).should be >= 1.millisecond
    GC.collect
  end
end
