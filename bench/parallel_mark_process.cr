# Process-GC parallel mark (STW-exempt pthreads) — standalone (Phase 6 CI harden).
#
# Kept out of process_spec: Spec + parallel mark + GC.collect was flaky on CI
# (SEGV inside Spec::Result reporting after the example body succeeded).
#
# ## The live set has to be big enough for a worker to reach it
#
# This asserts that the workers actually *stole* — `parallel_mark_stolen` is
# what separates "four workers were configured" from "four workers marked".
# The graph was 64 strings plus 8 joins, about 72 objects, and that assertion
# lost a race roughly half the time: workers wake by spinning on
# `@mark_epoch`, and with 72 objects the master drains the shared stack before
# any of them observes the bump, so `stolen` is legitimately 0 and the harness
# called it a failure. Measured at ~72 objects: 4 of 8 runs on master,
# 2 of 5 on the PR #33 merge that introduced the sharded marker — so it was
# never this branch's regression, just a gate nobody could trust.
#
# A live set of `LIVE` objects makes the mark milliseconds long, which is
# orders of magnitude past a spin-wake, and the steal becomes reliable rather
# than lucky. The graph is a chain so the mark cannot be satisfied breadth-
# first from the roots: each node is discovered only by scanning its parent,
# which is what keeps the shared stack populated for the whole phase.
#
# Until 2026-09-20 the only way this gate came out red was a hand edit of
# the steal counter. `--disabled` pins workers at 1 through
# `GCRY_DISABLE_PARALLEL_MARK=1` and requires stolen stay 0. Dropping the
# knob reddens the gate rather than hiding it.
#
# Build: crystal build -Dgc_none bench/parallel_mark_process.cr -o bin/parallel_mark_process
# Run:   ./bin/parallel_mark_process
#        GCRY_DISABLE_PARALLEL_MARK=1 ./bin/parallel_mark_process --disabled

{% unless flag?(:gc_none) %}
  raise "parallel_mark_process requires -Dgc_none (gcry as process GC)"
{% end %}

require "../src/gcry"

LIVE = 200_000

class Node
  property succ : Node?
  property tag : String

  def initialize(@tag : String)
  end
end

h = Gcry.default_heap
unless h
  STDERR.puts "FAIL no heap"
  exit 1
end
unless h.stop_the_world
  STDERR.puts "FAIL expected stop_the_world"
  exit 1
end

disabled = ARGV.includes?("--disabled")
if disabled && !h.force_serial_mark?
  STDERR.puts "--disabled needs GCRY_DISABLE_PARALLEL_MARK=1: without the skip this arm would require stolen to stay 0 while four workers are marking."
  exit 64
end

old = h.parallel_mark_workers
begin
  h.parallel_mark_workers = 4
  workers = h.parallel_mark_workers
  if disabled
    unless workers == 1
      STDERR.puts "FAIL GCRY_DISABLE_PARALLEL_MARK=1 did not pin workers at 1 (got #{workers})"
      exit 1
    end
  else
    unless workers == 4
      STDERR.puts "FAIL expected 4 workers, got #{workers}"
      exit 1
    end
  end

  before_runs = h.parallel_mark_runs
  before_stolen = h.parallel_mark_stolen

  head = Node.new("pm-0")
  cur = head
  (1...LIVE).each do |i|
    n = Node.new("pm-#{i}")
    cur.succ = n
    cur = n
  end

  GC.collect
  GC.collect

  runs = h.parallel_mark_runs
  stolen = h.parallel_mark_stolen
  if disabled
    if stolen > before_stolen
      STDERR.puts "FAIL parallel_mark_stolen increased under disable (#{before_stolen} -> #{stolen}) — GCRY_DISABLE_PARALLEL_MARK no longer pins workers at 1, so the only way this gate can fail is a hand edit of the steal counter again."
      exit 1
    end
    if runs > before_runs
      STDERR.puts "FAIL parallel_mark_runs increased under disable (#{before_runs} -> #{runs})"
      exit 1
    end
  else
    unless runs > before_runs
      STDERR.puts "FAIL parallel_mark_runs did not increase (#{before_runs} -> #{runs})"
      exit 1
    end
    unless stolen > before_stolen
      STDERR.puts "FAIL parallel_mark_stolen did not increase (#{before_stolen} -> #{stolen})"
      exit 1
    end
  end

  # The graph has to still be whole: a marker that loses an edge is the defect
  # `make parallel-mark-termination` exists for, and this walk is the cheap
  # end-to-end check that four workers marked the same heap one would have.
  walked = 0
  node = head.as(Node?)
  while n = node
    unless n.tag == "pm-#{walked}"
      STDERR.puts "FAIL chain damaged at #{walked}: #{n.tag.inspect}"
      exit 1
    end
    walked += 1
    node = n.succ
  end
  unless walked == LIVE
    STDERR.puts "FAIL chain truncated at #{walked} of #{LIVE}"
    exit 1
  end

  puts "arm: #{disabled ? "--disabled (workers pinned at 1, stolen must stay 0)" : "shipped (4 workers, stolen must rise)"}"
  puts "workers=#{workers} runs #{before_runs}->#{runs} stolen #{before_stolen}->#{stolen} chain=#{walked}"
  puts disabled ? "ok — serial mark kept the chain and stole nothing" : "parallel_mark_process ok"
ensure
  h.parallel_mark_workers = old if h
end
exit 0
