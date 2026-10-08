require "../../src/gcry"
require "spec"

# An idle mark helper waits on the heap's `@mark_wake` word, and the events
# that give it work — a cycle's start, a flush worth a pop, a cycle's end —
# wake it. Until 2026-10-08 that was Linux only: on macOS and Windows the
# wait was a `nanosleep` of its 100 µs–5 ms timeout that nothing cut short
# (`Sleep` of whole milliseconds on Windows, 15.6 ms at the default timer
# resolution), and the master never parked there. Parallel mark, on by
# default, was serial plus a poller: `make parallel-mark-process` stole
# 0.7–5.6 k per run on darwin x86_64 and Windows x86_64 and 0 on darwin
# arm64, against 165–369 k on Linux (CI, 2026-10-06).
#
# `parallel_mark_wakes` counts the waits a wake ended before their timeout.
# Helpers park inside every one of these marks — 64 chains give three of the
# four workers nothing to take for most of it — and between them, and each
# cycle's start and end wakes all of them, so a build whose waits only ever
# time out leaves it at 0.
class ParkedWakeNode
  property succ : ParkedWakeNode?
  property payload = 0_i64

  def initialize
  end
end

PARKED_WAKE_CHAINS =    64
PARKED_WAKE_PER    = 2_000

# Built in a frame that has returned, as in `33_idle_mark_helpers_park_spec`.
@[NoInline]
def parked_wake_build(holder : Array(ParkedWakeNode)) : Nil
  PARKED_WAKE_CHAINS.times do
    head = ParkedWakeNode.new
    cur = head
    (PARKED_WAKE_PER - 1).times do
      n = ParkedWakeNode.new
      cur.succ = n
      cur = n
    end
    holder << head
  end
end

@[NoInline]
def parked_wake_count(holder : Array(ParkedWakeNode)) : Int32
  count = 0
  holder.each do |head|
    node = head.as(ParkedWakeNode?)
    while n = node
      count += 1
      node = n.succ
    end
  end
  count
end

describe "Regression: parked mark helpers" do
  # In a process of its own, like `33_idle_mark_helpers_park_spec`: the
  # helpers start with the four-worker setting, and nothing else in the
  # suite is marking around them.
  it "are woken, not left to time out" do
    captured = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!, ["-e", "parked-markers-woken child"],
      env: {"GCRY_PARKED_WAKE_CHILD" => "1"}, output: captured, error: captured)
    fail captured.to_s unless status.success?
    captured.to_s.should contain("1 examples, 0 failures")
  end

  # The measurement, run by the example above in a fresh process; a no-op
  # anywhere else.
  it "parked-markers-woken child" do
    next unless ENV["GCRY_PARKED_WAKE_CHILD"]? == "1"
    heap = Gcry.default_heap
    saved_workers = heap.parallel_mark_workers
    saved_min_live = heap.parallel_mark_min_live
    holder = [] of ParkedWakeNode
    parked_wake_build(holder)

    runs = 0_u64
    wakes = 0_u64
    begin
      heap.parallel_mark_workers = 4
      heap.parallel_mark_min_live = 0_u64
      runs0 = heap.parallel_mark_runs
      wakes0 = heap.parallel_mark_wakes
      4.times { GC.collect }
      runs = heap.parallel_mark_runs - runs0
      wakes = heap.parallel_mark_wakes - wakes0
    ensure
      heap.parallel_mark_workers = saved_workers
      heap.parallel_mark_min_live = saved_min_live
    end

    parked_wake_count(holder).should eq(PARKED_WAKE_CHAINS * PARKED_WAKE_PER)
    # Four parallel marks, or there was nothing to wake.
    runs.should eq(4_u64)
    if wakes == 0
      fail "4 parallel marks with 4 workers: no wait on @mark_wake ended before its timeout"
    end
  end
end
