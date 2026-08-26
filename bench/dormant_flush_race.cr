# Can a post-STW flush walk step onto a chunk a mutator is unmapping?
#
# `flush_pending_dormant_chunks`, `flush_pending_page_release_chunks` and
# `flush_pending_mostly_empty_chunks` all run *after* `start_world`, with every
# mutator live, and all three walk `@chunks` holding nothing. The comment at
# the call site says they are "still under post-STW mutex" — but that mutex
# only serialises collectors against each other. No mutator ever takes it.
#
# A mutator does reach the chunk list from outside: `GC.free` of a large object
# calls `trim_large_cache`, which unlinks chunks and `munmap`s them. (Crystal's
# own GMP binding installs `GC.free` as libgmp's free hook, so any program that
# touches BigInt gets there without ever writing `GC.free` itself.)
#
# So the walk can dereference `chunk.value` on a chunk that is already gone.
# The segfault is the *mild* outcome. `madvise(MADV_DONTNEED)` computed from a
# stale header and issued after the kernel has handed that range to somebody
# else's `mmap` zeroes live memory belonging to another allocation, silently.
#
#   workers    allocate a large block, write it, verify it, GC.free it
#   collector  GC.collect in a loop, so the flush walks never stop
#   ballast    many small objects, so the walk is long and the window is wide
#
# `GCRY_MOSTLY_EMPTY=1` is what keeps the third walk from returning early; it
# is the one that visits every chunk regardless of flags, because the filters
# (`sparse?`, `large?`, `dormant?`) all read `chunk.value` *before* deciding to
# skip. Reading the header is the unsafe act, not the madvise.
#
# `GCRY_UNMAP_GUARD=1` turns the munmap into `mprotect(PROT_NONE)`, so a walk
# that steps onto a released chunk faults on the spot and the report names the
# chunk instead of the crash landing somewhere else later.
#
#   crystal build -Dgc_none bench/dormant_flush_race.cr -o bin/dormant_flush_race
#   bin/dormant_flush_race

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "dormant_flush_race requires -Dgc_none (gcry as process GC)" %}
{% end %}

PAYLOAD = 40_u64 * 1024
WORKERS =       4
ROUNDS  =  10_000
BALLAST =  40_000
FILL    = 0x5C_u8

class Verdict
  @@corrupt = Atomic(Int32).new(0)
  @@done = Atomic(Int32).new(0)

  def self.corrupt!
    @@corrupt.add(1)
  end

  def self.corrupt
    @@corrupt.get
  end

  def self.finish
    @@done.add(1)
  end

  def self.finished
    @@done.get
  end
end

if ARGV.includes?("--child")
  heap = Gcry.default_heap

  # A long chunk list: the flush walks visit every one of these, so the window
  # in which a peer can unmap something the walk has not reached yet is as wide
  # as the list is long. Keep them reachable so the sweep cannot shorten it.
  ballast = Array(Bytes).new(BALLAST)
  BALLAST.times { ballast << Bytes.new(256) }

  threads = [] of Thread
  WORKERS.times do
    threads << Thread.new do
      ROUNDS.times do
        p = GC.malloc_atomic(PAYLOAD)
        bytes = p.as(UInt8*)
        i = 0_u64
        while i < PAYLOAD
          bytes[i] = FILL
          i += 64
        end
        i = 0_u64
        while i < PAYLOAD
          Verdict.corrupt! if bytes[i] != FILL
          i += 64
        end
        GC.free(p)
      end
      Verdict.finish
    end
  end

  collector = Thread.new do
    until Verdict.finished >= WORKERS
      GC.collect
    end
  end

  threads.each(&.join)
  collector.join

  puts "child: #{Verdict.corrupt} corrupt verifies, walks #{heap.live_walk_spans}, " \
       "queued #{heap.live_walk_queued}, direct #{heap.live_walk_direct}, ballast #{ballast.size}"
  exit(Verdict.corrupt > 0 ? 1 : 0)
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
attempts = (ENV["DORMANT_FLUSH_RACE_ATTEMPTS"]?.try(&.to_i?) || 6)

puts "=== post-STW flush walk vs. mutator unmap ==="
puts "#{WORKERS} workers × #{ROUNDS} rounds of #{PAYLOAD} B, one collector, #{BALLAST} ballast objects"
puts ""

# Bounded, and hangs counted apart from faults — see the same change in
# `page_release_corruption.cr`. A bare `Process.run` with no deadline turns a
# hung child into a hung gate, and a hung gate reads as a slow one; that is how
# the stop-the-world hang fixed in 0.21.1 stayed invisible for a day.
def run(exe : String, env, attempts : Int32) : {Int32, Int32, String?}
  bad = 0
  hung = 0
  first = nil
  attempts.times do
    result = BoundedChild.run(exe, ["--child"], env)
    unless result.ok
      bad += 1
      hung += 1 if result.timed_out
      first ||= result.output.lines.find { |l| l.includes?("gcry:") || l.includes?("Invalid memory access") }
    end
  end
  {bad, hung, first}
end

base = {"GCRY_MOSTLY_EMPTY" => "1", "GCRY_UNMAP_GUARD" => "1", "GCRY_SEGV_REPORT" => "1"}
immediate = base.merge({"GCRY_TRIM_IMMEDIATE" => "1"})

failures = [] of String

queued_bad, queued_hung, queued_note = run(exe, base, attempts)
puts "  queued (default):    #{queued_bad} of #{attempts} failed" \
     "#{queued_hung > 0 ? " (#{queued_hung} timed out)" : ""}" \
     "#{queued_note ? "\n     #{queued_note.strip}" : ""}"

immediate_bad, immediate_hung, immediate_note = run(exe, immediate, attempts)
puts "  immediate (old):     #{immediate_bad} of #{attempts} failed" \
     "#{immediate_hung > 0 ? " (#{immediate_hung} timed out)" : ""}" \
     "#{immediate_note ? "\n     #{immediate_note.strip}" : ""}"

hung_total = queued_hung + immediate_hung
if hung_total > 0
  failures << "#{hung_total} child(ren) were killed on the deadline — a killed child " \
              "says nothing about whether a flush walk meets a released chunk. " \
              "Re-run with GCRY_STW_WATCHDOG_MS set"
end
failures << "the queued arm faulted #{queued_bad - queued_hung} of #{attempts} — a flush walk still meets a released chunk" if queued_bad - queued_hung > 0
if immediate_bad - immediate_hung == 0
  failures << "the immediate arm survived #{attempts} attempts, so this harness does not reach the race " \
              "and the queued arm's silence is not evidence"
end

puts ""
if failures.empty?
  puts "ok — queued, the walks never meet a released chunk; unqueued, they do"
  exit 0
else
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
