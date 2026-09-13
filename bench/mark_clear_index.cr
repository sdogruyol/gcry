# Does the mark clear cover every chunk the marker can mark?
#
# `mark_impl` resolves a candidate's chunk with `chunk_containing`, which reads
# `@chunk_index`. `clear_all_marks` used to walk the `@chunks` list. Those are
# the same set almost always — chunks on the list and not indexed read 0 in
# every run measured — but not quite: a chunk indexed and not listed turns up
# about one run in fourteen under thread churn, produced by the prepend race
# between the sweep's walk and `map_chunk`.
#
# A chunk the clear misses keeps its marks, and this is what that costs, in the
# words of the nursery case that hit it first (`clear_all_marks`):
#
#   > the block then read marked forever, `mark_impl` returned early without
#   > scanning it, and anything reachable only through it was reclaimed
#   > **while live**
#
# It is one half of the live-object release open from 2026-08-23. Decomposed
# over 12 attempts of `make thread-churn-uaf`: the mutator-count trigger alone
# faults 2, this alone 0, both 7. The trigger leaves chunks off the list; this
# is what makes them fatal.
#
# So the clear walks the index, and this gate is the pair that says so:
#
#   bin/mark_clear_index            # shipped: no chunk keeps a mark
#   bin/mark_clear_index --control  # the list walk back: some chunk does
#
# The control sets both halves, because the residue needs a chunk off the list
# to exist in the first place. Measured: 11 of 14 runs produce residue with the
# list walk and the pre-fix mutator-count reads, 0 of 20 with the shipped
# clear.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "mark_clear_index requires -Dgc_none (gcry as process GC)" %}
{% end %}

ROUNDS  = (ENV["MARK_CLEAR_ROUNDS"]?.try(&.to_i?) || 240)
THREADS = 8
# The control runs in child processes, and that is not incidental: restoring
# the pre-fix shape restores the defect, so a control child can *crash* instead
# of finishing its report. Both outcomes prove the same thing — the shape is
# broken — and only a child that finishes cleanly with no residue means the
# harness has stopped driving it. Run in-process, the crash exited non-zero and
# read as a gate failure, 1 run in 12.
CONTROL_ATTEMPTS   = 6
CONTROL_MAX_ROUNDS = ROUNDS * 8

heap = Gcry.default_heap.not_nil!
control_child = ARGV.includes?("--control-child")
control = ARGV.includes?("--control") || control_child

# The control parent spawns children and reads their verdicts; everything
# below this runs in a child or in the shipped arm.
if ARGV.includes?("--control")
  self_path = Process.executable_path || "bin/mark_clear_index"
  puts "=== does the mark clear cover the set the marker marks? ==="
  puts "control: the @chunks list walk and the pre-fix mutator-count reads, #{CONTROL_ATTEMPTS} children"
  puts ""
  residue_seen = 0
  crashed = 0
  clean = 0
  CONTROL_ATTEMPTS.times do
    sink = IO::Memory.new
    status = Process.run(self_path, ["--control-child"],
      output: sink, error: Process::Redirect::Close)
    line = sink.to_s.lines.find(&.starts_with?("residue="))
    if !status.success?
      # A crash is the defect this shape has, reported by the collector's own
      # SEGV path. It proves the shape is broken as surely as residue does.
      crashed += 1
    elsif line && (n = line.split('=').last.to_u64?) && n > 0
      residue_seen += 1
    else
      clean += 1
    end
  end
  puts "children with mark residue: #{residue_seen}"
  puts "children that crashed:      #{crashed}"
  puts "children clean:             #{clean}"
  puts ""
  if residue_seen + crashed == 0
    puts "FAIL every one of #{CONTROL_ATTEMPTS} children walked the list, found nothing and did not"
    puts "crash. Either the prepend race that puts a chunk in the index and off the list"
    puts "has stopped happening, or the clear no longer depends on which set it walks."
    puts "Both make the shipped run prove nothing."
    exit 1
  end
  puts "ok — the pre-fix shape still breaks (#{residue_seen} with residue, #{crashed} crashed), so the"
  puts "shipped arm's zero is attributable to walking the index."
  exit 0
end

heap.mark_clear_audit = true
# Also count what the divergence itself retains: a chunk off the list is never
# swept, so the residual is an RSS number and this is where it comes from.
heap.chunk_list_audit = true
if control
  # Both halves of the pre-fix shape: the clear walks the list again, and the
  # mutator count is read per decision so chunks leave the list at their old
  # rate. Either alone leaves nothing to find — the first has no off-list
  # chunks to miss, the second has nothing that misses them.
  heap.mark_clear_list = true
  heap.sweep_mutator_latch = false
end

unless control_child
  puts "=== does the mark clear cover the set the marker marks? ==="
  puts "clear walks: the chunk index (shipped)"
  puts "mutator count: latched in the stop"
  puts ""
end

limit = control ? CONTROL_MAX_ROUNDS : ROUNDS
rounds = 0
while rounds < limit
  break if control && heap.mark_clear_residue > 0
  rounds += 1
  born = [] of Thread
  THREADS.times { born << Thread.new { } }
  GC.collect
  born.each(&.join)
end

unless control_child
  puts "rounds run:              #{rounds}"
  puts "mark_clear_residue:      #{heap.mark_clear_residue}"
  puts "chunk_index_only:        #{heap.chunk_index_only}"
  puts "chunk_index_only_bytes:  #{heap.chunk_index_only_bytes}"
  puts ""
end

if control_child
  # The parent reads this line. Nothing else here is load-bearing.
  puts "residue=#{heap.mark_clear_residue}"
  exit 0
end

if heap.mark_clear_residue > 0
  puts "FAIL #{heap.mark_clear_residue} chunk(s) the index knows about still held a mark after"
  puts "`clear_all_marks`. Every block in one reads marked forever: `mark_impl` returns"
  puts "early on it, nothing follows its edges, and what it points at is reclaimed while"
  puts "live. The clear must cover the set the marker marks, which is the index."
  exit 1
end

puts "ok — no chunk the index knows about kept a mark across #{rounds} collections."
if heap.chunk_index_only > 0
  puts "(#{heap.chunk_index_only} chunk sighting(s) off the list, #{heap.chunk_index_only_bytes} bytes retained — the"
  puts "prepend race, which is an RSS question now that their marks are cleared.)"
end
exit 0
