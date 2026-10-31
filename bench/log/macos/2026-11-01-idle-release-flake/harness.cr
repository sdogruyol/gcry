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
# The red arm is the same binary with the collector off
# (`GCRY_IDLE_RELEASE_MS=0`; it is on by default at two minutes, far longer
# than this run): nothing collects at idle, the empty chunks stay mapped, and
# the run must fail.
#
#   crystal build -Dgc_none bench/idle_release.cr -o bin/idle_release
#   GCRY_IDLE_RELEASE_MS=50 bin/idle_release     # PASS
#   GCRY_IDLE_RELEASE_MS=0 bin/idle_release      # FAIL

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

# PROBE ONLY. Every collection event of the run, stamped, with the thread
# that reported it: [event, ns, main?] in a malloc'd buffer, written by a hook
# that runs inside the stop and so must not allocate.
module Diag
  CAP = 4096
  @@buf = Pointer(UInt64).null
  @@n = Pointer(Int64).null
  @@main_tid = 0_u64

  def self.setup : Nil
    @@buf = LibC.malloc(CAP * 3 * 8).as(UInt64*)
    @@n = LibC.malloc(8).as(Int64*)
    @@n.value = 0_i64
    @@main_tid = Gcry::Platform.current_thread_id
  end

  def self.note(e : Gcry::Heap::CollectionEvent) : Nil
    i = Atomic::Ops.atomicrmw(:add, @@n, 1_i64, :sequentially_consistent, false)
    return if i >= CAP
    @@buf[i * 3] = e.value.to_u64
    @@buf[i * 3 + 1] = Gcry::Clock.monotonic_ns
    @@buf[i * 3 + 2] = Gcry::Platform.current_thread_id == @@main_tid ? 1_u64 : 0_u64
  end

  # Events from *from_ns* on, as offsets in ms from *base_ns*.
  def self.dump(base_ns : UInt64, from_ns : UInt64) : Nil
    n = {@@n.value, CAP.to_i64}.min
    n.times do |i|
      ns = @@buf[i * 3 + 1]
      next if ns < from_ns
      ev = Gcry::Heap::CollectionEvent.new(@@buf[i * 3].to_i32)
      off = (ns.to_i64 - base_ns.to_i64) / 1_000_000.0
      who = @@buf[i * 3 + 2] == 1 ? "main" : "other"
      puts "  EV #{off.round(3)} ms #{ev} #{who}"
    end
  end

  # The first collection another thread started at or after *from_ns*: its
  # Start, ReclaimStart, ReclaimEnd and End, in ms from *from_ns* (-1: none).
  def self.other_collection(from_ns : UInt64) : {Float64, Float64, Float64, Float64}
    n = {@@n.value, CAP.to_i64}.min
    t = StaticArray(Float64, 4).new(-1.0)
    started = false
    n.times do |i|
      ns = @@buf[i * 3 + 1]
      next if ns < from_ns
      ev = Gcry::Heap::CollectionEvent.new(@@buf[i * 3].to_i32)
      off = (ns.to_i64 - from_ns.to_i64) / 1_000_000.0
      if !started
        next unless ev.start? && @@buf[i * 3 + 2] == 0
        started = true
        t[0] = off
      elsif @@buf[i * 3 + 2] == 0
        t[1] = off if ev.reclaim_start? && t[1] < 0
        t[2] = off if ev.reclaim_end? && t[2] < 0
        if ev.end?
          t[3] = off
          break
        end
      end
    end
    {t[0], t[1], t[2], t[3]}
  end

  # Read with no allocation (a tuple), formatted later: an allocation can
  # revive a dormant chunk and move the counters under the read.
  def self.snap(heap : Gcry::Heap)
    {heap.fully_free_chunk_bytes, heap.released_chunk_bytes, heap.dormant_chunk_bytes,
     heap.last_sweep_after_world, heap.last_sweep_multi, heap.last_sweep_release,
     heap.last_empty_warm_bytes, heap.last_empty_grace_bytes, heap.last_empty_unmap_bytes,
     heap.last_empty_kept_bytes, heap.last_empty_header_blocked_bytes, heap.sweep_dormant_skips,
     heap.stop_sweep_relinks_declined, heap.stop_sweep_dormant_declined,
     heap.collections, heap.idle_collections, heap.collecting?, Gcry::Clock.monotonic_ns}
  end

  def self.kept(s) : Int64
    s[0].to_i64 - s[1].to_i64 - s[2].to_i64
  end

  def self.fmt(s, base_ns : UInt64) : String
    "kept=#{kept(s)} fully_free=#{s[0]} released=#{s[1]} dormant=#{s[2]} after_world=#{s[3]} multi=#{s[4]} " \
    "release=#{s[5]} warm=#{s[6]} grace=#{s[7]} unmap=#{s[8]} kept_mapped=#{s[9]} hdr_blocked=#{s[10]} " \
    "dormant_skips=#{s[11]} relinks_declined=#{s[12]} dormant_declined=#{s[13]} collections=#{s[14]} " \
    "idle=#{s[15]} collecting=#{s[16]} at_ms=#{(s[17].to_i64 - base_ns.to_i64) / 1_000_000.0}"
  end

  # Walk the chunk list: the DORMANT bytes on it against the counter, and
  # every size-class chunk's flags. Only with no collection in flight.
  def self.chunks(heap : Gcry::Heap, per_chunk : Bool) : Nil
    if heap.collecting?
      puts "  CHUNKS not walked: a collection is in flight"
      return
    end
    n = 0
    dormant = 0_u64
    idle = 0
    heap.each_chunk do |c|
      n += 1
      dormant &+= c.value.mapped_bytes if Gcry::ChunkHeader.dormant?(c)
      idle += 1 if Gcry::ChunkHeader.idle?(c)
      if per_chunk
        puts "  CHUNK 0x#{c.address.to_s(16)} class=#{c.value.size_class.to_i64} mapped=#{c.value.mapped_bytes} flags=0x#{c.value.flags.to_s(16)}"
      end
    end
    puts "  CHUNKS n=#{n} dormant_walk=#{dormant} dormant_counter=#{heap.dormant_chunk_bytes} idle_flag=#{idle}"
  end
end

Diag.setup
Gcry.default_heap.collection_event_hook = ->(e : Gcry::Heap::CollectionEvent) { Diag.note(e); nil }
{% if Gcry::Heap.class.has_method?("shared_counters_atomic=") %}
  # PROBE ONLY: the 0.38 counter (recounted by every major sweep).
  Gcry::Heap.shared_counters_atomic = false if ENV["PROBE_RECOUNT"]? == "1"
{% end %}
puts "PROBE recount=#{ENV["PROBE_RECOUNT"]? == "1"}"

# The gaps are sized from the idle time the run asked for; the red arm sets
# `GCRY_IDLE_RELEASE_MS=0`, and its gaps stay those of a 50 ms run.
idle_ms = (ENV["GCRY_IDLE_RELEASE_MS"]? || "50").to_i
idle_ms = 50 if idle_ms <= 0
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
# PROBE: the last gap's start and wake, and what the counters said at each.
gap_start_ns = 0_u64
gap_c0 = 0_u64
gap_i0 = 0_u64
wake_ns = 0_u64
wake_c = 0_u64
wake_i = 0_u64
wake_collecting = false

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
  if round == rounds - 1
    gap_start_ns = Gcry::Clock.monotonic_ns
    gap_c0 = heap.collections
    gap_i0 = heap.idle_collections
  end
  sleep gap.milliseconds
  if round == rounds - 1
    wake_ns = Gcry::Clock.monotonic_ns
    wake_c = heap.collections
    wake_i = heap.idle_collections
    wake_collecting = heap.collecting?
  end

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

# What the last collection left, read before anything below allocates. On
# macOS an idle collection leaves empties dormant (released in place) rather
# than unmapped, and the `GC.disable` arm's allocations can revive one: the
# revival takes its bytes out of `dormant_chunk_bytes` (bitmap_alloc.cr,
# heap.cr) while the last sweep's `fully_free_chunk_bytes` still counts them.
# Read after those allocations, the sum came out as two chunks "kept" —
# 524 288 on macos-26-arm64, master run 38034037360 and again on this
# branch's run 38074816599 — with nothing wrong with the release.
snap = Diag.snap(heap)
kept_empty = Diag.kept(snap)
gs = gap_start_ns
puts "DIAG kept=#{kept_empty} gap_ms=#{idle_ms * 4} slept_ms=#{(wake_ns.to_i64 - gs.to_i64) / 1_000_000.0} " \
     "c0=#{gap_c0} i0=#{gap_i0} wake_c=#{wake_c} wake_i=#{wake_i} wake_collecting=#{wake_collecting}"
puts "DIAG read #{Diag.fmt(snap, gs)}"
og = Diag.other_collection(gs)
puts "IDLEGC start_ms=#{og[0].round(3)} reclaim_start_ms=#{og[1].round(3)} reclaim_end_ms=#{og[2].round(3)} end_ms=#{og[3].round(3)}"
if kept_empty != 0
  # Wait for the last gap's idle collection, if it had not finished, and read
  # again before anything allocates: a late collection reads 0 here, a
  # non-release does not.
  deadline = Gcry::Clock.monotonic_ns + 10_000_000_000_u64
  while (heap.idle_collections == gap_i0 || heap.collecting?) && Gcry::Clock.monotonic_ns < deadline
    sleep 5.milliseconds
  end
  again = Diag.snap(heap)
  puts "DIAG reread #{Diag.fmt(again, gs)}"
  # What ran around the last gap, from the burst before it on.
  Diag.dump(gs, gs - 2_000_000_000_u64)
  Diag.chunks(heap, true)
else
  Diag.chunks(heap, false)
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
# One more burst of slack: a conservative word can keep one finalizable
# object alive past its burst, and macos-latest ran 7 599 of the 7 600 the
# tighter bound required (2026-10-01). That defect is ~4 800 short.
fin_due = (rounds - 3).to_i64 * 200
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
