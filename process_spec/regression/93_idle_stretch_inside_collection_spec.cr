require "../../src/gcry"
require "spec"

# The idle thread runs one collection per idle stretch and re-arms when the
# allocation count moves (`IdleRelease.loop_forever`). Until 2026-11-01 it read
# the count again once its collection returned and took that as the baseline.
# An allocation that landed after the collection let the mutator go and before
# that read — the last of a burst the collection had interrupted — was then in
# the baseline: the stretch it began looked like the one just collected, and
# was never collected. The program kept its warm budget and its unswept
# garbage until it next allocated. `make idle-release` makes such overlaps on
# purpose (gaps of 1-2 x the idle time). Its macOS flake was something else —
# the gate reading before a late idle collection — and this window was found
# reading the loop for it (`bench/log/macos/2026-11-01-idle-release-flake/`).
# The baseline is now the count the idle decision was made on.
#
# The interleaving is forced: a collection event hook holds the idle thread
# at the `End` of its collection — after the world restarted, before the
# collection returns — until the main thread has made its last allocation.
# The main thread then sleeps through twenty idle times. The fixed loop runs
# exactly one more idle collection in that stretch; the control arm
# (`IdleRelease.baseline_after_collect`, the code before) runs none. Each arm
# in a process of its own: the idle thread is born once per process. Not
# under `-Dwithout_mt`, which has no idle thread.
{% skip_file if flag?(:without_mt) %}

private C93_IDLE_MS = 50

# Class state and a proc that captures nothing: the process heap lives in libc
# memory the collector does not scan, so a closure only it held would be swept.
private module IdleStretchHold
  @@armed = Atomic(Int32).new(0)
  @@held = Atomic(Int32).new(0)
  @@released = Atomic(Int32).new(0)

  # On the collecting thread, at every event of every collection; holds only
  # the idle thread's, once armed, and allocates nothing.
  def self.call(event : Gcry::Heap::CollectionEvent) : Nil
    return unless event.end?
    return unless @@armed.get == 1
    thread = Thread.current?
    return unless thread && Gcry::IdleRelease.thread?(thread)
    @@armed.set(0)
    @@held.set(1)
    deadline = Gcry::Clock.monotonic_ns &+ 10_000_000_000_u64
    while @@released.get == 0 && Gcry::Clock.monotonic_ns < deadline
      Intrinsics.pause
    end
  end

  def self.arm : Nil
    @@armed.set(1)
  end

  def self.held? : Bool
    @@held.get == 1
  end

  def self.release : Nil
    @@released.set(1)
  end
end

# Idle collections in the stretch that begins with an allocation made while
# an idle collection is held at its end, that held one included.
private def c93_idle_collections_across(heap : Gcry::Heap) : UInt64
  heap.collection_event_hook = ->(event : Gcry::Heap::CollectionEvent) { IdleStretchHold.call(event) }
  sink = nil.as(Array(Int32)?)
  # A collection starts the idle thread, and a burst gives it a stretch to end.
  GC.collect
  20_000.times { sink = Array(Int32).new(8, 0) }
  IdleStretchHold.arm
  deadline = Time.instant + 10.seconds
  until IdleStretchHold.held?
    fail "no idle collection reached its end" if Time.instant > deadline
    sleep 1.millisecond
  end
  # Not yet counted: `idle_collections` moves once the held one returns.
  before = heap.idle_collections
  # The stretch's last allocation, inside the idle collection.
  100.times { sink = Array(Int32).new(16, 0) }
  IdleStretchHold.release
  sleep (C93_IDLE_MS * 20).milliseconds
  heap.collection_event_hook = nil
  heap.idle_collections - before
end

describe "Regression: an idle stretch that begins inside an idle collection gets its own" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      env = {"GCRY_IDLE_STRETCH_CHILD" => arm, "GCRY_IDLE_RELEASE_MS" => C93_IDLE_MS.to_s} of String => String?
      status = Process.run(Process.executable_path.not_nil!, ["-e", "idle-stretch child #{arm}"],
        env: env, output: captured, error: captured)
      fail "child #{status.inspect}:\n#{captured}" unless status.success?
      if arm == "control"
        captured.to_s.should contain("idle93: control left the stretch uncollected")
      else
        captured.to_s.should contain("1 examples, 0 failures")
      end
    end
  end

  it "idle-stretch child fixed" do
    next unless ENV["GCRY_IDLE_STRETCH_CHILD"]? == "fixed"
    Gcry::IdleRelease.idle_ms.should eq(C93_IDLE_MS)
    # The held collection, then exactly one for the stretch: re-armed by the
    # allocation, and not by the collection's own work.
    c93_idle_collections_across(Gcry.default_heap).should eq(2)
  end

  it "idle-stretch child control" do
    next unless ENV["GCRY_IDLE_STRETCH_CHILD"]? == "control"
    Gcry::IdleRelease.idle_ms.should eq(C93_IDLE_MS)
    Gcry::IdleRelease.baseline_after_collect = true
    n = c93_idle_collections_across(Gcry.default_heap)
    # The held one only.
    n.should eq(1)
    STDOUT.puts "idle93: control left the stretch uncollected (idle collections #{n})"
    STDOUT.flush
  end
end
