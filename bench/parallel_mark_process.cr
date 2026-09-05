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
# Build: crystal build -Dgc_none bench/parallel_mark_process.cr -o bin/parallel_mark_process
# Run:   ./bin/parallel_mark_process

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
raise "no heap" unless h
raise "expected stop_the_world" unless h.stop_the_world

old = h.parallel_mark_workers
begin
  h.parallel_mark_workers = 4
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

  raise "parallel_mark_runs did not increase (#{before_runs} -> #{h.parallel_mark_runs})" unless h.parallel_mark_runs > before_runs
  raise "parallel_mark_stolen did not increase (#{before_stolen} -> #{h.parallel_mark_stolen})" unless h.parallel_mark_stolen > before_stolen

  # The graph has to still be whole: a marker that loses an edge is the defect
  # `make parallel-mark-termination` exists for, and this walk is the cheap
  # end-to-end check that four workers marked the same heap one would have.
  walked = 0
  node = head.as(Node?)
  while n = node
    raise "chain damaged at #{walked}: #{n.tag.inspect}" unless n.tag == "pm-#{walked}"
    walked += 1
    node = n.succ
  end
  raise "chain truncated at #{walked} of #{LIVE}" unless walked == LIVE
ensure
  h.parallel_mark_workers = old
end

puts "parallel_mark_process ok"
