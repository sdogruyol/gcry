require "../../src/gcry"
require "spec"

# Parallel mark is the process default above 32 MiB live, and one long linked
# list gives its helpers nothing to take: the worker that pops the head keeps
# each node's one child to itself. They polled the empty shared stack for the
# whole mark anyway, a core each. Four workers on a 3 M-node list used 4.0
# cores of CPU per second of back-to-back collections against 1.05 serial
# (`bench/mark_list_heap.cr`). An idle helper now parks after a bounded spin,
# and so does an idle master, until work is published or the mark ends.
class IdleMarkNode
  property next_node : IdleMarkNode?
  property payload = 0_i64

  def initialize(@next_node)
  end
end

# Built in a frame that has returned, with the head only in `holder`'s buffer,
# so nothing on the example's stack names the list once it is dropped (see
# `10_monitor_wait_cpu_spec`).
@[NoInline]
def idle_mark_build(holder : Array(IdleMarkNode?), count : Int32) : Nil
  head = nil.as(IdleMarkNode?)
  count.times { head = IdleMarkNode.new(head) }
  holder << head
end

@[NoInline]
def idle_mark_length(holder : Array(IdleMarkNode?)) : Int32
  length = 0
  node = holder[0]
  while node
    length += 1
    node = node.next_node
  end
  length
end

describe "parallel mark on a heap with nothing to divide" do
  # In a process of its own. Inside the suite the rest of process_spec's live
  # data gives the helpers real work, and the ratio measured that instead:
  # 2.4–3.0 with the fix, against 1.1 alone.
  it "does not spend a core on each idle helper" do
    captured = IO::Memory.new
    status = Process.run(Process.executable_path.not_nil!, ["-e", "idle-mark-helpers child"],
      env: {"GCRY_IDLE_MARK_CHILD" => "1"}, output: captured, error: captured)
    fail captured.to_s unless status.success?
    captured.to_s.should contain("1 examples, 0 failures")
  end

  # The measurement, run by the example above in a fresh process; a no-op
  # anywhere else.
  it "idle-mark-helpers child" do
    next unless ENV["GCRY_IDLE_MARK_CHILD"]? == "1"
    heap = Gcry.default_heap
    saved_workers = heap.parallel_mark_workers
    saved_min_live = heap.parallel_mark_min_live
    holder = [] of IdleMarkNode?
    idle_mark_build(holder, 1_500_000)

    collections = 0
    runs = 0_u64
    cpu = 0.0
    wall = 0.0
    begin
      heap.parallel_mark_workers = 4
      heap.parallel_mark_min_live = 0_u64
      GC.collect
      runs0 = heap.parallel_mark_runs
      cpu0 = Process.times
      t0 = Time.instant
      # At least four pauses however slow the runner, as in
      # `10_monitor_wait_cpu_spec`.
      while collections < 4 || (Time.instant - t0).total_milliseconds < 1_500
        GC.collect
        collections += 1
      end
      wall = (Time.instant - t0).total_seconds
      cpu1 = Process.times
      cpu = (cpu1.utime - cpu0.utime) + (cpu1.stime - cpu0.stime)
      runs = heap.parallel_mark_runs - runs0
    ensure
      heap.parallel_mark_workers = saved_workers
      heap.parallel_mark_min_live = saved_min_live
    end

    # The walk keeps the list live through the loop in a release build too.
    length = idle_mark_length(holder)
    holder.clear
    GC.collect

    length.should eq(1_500_000)
    # Every one of them marked with four workers, or the ratio says nothing.
    runs.should eq(collections.to_u64)
    # The collecting thread is a core for the whole loop. Three helpers that
    # poll were three more; parked, they are a few spins per collection.
    # Until 2026-10-08 an idle master polled rather than parked off Linux,
    # where a park was a sleep nothing woke, and the bound there was 2.5: a
    # helper that took the list left the master spending a second core.
    ratio = cpu / wall
    bound = 1.6
    if ratio >= bound
      fail "process CPU #{cpu.round(3)} s over #{wall.round(3)} s of back-to-back collections " \
           "(#{collections}) of one list with 4 mark workers: ratio #{ratio.round(2)}, bound #{bound}"
    end
  end
end
