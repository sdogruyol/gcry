# Can the large-object cache hand out a chunk that a trimming peer is
# unmapping?
#
# `alloc_large` → `take_large_free` walks `@large_freelists` **holding
# `@alloc_lock`**, takes a chunk off the list and returns it to the mutator.
# `trim_large_cache` walks the same list; before 2026-08-23 it held nothing and
# `munmap`ed each chunk while still walking. Those two racing means a live
# buffer, just issued, can be unmapped under its owner.
#
# That was found while chasing a use-after-free in acikturkiye — a 69 632-byte
# large chunk released while a fiber wrote JSON into it
# (`bench/log/linux/2026-08-23-acik-crash/FINDINGS.md`) — and it could not be
# settled there: the crash rate fell from 7 of 60 to nothing between sessions,
# for reasons that were not the fix, and neither arm could be told from the
# other. So the question is asked directly instead of waiting for an
# application to ask it: this harness needs no Kemal, no Postgres and no rate.
#
#   workers   allocate a large block, write a pattern, verify it, free it
#   trimmer   calls `trim_large_cache(0)` in a loop
#
# With the lock, `take_large_free` and the trim's detach are serialised and no
# block is both handed out and torn down. Without it they interleave, and the
# worker writes into a chunk that is being unmapped: SIGSEGV, or a pattern that
# reads back wrong.
#
#   default              must survive, every verify clean
#   GCRY_TRIM_UNLOCKED=1 must fail — otherwise the arm above is not evidence
#
#   crystal build -Dgc_none bench/large_cache_race.cr -o bin/large_cache_race
#   bin/large_cache_race
#   GCRY_TRIM_UNLOCKED=1 bin/large_cache_race --child

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "large_cache_race requires -Dgc_none (gcry as process GC)" %}
{% end %}

# Comfortably over LARGE_THRESHOLD (32 KiB) and a single size, so every free
# feeds the bucket the next allocation takes from — `take_large_free` matches on
# exact mapped size, so one size maximises the overlap this is about.
PAYLOAD = 40_u64 * 1024
WORKERS =       4
ROUNDS  =  20_000
FILL    = 0xA7_u8

class Verdict
  @@corrupt = Atomic(Int32).new(0)
  @@done = Atomic(Int32).new(0)
  @@stop = Atomic(Int32).new(0)

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

  def self.stop!
    @@stop.set(1)
  end

  def self.stop?
    @@stop.get != 0
  end
end

if ARGV.includes?("--child")
  heap = Gcry.default_heap
  # Retain enough that a freed block stays cached for the next allocation to
  # take, which is the hit path `take_large_free` exists for. The trimmer then
  # asks for 0, so the two are pulling on the same list at the same time.
  heap.large_cache_retain = 64_u64 * 1024 * 1024

  threads = [] of Thread
  WORKERS.times do
    threads << Thread.new do
      ROUNDS.times do
        break if Verdict.stop?
        p = GC.malloc_atomic(PAYLOAD)
        bytes = p.as(UInt8*)
        i = 0_u64
        while i < PAYLOAD
          bytes[i] = FILL
          i += 64 # one byte per cache line is enough to touch every page
        end
        i = 0_u64
        while i < PAYLOAD
          if bytes[i] != FILL
            Verdict.corrupt!
            break
          end
          i += 64
        end
        GC.free(p)
      end
      Verdict.finish
    end
  end

  # The trimmer: same list, from another thread, as hard as it will go.
  trimmer = Thread.new do
    until Verdict.finished >= WORKERS
      heap.trim_large_cache(0_u64)
    end
  end

  threads.each(&.join)
  Verdict.stop!
  trimmer.join

  puts "child: #{Verdict.corrupt} corrupt verifies, cache hits #{heap.large_cache_hits}"
  exit(Verdict.corrupt > 0 ? 1 : 0)
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
attempts = (ENV["LARGE_CACHE_RACE_ATTEMPTS"]?.try(&.to_i?) || 5)
failures = [] of String

puts "=== large-cache race ==="
puts "#{WORKERS} workers × #{ROUNDS} rounds of #{PAYLOAD} B, one trimmer, #{attempts} attempts per arm"
puts ""

# `timed_out` is reported apart from `bad` on purpose. A child killed on the
# deadline says nothing about serialisation, and a gate that folds the two
# together will tell the next reader the allocator raced when all that happened
# was a slow machine.
# The gcry lines a crashed child left behind. `GCRY_SEGV_REPORT=1` classifies
# the address — released chunk, free block, hole — and without keeping them the
# gate can say a fault happened and nothing about what faulted. That is the
# difference between "the locked arm faulted 1 of 60 on aarch64" and knowing
# which of gcry's own structures it landed in.
def gcry_lines(captured : String) : String?
  lines = captured.lines.select { |l| l.starts_with?("gcry:") }
  return nil if lines.empty?
  lines.first(12).join("\n")
end

def run(exe : String, unlocked : Bool, attempts : Int32) : {Int32, Int32, String?, String?}
  bad = 0
  hung = 0
  first = nil
  report = nil
  env = {} of String => String
  env["GCRY_TRIM_UNLOCKED"] = "1" if unlocked
  attempts.times do
    result = BoundedChild.run(exe, ["--child"], env)
    captured = result.output
    unless result.ok
      bad += 1
      hung += 1 if result.timed_out
      first ||= captured.lines.find { |l| l.includes?("Invalid memory access") || l.includes?("corrupt") }
      report ||= gcry_lines(captured)
    end
  end
  {bad, hung, first, report}
end

locked_bad, locked_hung, locked_note, locked_report = run(exe, false, attempts)
# The hung count belongs on the line itself, not only in the failure list at
# the end. A reader who sees "1 of 20 failed" cannot tell a use-after-free from
# a child killed on the deadline, and those are different defects with
# different owners — the gate says so in its own failure text and then prints a
# summary that hides it.
puts "  locked (default):    #{locked_bad} of #{attempts} failed" \
     "#{locked_hung > 0 ? " (#{locked_hung} timed out)" : ""}" \
     "#{locked_note ? "   #{locked_note.strip}" : ""}"
if locked_report
  puts "  what the locked arm's first crash said:"
  locked_report.each_line { |l| puts "    #{l}" }
end

unlocked_bad, unlocked_hung, unlocked_note, _ = run(exe, true, attempts)
puts "  unlocked (old):      #{unlocked_bad} of #{attempts} failed#{unlocked_note ? "   #{unlocked_note.strip}" : ""}"

if locked_hung > 0
  failures << "the locked arm timed out #{locked_hung} of #{attempts} — a killed child is not " \
              "evidence about serialisation, so raise BENCH_CHILD_TIMEOUT_S or find the hang"
end
if locked_bad > locked_hung
  failures << "the locked arm faulted #{locked_bad - locked_hung} of #{attempts} — the allocator " \
              "and the trim are not serialised"
end
if unlocked_bad == 0
  failures << "the unlocked arm survived #{attempts} attempts, so this harness does not reach the race " \
              "and the locked arm's silence is not evidence"
end

puts ""
if failures.empty?
  puts "ok — serialised, the allocator and the trim cannot collide; unserialised, they do"
  exit 0
else
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
