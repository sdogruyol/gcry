# Does the mark clear cover every chunk the marker can mark?
#
# `mark_impl` resolves a candidate's chunk with `chunk_containing`, which reads
# `@chunk_index`. `clear_all_marks` used to walk the `@chunks` list. Those are
# the same set almost always — chunks on the list and not indexed read 0 in
# every run measured — but not quite: a chunk indexed and not listed turns up
# about one run in fourteen under thread churn, produced by the prepend race
# between the sweep's walk and `map_chunk`.
#
# A chunk the clear misses keeps its marks, and this is what that costs, in
# the words of the nursery case that hit it first (`clear_all_marks`):
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
#   bin/mark_clear_index --control  # children under the two restoring knobs
#
# `--control` is the parent. It forks `--child` under
# `GCRY_MARK_CLEAR_LIST=1` and `GCRY_SWEEP_MUTATOR_LATCH=0` — the same pair
# `thread-churn-uaf --control` uses, split out so this gate can fail when the
# clear no longer depends on which set it walks. The census excludes
# `--control` on purpose (a control has to pass); the knobs and `--child` are
# the red direction. Dropping them leaves every child clean, which is FAIL.
#
# Both halves, because the residue needs a chunk off the list to exist in the
# first place. Measured: 11 of 14 runs produce residue with the list walk and
# the pre-fix mutator-count reads, 0 of 20 with the shipped clear.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "mark_clear_index requires -Dgc_none (gcry as process GC)" %}
{% end %}

ROUNDS  = (ENV["MARK_CLEAR_ROUNDS"]?.try(&.to_i?) || 240)
THREADS = 8
# The broken arm runs in child processes, and that is not incidental:
# restoring the pre-fix shape restores the defect, so a child can *crash*
# instead of finishing its report. Both outcomes prove the same thing — the
# shape is broken — and only a child that finishes cleanly with no residue
# means the harness has stopped driving it. Run in-process, the crash exited
# non-zero and read as a gate failure, 1 run in 12.
CONTROL_ATTEMPTS   = 6
CONTROL_MAX_ROUNDS = ROUNDS * 8
# What the broken arm actually needs, learned the hard way on 2026-09-13: mark
# residue requires a chunk off the `@chunks` list, a chunk leaves the list only
# through a prepend that races the sweep's walk, and a prepend happens in
# `map_chunk`. Thread churn alone maps about thirty chunks per child, so the
# arm was running on a denominator of thirty and passing on luck — it found
# residue 6 of 6 times locally and **0 of 6** on the two-core CI runner, which
# is the gate's own inconclusive arm firing correctly.
# So the workload grows a live set and drops it whole, which releases chunks
# and maps them again: ~60 mappings a round instead of ~0.03. Measured in
# `bench/log/linux/2026-09-13-chunk-list-drift/FINDINGS.md`.
MAIN_PER_ROUND = 64
ALLOC_BYTES    = 8 * 1024
SAWTOOTH       = 20
# And the born threads have to allocate, not just exist. Threads that start
# and stop are usually gone by the time the after-world sweep walks the list,
# so the prepend that strands a chunk never comes from a mutator racing that
# walk — measured as a bimodal control, 82 stranded chunks in one child and
# zero in the next two. With this it is every child.
ALLOC_PER_THREAD = 12
# The broken arm leaks what it strands — 97% of its heap on the drift harness
# — so it stops at a ceiling rather than growing until the runner kills it.
HEAP_CAP = 512_u64 << 20

# Both halves of the pre-fix shape, plus the two audits the parent reads.
# Either restoring knob alone leaves nothing to find — the list walk has no
# off-list chunks to miss, the unlatched mutator count has nothing that
# misses them. The audits are how residue and offlist become numbers rather
# than a silent pass; a child without them reports 0/0 on a heap that is
# broken.
BROKEN = {
  "GCRY_MARK_CLEAR_LIST"     => "1",
  "GCRY_SWEEP_MUTATOR_LATCH" => "0",
  "GCRY_MARK_CLEAR_AUDIT"    => "1",
  "GCRY_CHUNK_LIST_AUDIT"    => "1",
}

heap = Gcry.default_heap.not_nil!
child = ARGV.includes?("--child")

# The parent spawns children and reads their verdicts; everything below this
# runs in a child or in the shipped arm.
if ARGV.includes?("--control")
  self_path = Process.executable_path || "bin/mark_clear_index"
  puts "=== does the mark clear cover the set the marker marks? ==="
  puts "broken: GCRY_MARK_CLEAR_LIST=1 GCRY_SWEEP_MUTATOR_LATCH=0, #{CONTROL_ATTEMPTS} children"
  puts ""
  residue_seen = 0
  offlist_seen = 0
  crashed = 0
  clean = 0
  CONTROL_ATTEMPTS.times do
    sink = IO::Memory.new
    status = Process.run(self_path, ["--child"],
      env: BROKEN, output: sink, error: Process::Redirect::Close)
    out = sink.to_s
    residue = out.lines.find(&.starts_with?("residue=")).try(&.split('=').last.to_u64?) || 0_u64
    offlist = out.lines.find(&.starts_with?("offlist=")).try(&.split('=').last.to_u64?) || 0_u64
    if !status.success?
      # A crash is the defect this shape has, reported by the collector's own
      # SEGV path. It proves the shape is broken as surely as residue does.
      crashed += 1
    elsif residue > 0
      residue_seen += 1
    elsif offlist > 0
      # Residue is the stronger event and needs two things: a chunk stranded
      # off the list *and* something marking into it afterwards. Under a
      # workload that maps, the pre-fix shape strands chunks by the hundred
      # but most of them are garbage nothing marks into — measured 2 of 6
      # children with residue and 6 of 6 with strands. The strand is the
      # situation the shipped clear is what protects against, so it is what
      # this arm has to show.
      offlist_seen += 1
    else
      clean += 1
    end
  end
  puts "children with mark residue:       #{residue_seen}"
  puts "children with an off-list chunk:  #{offlist_seen}"
  puts "children that crashed:            #{crashed}"
  puts "children clean:                   #{clean}"
  puts ""
  if residue_seen + offlist_seen + crashed == 0
    puts "FAIL every one of #{CONTROL_ATTEMPTS} children ran under GCRY_MARK_CLEAR_LIST=1"
    puts "and GCRY_SWEEP_MUTATOR_LATCH=0, stranded no chunk off the list, found no mark"
    puts "residue and did not crash. Either the prepend race that puts a chunk in the"
    puts "index and off the list has stopped happening, or the knobs no longer restore"
    puts "the list walk. Both make the shipped run prove nothing."
    exit 1
  end
  puts "ok — the pre-fix shape still breaks (#{residue_seen} with residue, #{offlist_seen} with a"
  puts "stranded chunk, #{crashed} crashed), so the"
  puts "shipped arm's zero is attributable to walking the index."
  exit 0
end

heap.mark_clear_audit = true
# Also count what the divergence itself retains: a chunk off the list is never
# swept, so the residual is an RSS number and this is where it comes from.
heap.chunk_list_audit = true
# The list-walk / unlatched-mutator-count pair is applied only through
# `apply_env_config` in the child. Setting the properties here would hide a
# knob that no longer restores the pre-fix shape: the parent would still see
# residue and the census would still see a fork.

unless child
  puts "=== does the mark clear cover the set the marker marks? ==="
  puts "clear walks: the chunk index (shipped)"
  puts "mutator count: latched in the stop"
  puts ""
end

limit = child ? CONTROL_MAX_ROUNDS : ROUNDS
rounds = 0
live = [] of Array(UInt8)
while rounds < limit
  break if child && heap.mark_clear_residue > 0
  break if heap.heap_size > HEAP_CAP
  rounds += 1
  born = [] of Thread
  THREADS.times do
    born << Thread.new do
      mine = [] of Array(UInt8)
      ALLOC_PER_THREAD.times { mine << Array(UInt8).new(ALLOC_BYTES, 3_u8) }
      mine.size
    end
  end
  # The live set is what makes chunks be mapped rather than reused: it grows
  # for SAWTOOTH rounds and is dropped whole, so the sweep releases its chunks
  # and the rounds after it map new ones.
  MAIN_PER_ROUND.times { live << Array(UInt8).new(ALLOC_BYTES, 1_u8) }
  GC.collect
  born.each(&.join)
  live.clear if rounds % SAWTOOTH == 0
end

unless child
  puts "rounds run:              #{rounds}"
  puts "mark_clear_residue:      #{heap.mark_clear_residue}"
  puts "chunk_index_only:        #{heap.chunk_index_only}"
  puts "chunk_index_only_bytes:  #{heap.chunk_index_only_bytes}"
  puts ""
end

if child
  # The two lines the parent reads: the residue, and the strand it needs to
  # exist first. Nothing else here is load-bearing.
  puts "residue=#{heap.mark_clear_residue}"
  puts "offlist=#{heap.chunk_index_only}"
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
