# Does `GCRY_IDLE_RELEASE_MS` give memory back without taking live data with it?
#
# The releaser (src/gcry/idle_release.cr) turns empty, cursor-free bitmap chunks
# dormant and `MADV_DONTNEED`s them from its own thread while the mutator may
# wake up at any moment. A mistake there does not crash; it zeroes objects. So
# this keeps a set of long-lived objects whose every word is a function of the
# object's identity, and checks all of them after every idle gap:
#
#   burst    replace a slice of the live set, churn garbage so collections run
#            and leave warm chunks behind
#   gap      sleep 1x-2x the idle time — long enough for the release to fire,
#            and short enough that the next burst often starts while it walks,
#            so a revive can race the flush (measured: it rarely does — the
#            flush takes milliseconds — and the refusal counter is printed so
#            the run says whether it did)
#   verify   every word of every live object
#
# PASS needs no corruption *and* a release that actually happened
# (`idle_release_bytes > 0`) — a gate whose mechanism never engaged proves
# nothing. The red arm is `GCRY_IDLE_RELEASE_UNCHECKED=1`, which skips the
# emptiness test and so releases the retired chunks the live set sits in; the
# verify pass must see the zeroes.
#
#   crystal build -Dgc_none bench/idle_release.cr -o bin/idle_release
#   GCRY_IDLE_RELEASE_MS=50 bin/idle_release                                  # PASS
#   GCRY_IDLE_RELEASE_MS=50 GCRY_IDLE_RELEASE_UNCHECKED=1 bin/idle_release    # FAIL

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

  # First bad word, or -1.
  def bad_word : Int32
    WORDS.times { |i| return i if @words[i] != Checked.expect(@id, i) }
    -1
  end

  getter id
end

idle_ms = (ENV["GCRY_IDLE_RELEASE_MS"]? || "0").to_i
if idle_ms <= 0
  STDERR.puts "set GCRY_IDLE_RELEASE_MS (e.g. 50): this harness exercises the idle releaser"
  exit 2
end
rounds = (ENV["ROUNDS"]? || "40").to_i
live_n = 20_000
heap = Gcry.default_heap

live = Array(Checked).new(live_n) { |i| Checked.new(i.to_u64) }
next_id = live_n.to_u64
rng = Random.new(42)
corrupt = 0
# The first bad read, as integers: a String built here would live on the heap
# under test, and the red arm zeroed the very message reporting it.
first_round = -1
first_id = 0_u64
first_word = 0
first_value = 0_u64

rounds.times do |round|
  # Burst: replace a slice of the live set, then churn garbage.
  (live_n // 10).times do
    live[rng.rand(live_n)] = Checked.new(next_id)
    next_id += 1
  end
  sink = nil.as(Checked?)
  60_000.times { sink = Checked.new(0_u64) }

  # Gap: 1x-2x the idle time.
  sleep (idle_ms * (100 + rng.rand(101)) // 100).milliseconds

  live.each do |obj|
    w = obj.bad_word
    next if w < 0
    corrupt += 1
    if first_round < 0
      first_round = round
      first_id = obj.id
      first_word = w
      first_value = obj.@words[w]
    end
  end
end

puts "idle release: #{rounds} bursts, gaps of 1-2 x #{idle_ms} ms, #{live_n} checksummed live objects"
puts "  passes #{heap.idle_releases}  chunks released #{heap.idle_release_chunks}  bytes #{heap.idle_release_bytes}"
puts "  dormant revives #{heap.bitmap_dormant_revives}  revives refused mid-flush #{heap.dormant_revive_during_flush}"
if corrupt > 0
  puts "FAIL: #{corrupt} bad reads of live objects; first in round #{first_round}: " \
       "id #{first_id} word #{first_word} = 0x#{first_value.to_s(16)}"
  exit 1
end
if heap.idle_release_bytes == 0
  puts "FAIL: the releaser never released anything, so this run tested nothing"
  exit 1
end
puts "PASS: memory went back at idle and every live object read back intact"
