# A mutator frozen while holding `@index_lock` stalls the sweep forever. Does
# anything say so?
#
# `ROADMAP.md` has carried the shape without a reproducer: `chunk_containing`
# holds that spinlock for the length of a lookup, a suspend signal arrives
# wherever it likes, and the collector's own `index_insert` / `index_remove`
# take the same lock unconditionally — so a thread frozen holding it leaves the
# collector spinning with the world stopped, and nothing is resumed until the
# phase that is spinning finishes. It was left open because the fix is not small
# (the collector cannot take the unlocked path: a mutator frozen mid-insert
# leaves the array half-updated) and because nothing had been seen to hit it.
#
# The fix is still not small. What this closes is the other half: a process that
# wedges here used to print `STALLED ... in phase=sweep` and no more, which does
# not name the lock, and a reader who does not already suspect `@index_lock` has
# nowhere to go. Now the watchdog names it.
#
#   bin/index_lock_wedge            # a mutator holds the lock across a stop
#   bin/index_lock_wedge --control  # nobody holds it; the report must stay silent
#
# The wedge arm is expected to hang: that is the defect. The parent gives the
# child a deadline, kills it, and reads what it printed — which is the whole
# question.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "index_lock_wedge requires -Dgc_none (gcry as process GC)" %}
{% end %}

HOLD_MS     = (ENV["WEDGE_HOLD_MS"]?.try(&.to_u64?) || 30_000_u64)
WATCHDOG_MS = (ENV["WEDGE_WATCHDOG_MS"]?.try(&.to_u64?) || 1_000_u64)
CHILD_WAIT  = (ENV["WEDGE_CHILD_WAIT"]?.try(&.to_i?) || 12)

def run_child(control : Bool) : NoReturn
  heap = Gcry.default_heap.not_nil!
  # Give the sweep chunks to remove from the index: a live set that dies is what
  # makes `index_remove` run at all.
  garbage = [] of Array(UInt8)
  4096.times { garbage << Array(UInt8).new(8 * 1024, 1_u8) }
  garbage.clear
  GC.collect

  # Printed *before* the holder starts, because the hold arm is expected to
  # wedge and a killed child never reaches its final print. Whether any section
  # runs with the world stopped is a property of the collector, not of this
  # particular collection, so an early reading answers it.
  puts "sections=#{heap.index_lock_sections} in_stw=#{heap.index_lock_sections_in_stw}"
  STDOUT.flush

  unless control
    # A mutator holding `@index_lock`. The stop's suspend signal lands on this
    # thread while it holds the lock — which is the whole shape — and then the
    # collector's index surgery spins on it with the world stopped.
    Thread.new do
      heap.debug_hold_index_lock(HOLD_MS)
    end
    sleep 50.milliseconds
  end

  more = [] of Array(UInt8)
  4096.times { more << Array(UInt8).new(8 * 1024, 2_u8) }
  more.clear
  GC.collect
  # The number that decides whether the wedge is reachable at all: an index-lock
  # section entered with the world stopped is the only one a frozen holder can
  # block, because with the world running the holder keeps running and the cost
  # is a stall bounded by its own work.
  puts "sections=#{heap.index_lock_sections} in_stw=#{heap.index_lock_sections_in_stw}"
  STDOUT.flush
  puts "finished"
  exit 0
end

# The third arm, and the one that decides the item: a program with no mutator
# but the main thread. `sweep_after_world?` reads the mutator count, so alone
# the sweep runs *inside* the stop — which is where an index-lock section can be
# blocked by a frozen holder. The question is whether that configuration and a
# second mutator can coexist.
if ARGV.includes?("--child-single")
  heap = Gcry.default_heap.not_nil!
  garbage = [] of Array(UInt8)
  4096.times { garbage << Array(UInt8).new(8 * 1024, 1_u8) }
  garbage.clear
  GC.collect
  more = [] of Array(UInt8)
  4096.times { more << Array(UInt8).new(8 * 1024, 2_u8) }
  more.clear
  GC.collect
  puts "sections=#{heap.index_lock_sections} in_stw=#{heap.index_lock_sections_in_stw}"
  exit 0
end

ARGV.each do |arg|
  run_child(arg == "--child-control") if arg.starts_with?("--child")
end

control = ARGV.includes?("--control")
exe = Process.executable_path.not_nil!
puts "=== a mutator frozen holding @index_lock ==="
puts "mode: #{control ? "control (nobody holds the lock)" : "hold (#{HOLD_MS} ms)"}"
puts ""

# The single-mutator reading first, because it is what makes the other number
# mean something: if no section ever runs in the stop, a frozen holder cannot
# wedge anything, and if sections do run in the stop only when this process is
# alone, then the wedge needs two things that exclude each other.
single = IO::Memory.new
Process.run(exe, ["--child-single"], output: single, error: single)
single_line = single.to_s.lines.select(&.starts_with?("sections=")).last?
single_in_stw = single_line.try(&.split("in_stw=").last.to_u64?) || 0_u64
single_sections = single_line.try(&.split(' ').first.split('=').last.to_u64?) || 0_u64
puts "alone (no second mutator): #{single_sections} sections, #{single_in_stw} with the world stopped"
puts ""

# And whether a holder costs a deadlock or a wait: with a short hold the child
# must finish. A collector blocked on a lock whose owner is *running* resolves
# when the owner lets go; one blocked on a frozen owner never does.
short = IO::Memory.new
short_child = Process.new(exe, ["--child"],
  env: {"GCRY_STW_WATCHDOG_MS" => WATCHDOG_MS.to_s, "WEDGE_HOLD_MS" => "1500"},
  output: short, error: short)
short_deadline = Time.instant + 20.seconds
short_finished = false
while Time.instant < short_deadline
  if short_child.terminated?
    short_child.wait
    short_finished = true
    break
  end
  sleep 100.milliseconds
end
unless short_finished
  short_child.signal(Signal::KILL)
  short_child.wait
end
puts "a 1.5 s hold: the child #{short_finished ? "finished" : "did NOT finish"}"
puts ""

captured = IO::Memory.new
child = Process.new(exe, [control ? "--child-control" : "--child"],
  env: {"GCRY_STW_WATCHDOG_MS" => WATCHDOG_MS.to_s},
  output: captured, error: captured)
deadline = Time.instant + CHILD_WAIT.seconds
finished = false
while Time.instant < deadline
  if status = child.terminated? ? child.wait : nil
    finished = true
    break
  end
  sleep 100.milliseconds
end
unless finished
  # Expected on the hold arm: the collector is spinning on a lock a frozen
  # thread owns, and nothing will resume that thread.
  child.signal(Signal::KILL)
  child.wait
end
text = captured.to_s

stalled = text.includes?("STOP-THE-WORLD STALLED")
named = text.includes?("taking @index_lock for chunk 0x")
counts = text.lines.select(&.starts_with?("sections=")).last?
in_stw = counts.try(&.split("in_stw=").last.to_u64?) || 0_u64
sections = counts.try(&.split(' ').first.split('=').last.to_u64?) || 0_u64
puts "child #{finished ? "finished" : "had to be killed"}"
puts "index-lock sections: #{sections}, of them with the world stopped: #{in_stw}"
puts "watchdog fired: #{stalled}"
puts "named the lock: #{named}"
puts ""

if control
  if stalled
    puts "FAIL the control wedged too, so the hold arm proves nothing about the lock. What it"
    puts "said:\n#{text.lines.select(&.includes?("gcry:")).first(4).join("\n")}"
    exit 1
  end
  puts "ok — nobody held the lock, the collection finished and the watchdog stayed silent,"
  puts "so the other arm's report is attributable to the held lock."
  exit 0
end

if !stalled
  # Not a failure by itself, and the counts say which of the two it is.
  if in_stw == 0
    puts "ok — the wedge did not reproduce, and the two numbers say why rather than leaving it"
    puts "to luck. With a second mutator holding the lock: #{sections} index-lock sections, #{in_stw} of them"
    puts "with the world stopped. Alone: #{single_sections} sections, #{single_in_stw} with the world stopped."
    puts ""
    if single_in_stw > 0
      puts "So the wedge needs two things that exclude each other. An index-lock section can"
      puts "only be blocked by a frozen holder if it runs *inside* the stop, and the sweep runs"
      puts "inside the stop only when this process has one mutator — `sweep_after_world?` reads"
      puts "the mutator count. A second mutator is exactly what a frozen holder requires. That"
      puts "is why nothing has been seen to hit this, and it is a property to re-measure rather"
      puts "than a proof: anything that moves index surgery into the stop under multiple"
      puts "mutators reopens it, and this harness is what notices."
    else
      puts "And no section runs inside the stop in either configuration, so on this tree the"
      puts "collector never holds up a frozen mutator's lock at all: it waits for a holder that"
      puts "is still running, which resolves when the holder lets go."
    end
    unless short_finished
      puts ""
      puts "FAIL but a 1.5 s hold did not finish either, so the wait is not bounded by the"
      puts "holder after all — the numbers above say the section was not in the stop, which"
      puts "makes an unbounded wait a third thing again and worth chasing."
      exit 1
    end
    exit 0
  end
  puts "FAIL #{in_stw} index-lock section(s) ran with the world stopped and a mutator held the"
  puts "lock across it, yet no stall was reported in #{CHILD_WAIT} s. The wedge is reachable and"
  puts "the watchdog did not see it, which is the worst of the three outcomes."
  exit 1
end
unless named
  puts "FAIL the watchdog fired but did not name the lock, which is the half this harness"
  puts "exists for: `phase=sweep` alone sends a reader looking everywhere. What it said:"
  puts text.lines.select(&.includes?("gcry:")).first(4).join("\n")
  exit 1
end
puts "ok — the wedge reproduces and the report names it: the phase, the lock, and the chunk"
puts "the collector was in that section for. The wedge itself is still open — a mutator"
puts "frozen mid-`index_insert` leaves the array half-updated, so the collector cannot"
puts "simply take the unlocked path — but it is no longer a silent hang."
exit 0
