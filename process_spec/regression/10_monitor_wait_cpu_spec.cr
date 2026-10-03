require "../../src/gcry"
require "spec"

# The runtime's Monitor thread is never signal-suspended; it waits a stop out
# in `MonitorGate.enter`, and it reaches that wait in nearly every stop longer
# than its ~10 ms period. The wait spun on `pause` for the whole stop, so every
# collection's pause also burned a second core: a third of crystal-metric
# Primes' CPU (user 4.1 s on 2.7 s wall, 2.55 s after the fix). The pause runs
# one thread here (no parallel mark), so the process's CPU time across a run
# of long collections is about their wall time, and was about twice that.
class MonitorWaitNode
  property next_node : MonitorWaitNode?
  property payload = 0_i64

  def initialize(@next_node)
  end
end

# The list is built and walked in frames that have returned before the spec
# drops it, and its head lives only in `holder`'s buffer, so no stack slot of
# the example still names it afterwards. Left reachable, it is freed under a
# later example instead: `1_live_objects_dormant_spec` read a drift of −73 336.
@[NoInline]
def monitor_wait_build(holder : Array(MonitorWaitNode?), count : Int32) : Nil
  head = nil.as(MonitorWaitNode?)
  count.times { head = MonitorWaitNode.new(head) }
  holder << head
end

@[NoInline]
def monitor_wait_length(holder : Array(MonitorWaitNode?)) : Int32
  length = 0
  node = holder[0]
  while node
    length += 1
    node = node.next_node
  end
  length
end

describe "the Monitor's wait for a stopped world" do
  it "does not burn a core for the length of the pause" do
    holder = [] of MonitorWaitNode?
    monitor_wait_build(holder, 1_500_000)

    GC.collect
    cpu0 = Process.times
    t0 = Time.instant
    collections = 0
    while (Time.instant - t0).total_milliseconds < 1_500
      GC.collect
      collections += 1
    end
    wall = (Time.instant - t0).total_seconds
    cpu1 = Process.times
    cpu = (cpu1.utime - cpu0.utime) + (cpu1.stime - cpu0.stime)

    # The walk keeps the list live through the loop in a release build too,
    # where LLVM otherwise drops it and every pause is a few µs. Pauses shorter
    # than the Monitor's period never meet it, and the check would pass
    # vacuously.
    length = monitor_wait_length(holder)
    holder.clear
    GC.collect

    length.should eq(1_500_000)
    collections.should be > 3
    collections.should be < 100
    ratio = cpu / wall
    if ratio >= 1.4
      fail "process CPU #{cpu.round(3)} s over #{wall.round(3)} s of back-to-back collections (#{collections}): ratio #{ratio.round(2)}"
    end
  end
end
