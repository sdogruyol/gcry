# Does `GCRY_IDLE_RELEASE_MS` give memory back at idle, from its own thread,
# without harming the program it runs beside?
#
# The idle collector (src/gcry/idle_release.cr) is a Crystal thread that runs a
# releasing collection once the process has stopped allocating. It collects
# while the mutator may wake at any moment, from a thread that is not the
# mutator, and it must not run finalizers there. So:
#
#   burst    replace a slice of a checksummed live set, churn garbage — some of
#            it with finalizers — so ordinary collections run
#   gap      sleep 1x-2x the idle time: long enough for the idle collection to
#            fire, short enough that the mutator often wakes while it runs
#   verify   every word of every live object
#
# PASS needs all of:
#   * no live object reads back wrong;
#   * idle collections actually happened (`idle_collections > 0`), and the last
#     one released every empty chunk it found — `fully_free - released -
#     dormant == 0`, which only a releasing collection gives;
#   * finalizers ran as promptly as without it, and none on the idle thread;
#   * nothing collects at idle while `GC.disable` is in force.
#
# The red arm is the same binary without the knob: nothing collects at idle,
# the empty chunks stay mapped, and the run must fail.
#
#   crystal build -Dgc_none bench/idle_release.cr -o bin/idle_release
#   GCRY_IDLE_RELEASE_MS=50 bin/idle_release     # PASS
#   bin/idle_release                             # FAIL

require "../src/gcry"

WORDS = 14 # 112-byte payload: a small size class with several blocks a page

class Checked
  @words = StaticArray(UInt64, WORDS).new(0_u64)

  def initialize(@id : UInt64)
    WORDS.times { |i| @words[i] = Checked.expect(@id, i) }
  end

  def self.expect(id : UInt64, i : Int32) : UInt64
    (id &* 0x9E3779B97F4A7C15_u64) ^ (i.to_u64 &* 0xBF58476D1CE4E5B9_u64) | 1_u64
  end

  def bad_word : Int32
    WORDS.times { |i| return i if @words[i] != Checked.expect(@id, i) }
    -1
  end

  getter id
end

# Counts only: a finalizer must not allocate.
module FinLog
  @@ran = Atomic(Int64).new(0_i64)
  @@on_idle = Atomic(Int64).new(0_i64)

  def self.record : Nil
    @@ran.add(1_i64)
    if t = Thread.current?
      @@on_idle.add(1_i64) if Gcry::IdleRelease.thread?(t)
    end
  end

  def self.ran : Int64
    @@ran.get
  end

  def self.on_idle : Int64
    @@on_idle.get
  end
end

class Finalized
  @pad = StaticArray(UInt64, 6).new(0_u64)

  def finalize
    FinLog.record
  end
end

idle_ms = (ENV["GCRY_IDLE_RELEASE_MS"]? || "50").to_i
rounds = (ENV["ROUNDS"]? || "40").to_i
live_n = 20_000
heap = Gcry.default_heap

live = Array(Checked).new(live_n) { |i| Checked.new(i.to_u64) }
next_id = live_n.to_u64
rng = Random.new(42)
corrupt = 0
# The first bad read, as integers: a String built here lives on the heap under
# test, and a broken collector would corrupt the message reporting it.
first_round = -1
first_id = 0_u64
first_word = 0

rounds.times do |round|
  (live_n // 10).times do
    live[rng.rand(live_n)] = Checked.new(next_id)
    next_id += 1
  end
  sink = nil.as(Checked?)
  60_000.times { sink = Checked.new(0_u64) }
  fsink = nil.as(Finalized?)
  200.times { fsink = Finalized.new }

  # The last gap is long enough that the idle collection certainly runs, so
  # the release check below reads a heap it has just swept.
  gap = round == rounds - 1 ? idle_ms * 4 : idle_ms * (100 + rng.rand(101)) // 100
  sleep gap.milliseconds

  live.each do |obj|
    w = obj.bad_word
    next if w < 0
    corrupt += 1
    if first_round < 0
      first_round = round
      first_id = obj.id
      first_word = w
    end
  end
end

# `GC.disable` must hold off the idle collector: no collection the program did
# not ask for. The check sits under the post-STW lock, because the one made
# before asking for it can be stale by the length of the program's own cycles.
disabled_idle = 0_u64
if heap.idle_collections > 0
  GC.disable
  i0 = heap.idle_collections
  sink2 = nil.as(Checked?)
  1000.times { sink2 = Checked.new(0_u64) }
  sleep (idle_ms * 4).milliseconds
  disabled_idle = heap.idle_collections - i0
  GC.enable
end

kept_empty = heap.fully_free_chunk_bytes.to_i64 - heap.released_chunk_bytes.to_i64 -
             heap.dormant_chunk_bytes.to_i64
idle = heap.idle_collections
fin_ran = FinLog.ran
fin_idle = FinLog.on_idle

puts "idle release: #{rounds} bursts, gaps of 1-2 x #{idle_ms} ms, #{live_n} checksummed live objects"
puts "  idle collections #{idle} of #{heap.collections}"
puts "  empty chunks left mapped by the last collection #{kept_empty}"
puts "  finalizers run #{fin_ran}, on the idle thread #{fin_idle}"
puts "  idle collections while GC.disable'd: #{disabled_idle}"
fail = false
if corrupt > 0
  puts "FAIL: #{corrupt} bad reads of live objects; first in round #{first_round}: id #{first_id} word #{first_word}"
  fail = true
end
if idle == 0
  puts "FAIL: no collection ran at idle"
  fail = true
elsif kept_empty != 0
  puts "FAIL: the last collection kept #{kept_empty} bytes of empty chunks mapped — it did not release"
  fail = true
end
# Every burst makes 200 finalizable objects. The last two bursts' may still be
# queued at exit; anything more is the idle collector holding them back. The
# first version deferred them to the next *ordinary* collection, and idle
# collections made those rare: 2 999 of 8 000 had run, against 7 799 off.
fin_due = (rounds - 2).to_i64 * 200
if fin_ran < fin_due
  puts "FAIL: #{fin_ran} finalizers ran, #{fin_due} were due — the idle collector is holding them back"
  fail = true
end
if disabled_idle != 0
  puts "FAIL: #{disabled_idle} idle collections ran while GC was disabled"
  fail = true
end
if fin_idle != 0
  puts "FAIL: #{fin_idle} finalizers ran on the idle thread, which has no scheduler"
  fail = true
end
exit 1 if fail
puts "PASS: idle collections released memory, every live object read back intact, finalizers stayed on mutators"
