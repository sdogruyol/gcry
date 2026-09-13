# A live large object is released under thread churn.
#
# `ROADMAP.md` has carried this defect since 2026-08-23 as *"A live large
# object is released under load on the fat app"*: a large-object chunk
# released by the large-object path and written into afterwards, with
# `GCRY_MARK_AUDIT=1` reporting **0 edges** — no heap object holds it, so the
# only holder is a stack slot or a register and the root scan is not seeing
# it. It was found under `wrk` against acikturkiye at roughly one run in
# eight, then stopped reproducing, and the item says what that cost:
#
#   > until the crash reproduces at a resolvable rate, no arm here means
#   > anything … step one next time is re-establishing the baseline on the
#   > current tree.
#
# This is that baseline, and it needs neither `wrk` nor an application:
# eight short-lived threads per round, one collection per round. It fires on
# **both** object layouts with no research knob set, in about a second per
# attempt.
#
# The header layout is what makes it legible. `GCRY_UNMAP_GUARD=1` releases a
# chunk with `mprotect(PROT_NONE)` instead of `munmap` and keeps its
# identity, so the report names the chunk rather than "some address in no
# live chunk":
#
#   SIGSEGV at 0x… — in a chunk gcry RELEASED — base 0x…, 45056 bytes,
#   large-object release, at collection 19; the write is 48 bytes into it.
#   Collections since: 141.
#   holders — heap: 0 word(s) in 0 live block(s)
#   holders — stack: fiber 0x… (running) slot 0x… holds block+0
#
# Which is the 2026-08-23 shape exactly, at a different size.
#
# Two arms:
#
#   default       no knobs. The rate the shipped collector has.
#   amplified     `GCRY_THREAD_UNSTAGE_ON_DEATH=1`, which drops a dead
#                 thread's staging record and with it the pre-stop wait's
#                 spin — the accidental delay that was hiding this
#                 (src/gcry/platform/thread_staging.cr). Roughly 20x the
#                 rate, and the arm to drive a bisect with.
#
# Not a CI gate: it fails a small fraction of runs on purpose, and gating on
# a rate would make every unrelated push flaky. What it *does* assert is
# that the amplified arm still reproduces — a reproducer that has silently
# stopped reproducing is worse than none, and this file exists because that
# happened to the last one.
#
#   crystal build -Dgc_none bench/thread_churn_uaf.cr -o bin/thread_churn_uaf
#   bin/thread_churn_uaf
#   bin/thread_churn_uaf --child

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "thread_churn_uaf requires -Dgc_none (gcry as process GC)" %}
{% end %}

ROUNDS   = (ENV["CHURN_ROUNDS"]?.try(&.to_i?) || 240)
BATCH    = 8
ATTEMPTS = (ENV["CHURN_ATTEMPTS"]?.try(&.to_i?) || 24)
LANES    = 6

if ARGV.includes?("--child")
  ROUNDS.times do
    born = [] of Thread
    BATCH.times { born << Thread.new { } }
    GC.collect
    born.each(&.join)
  end
  puts "ok"
  exit 0
end

self_path = Process.executable_path || "bin/thread_churn_uaf"

record Arm, name : String, env : Hash(String, String)
record Result, name : String, runs : Int32, failed : Int32, report : String?

# The diagnostics travel with the arms rather than being something to
# remember: this defect produced one unreadable sighting per week for a
# month, and the report is the whole value of a sighting.
# The two diagnostics surface **different victims**, and running them
# together hides one: the freed-block poison makes a small-block read fault
# first, before the released large chunk is ever touched. So they get their
# own arms.
#
# `GCRY_UNMAP_GUARD=1` releases a chunk with `mprotect(PROT_NONE)` instead of
# `munmap` and keeps its identity, which is what turns "some address in no
# live chunk" into a named chunk, its size, the path that released it and the
# collection it happened at.
GUARD = {
  "GCRY_UNMAP_GUARD" => "1",
  "GCRY_SEGV_REPORT" => "1",
}
# Poison makes a stale *read* fault instead of quietly returning recycled
# memory, which is why it raises the rate by an order of magnitude — and why
# it is not the arm to read the large-object release from.
POISON = GUARD.merge({"GCRY_POISON_HOLDERS" => "1"})

def run_arm(self_path : String, arm : Arm, attempts : Int32, want : String) : Result
  failed = 0
  report = nil
  remaining = attempts
  while remaining > 0
    lanes = remaining < LANES ? remaining : LANES
    remaining -= lanes
    children = Array(Tuple(Process, IO::Memory)).new(lanes)
    lanes.times do
      sink = IO::Memory.new
      children << {Process.new(self_path, ["--child"], env: arm.env,
        output: Process::Redirect::Close, error: sink), sink}
    end
    children.each do |process, sink|
      status = process.wait
      next if status.success?
      failed += 1
      next if report
      lines = sink.to_s.lines
      report = lines.find(&.includes?(want)).try(&.strip) ||
               lines.find(&.starts_with?("gcry:")).try(&.strip)
    end
  end
  Result.new(arm.name, attempts, failed, report)
end

puts "=== a live large object released under thread churn ==="
puts "#{ATTEMPTS} attempts per arm, #{ROUNDS} rounds x #{BATCH} threads each"
puts "layout: #{{{ flag?(:gcry_block_headers) ? "block headers" : "headerless" }}}"
puts ""

# `default` measures what the shipped collector does: no knobs, no
# diagnostics, so a stale read usually returns recycled memory and the run
# survives. That is the rate to quote, and it is also why the other two arms
# exist — at ~1.5% a sighting takes a hundred runs, and a sighting is the
# only thing that says anything.
#
# The other two carry the reproducer knob, which raises the rate about
# twentyfold by removing the pre-stop wait's accidental delay, and then
# differ in which victim they can name.
AMP = {"GCRY_THREAD_UNSTAGE_ON_DEATH" => "1"}

# `--control` restores the defect, and it takes two knobs because the defect
# took two things. Measured, 12 attempts each:
#
#   shipped                                        0/12
#   GCRY_SWEEP_MUTATOR_LATCH=0  (the trigger)      2/12
#   GCRY_MARK_CLEAR_LIST=1      (the consequence)  0/12
#   both — the pre-fix shape                       7/12
#
# The trigger is the mutator count read at two instants across `start_world`,
# which leaves chunks in `@chunk_index` and off the `@chunks` list. The
# consequence is that mark clearing walked the list, so those chunks kept their
# marks: every block in one reads marked forever, `mark_impl` returns early on
# it, nothing follows its edges, and what it points at is reclaimed while live.
# Either alone is nearly harmless; together they are the use-after-free.
#
# The control is here because a reproducer that has been fixed becomes a gate
# that can rot silently — if the harness stops driving the workload, the
# shipped arms read clean for the wrong reason.
CONTROL = {
  "GCRY_SWEEP_MUTATOR_LATCH" => "0",
  "GCRY_MARK_CLEAR_LIST"     => "1",
}

control = ARGV.includes?("--control")
extra = control ? CONTROL : {} of String => String

arms = [
  {Arm.new("default", extra.dup), "gcry:"},
  {Arm.new("guarded", GUARD.merge(AMP).merge(extra)), "RELEASED"},
  {Arm.new("poisoned", POISON.merge(AMP).merge(extra)), "use-after-free"},
]
results = arms.map { |arm, want| run_arm(self_path, arm, ATTEMPTS, want) }

results.each do |r|
  pct = r.runs.zero? ? 0.0 : 100.0 * r.failed / r.runs
  puts "  %-10s %d of %d failed (%.1f%%)" % [r.name, r.failed, r.runs, pct]
end
puts ""

results.each do |r|
  next unless report = r.report
  puts "#{r.name} sighting:"
  puts "  #{report}"
  puts ""
end

driven = results.find { |r| r.name == "poisoned" }.not_nil!

if control
  # The control must still reproduce. Measured on the fix's own A/B: 6 of 18
  # per layout: poisoned 7 of 12 with the pre-fix shape. Eight attempts here
  # miss that about once in a thousand runs.
  if driven.failed == 0
    puts "FAIL the control arm did not reproduce in #{driven.runs} attempts. With the"
    puts "pre-fix shape this workload faults about 58% of attempts, so a clean run"
    puts "here means the harness has stopped driving the defect and the shipped arms"
    puts "above prove nothing. That is how the last reproducer for this was lost."
    exit 1
  end
  puts "ok — with the pre-fix shape restored the defect still reproduces, so the"
  puts "clean shipped run is attributable to the fixes and not to the harness."
  exit 0
end

total = results.sum(&.failed)
if total > 0
  puts "FAIL #{total} run(s) faulted. This was fixed on 2026-09-13 in two places."
  puts "The trigger: the sweep read `multi_mutator_threads?` at two instants across"
  puts "`start_world` — inside the stop, where the decision it drives is taken, and"
  puts "again during the sweep — and a thread born in between flipped the answer,"
  puts "leaving chunks in `@chunk_index` and off the `@chunks` list. The consequence:"
  puts "mark clearing walked the list, so those chunks kept their marks, every block"
  puts "in one read marked forever, `mark_impl` returned early on it, and nothing"
  puts "followed its edges. `GCRY_CHUNK_LIST_AUDIT=1` reports the first directly and"
  puts "`GCRY_MARK_CLEAR_AUDIT=1` the second."
  exit 1
end

puts "ok — no arm faulted. With the pre-fix shape restored this workload faults"
puts "about 58% of attempts; `--control` does that and must still fail."
