# Does the chunk-list divergence accumulate with uptime, or is it one chunk?
#
# `map_chunk` prepends to `@chunks` under the index lock; the after-world sweep
# rebuilds `@chunks` from a walk it started earlier. A prepend that lands during
# that walk is not on the rebuilt list, and the chunk stays in `@chunk_index`.
# It cannot come back: the rebuild walks from `@chunks`, and nothing re-links a
# chunk the head no longer reaches. So the loss is permanent by construction —
# what was never measured is the **rate**, and the rate is what separates "128
# KiB, once" from "an unbounded leak proportional to thread churn".
#
# Since 2026-09-13 the marks of such a chunk are cleared anyway (the clear walks
# the index), so this is an RSS question and not a soundness one. It is the last
# open piece of the 2026-08-23 live-object release
# (`bench/log/linux/2026-09-12-writer-frames/FINDINGS.md`).
#
# Two arms, because on the shipped tree the event is rare (about one run in
# fourteen of `make thread-churn-uaf`) and rare events cannot be sampled over
# uptime in a minute:
#
#   bin/chunk_list_drift          # shipped: the mutator count is latched
#   bin/chunk_list_drift --fast   # `sweep_mutator_latch = false`: same race,
#                                 # higher rate, so the accumulation shape shows
#
# The fast arm restores half of the pre-fix shape, which is why it runs in a
# child process: that shape faulted 2 of 12 times on the churn reproducer, and a
# crash mid-measurement must cost the last bucket rather than the whole run.
# Buckets are printed as they complete for the same reason.
#
# What the numbers mean: `chunk_index_only_now` is the count of chunks the index
# holds and the list does not, as of the last collection. Monotone, so the slope
# across buckets is chunks lost per collection, and each is `mapped_bytes` of
# retained memory that no sweep will ever visit.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "chunk_list_drift requires -Dgc_none (gcry as process GC)" %}
{% end %}

# The rate is the reason this is long. On the shipped tree the divergence turns
# up in about one run in fourteen of `make thread-churn-uaf`, and a run there is
# 240 collections — so ~1 event per 3000 collections, and a 180-collection
# sample measured exactly what it should have: nothing, in both arms.
ROUNDS  = (ENV["CHUNK_DRIFT_ROUNDS"]?.try(&.to_i?) || 6000)
BUCKETS = 6
# The churn reproducer's eight threads per collection, plus the allocation the
# denominator needs (see the note above the loop): thread birth alone mapped 32
# chunks in 1200 collections, which measures almost nothing.
THREADS = 8
# What drives the denominator, and it is the live set rather than the garbage:
# garbage is reused inside the chunks that already exist, while a chunk is only
# *mapped* when peak demand grows. So the main thread grows a live set by
# MAIN_PER_ROUND blocks a round, drops it whole every SAWTOOTH rounds — empty
# chunks are released on Linux by default, so the next cycle maps them again —
# and the born threads allocate a little each, because the prepend that strands
# a chunk has to come from a mutator racing the sweep's walk.
ALLOC_PER_THREAD = 12
ALLOC_BYTES      = 8 * 1024
MAIN_PER_ROUND   = 64
SAWTOOTH         = 20
# The fast arm strands ~88% of what it maps, so it grows without bound: 2.8 GB
# in 1200 rounds before this cap existed. It has proven its point long before
# then, and a measurement harness must not be the thing that OOMs the host.
HEAP_CAP = 1_u64 << 30
# The startup-regime arm: many short processes rather than one long one.
PLAIN_CHILDREN =  24
PLAIN_ROUNDS   = 240
# The gate. Not zero: the race is still open, and measured at below one
# stranded chunk per 700 000 mappings on the shipped tree — 0 of 693 291 in
# steady state, 0 of 6 280 across 200 short processes, and one sighting in 74
# runs of the churn reproducer, which is a sighting and not a rate. Gating on
# zero would red CI on the real event. The pre-fix shape strands 80-181 per
# 1000, so a cap three orders of magnitude below it separates "still rare" from
# "something reopened it" without flaking on the rare case.
MAX_PER_1000 = 5.0
# Below this the arm mapped too little to say anything. The first version of
# this harness churned threads and nothing else, mapped 32 chunks in 1200
# collections, and reported "nothing stranded in 90 000 collections" as if that
# were a bound. It was a bound on nothing, and this is the guard against
# publishing another one.
MIN_MAPPINGS = 5000_u64

record Bucket, round : Int32, chunks : UInt64, bytes : UInt64, heap_bytes : UInt64, mapped : UInt64

def run_child(self_path : String, fast : Bool, plain : Bool = false) : {Array(Bucket), Bool}
  args = ["--child"]
  args << "--fast" if fast
  args << "--plain" if plain
  sink = IO::Memory.new
  env = plain ? {"CHUNK_DRIFT_ROUNDS" => PLAIN_ROUNDS.to_s} : nil
  status = Process.run(self_path, args, env: env,
    output: sink, error: Process::Redirect::Close)
  buckets = [] of Bucket
  sink.to_s.each_line do |line|
    next unless line.starts_with?("bucket ")
    f = line.split
    next unless f.size == 6
    buckets << Bucket.new(f[1].to_i, f[2].to_u64, f[3].to_u64, f[4].to_u64, f[5].to_u64)
  end
  {buckets, status.success?}
end

def report(label : String, buckets : Array(Bucket), ok : Bool) : {Float64, UInt64}
  puts "=== #{label} ==="
  if buckets.empty?
    puts "  no buckets#{ok ? "" : " — the child crashed before the first one"}"
    puts ""
    return {0.0, 0_u64}
  end
  puts "  collections   off-list   retained B   heap B   chunks mapped"
  buckets.each do |b|
    puts "  #{b.round.to_s.rjust(11)}   #{b.chunks.to_s.rjust(8)}   #{b.bytes.to_s.rjust(10)}   #{b.heap_bytes.to_s.rjust(6)}   #{b.mapped.to_s.rjust(13)}"
  end
  last = buckets.last
  puts "  child crashed after bucket #{last.round} — the arm restores half the pre-fix shape" unless ok
  if last.chunks == 0
    puts "  nothing left the list in #{last.round} collections and #{last.mapped} mappings:"
    puts "  the rate is below 1 per #{last.mapped} mappings on this arm"
  else
    puts "  rate: #{last.chunks} stranded of #{last.mapped} chunks mapped = #{(last.chunks * 1000.0 / last.mapped).round(2)} per 1000 mappings,"
    puts "        #{(last.bytes / 1024.0).round(1)} KiB retained, #{(last.bytes * 100.0 / last.heap_bytes).round(1)}% of the heap at the end"
    # Per *mapping*, not per collection: the last two buckets say which axis
    # this rides. A run whose heap stopped growing and whose loss stopped with
    # it is a bounded leak; one that keeps losing while mapping nothing is not.
    #
    # Two buckets are not guaranteed. The pre-fix arm is *expected* to crash —
    # that crash is its evidence — and if it goes down before the second
    # bucket there is no slope to read. `buckets.empty?` was handled above and
    # this case was not, so the reporter died with `Index out of bounds` on
    # the arm whose whole purpose is to die (2026-09-20, the first run after
    # this gate moved to its own job, where the child happened to crash after
    # the first bucket). A reporter that falls over on its own evidence turns
    # a working gate into a red one.
    if buckets.size >= 2
      a, b = buckets[-2], buckets[-1]
      dm = b.mapped - a.mapped
      dc = b.chunks - a.chunks
      puts "  last bucket: #{dm} mapping(s), #{dc} stranded — " +
           (dm == 0 && dc == 0 ? "the heap stopped growing and the loss stopped with it" : dc == 0 ? "mapping without losing" : "still losing while it maps")
    else
      puts "  one bucket only#{ok ? "" : " — the child crashed before a second"}, so there is no slope to read"
    end
  end
  puts ""
  {last.chunks * 1000.0 / last.mapped, last.mapped}
end

heap = Gcry.default_heap.not_nil!

unless ARGV.includes?("--child")
  self_path = Process.executable_path || "bin/chunk_list_drift"
  puts "=== does the chunk-list divergence accumulate with uptime? ==="
  puts "#{ROUNDS} collections per arm, #{THREADS} threads born per collection — the churn"
  puts "reproducer's workload. A chunk off `@chunks` is never swept and cannot rejoin the"
  puts "list, so `off-list chunks` is monotone and its slope is the leak rate."
  puts ""
  shipped, shipped_ok = run_child(self_path, false)
  fast, fast_ok = run_child(self_path, true)
  shipped_rate, shipped_mapped = report("shipped — mutator count latched in the stop", shipped, shipped_ok)
  fast_rate, fast_mapped = report("fast — `sweep_mutator_latch = false`, the pre-fix reads", fast, fast_ok)

  # The third arm is a different regime, not a different tree: short-lived
  # processes whose heap is still being built. The steady-state arms above map
  # thousands of chunks into a heap that has found its size; this maps a few
  # dozen into one that has not, which is where the shipped sighting came from.
  puts "=== shipped, startup regime — #{PLAIN_CHILDREN} processes x #{PLAIN_ROUNDS} collections, thread churn only ==="
  plain_lost = 0_u64
  plain_mapped = 0_u64
  plain_with_loss = 0
  plain_crashed = 0
  PLAIN_CHILDREN.times do
    buckets, ok = run_child(self_path, false, plain: true)
    plain_crashed += 1 unless ok
    next if buckets.empty?
    last = buckets.last
    plain_lost += last.chunks
    plain_mapped += last.mapped
    plain_with_loss += 1 if last.chunks > 0
  end
  puts "  processes that stranded a chunk: #{plain_with_loss} of #{PLAIN_CHILDREN}#{plain_crashed > 0 ? " (#{plain_crashed} crashed)" : ""}"
  puts "  stranded: #{plain_lost} chunk(s) of #{plain_mapped} mapped"
  if plain_lost > 0
    puts "  rate: #{(plain_lost * 1000.0 / plain_mapped).round(2)} per 1000 mappings, #{(plain_lost * 128).round} KiB across the run"
    puts "  so the residual lives in the heap-growth regime, not in steady state"
  else
    puts "  nothing stranded: below 1 per #{plain_mapped} mappings in this regime too"
  end
  puts ""

  failures = [] of String
  if shipped_mapped < MIN_MAPPINGS
    failures << "the shipped arm mapped only #{shipped_mapped} chunks (want #{MIN_MAPPINGS}): it measured nothing"
  end
  if fast_rate <= MAX_PER_1000
    failures << "the fast arm stranded #{fast_rate.round(2)} per 1000 mappings (want above #{MAX_PER_1000}): " +
                "the workload no longer reaches the race, so the shipped arm's number means nothing"
  end
  if shipped_rate > MAX_PER_1000
    failures << "the shipped arm stranded #{shipped_rate.round(2)} per 1000 mappings (want at most #{MAX_PER_1000}): " +
                "chunks are leaving the list at a rate the latched mutator count was supposed to have closed"
  end
  unless failures.empty?
    failures.each { |f| puts "FAIL #{f}" }
    exit 1
  end
  puts "ok — shipped #{shipped_rate.round(3)} per 1000 mappings (cap #{MAX_PER_1000}) over #{shipped_mapped} mappings,"
  puts "     the pre-fix shape #{fast_rate.round(1)} per 1000 and #{(fast.last.bytes * 100.0 / fast.last.heap_bytes).round(1)}% of its heap stranded."
  exit 0
end

# ── child ────────────────────────────────────────────────────────────
heap.chunk_list_audit = true
# `--plain` is the churn reproducer's shape with nothing added: thread birth
# only, a heap that never grows past a few MB, and a process that lives for 240
# collections. It exists because that is the shape the one shipped sighting came
# from (1 run in 14, 2026-09-12), and a steady-state measurement cannot speak
# for a regime where the heap is still being built.
plain = ARGV.includes?("--plain")
if ARGV.includes?("--fast")
  # Half of the pre-fix shape: the mutator count is read per decision again, so
  # chunks leave the list at their old rate. The mark clear still walks the
  # index, so this measures the leak and not the use-after-free.
  heap.sweep_mutator_latch = false
end

# The denominator has to be driven. A first version churned threads and nothing
# else, and the shipped arm mapped 32 chunks in 1200 collections — so "nothing
# stranded in 90 000 collections" was really "nothing stranded in ~40 mappings",
# a bound worth nothing. The strand needs a *prepend*, and a prepend needs a
# mapping, so the workload has to keep mapping: a live set that grows for
# SAWTOOTH rounds and is then dropped whole, which makes the sweep release its
# chunks and the next rounds map them again.
every = ROUNDS // BUCKETS
round = 0
live = [] of Array(UInt8)
while round < ROUNDS
  round += 1
  born = [] of Thread
  # The prepend must come from a *mutator* racing the sweep's walk, not from the
  # thread that runs the collection — so the born threads are the allocators.
  # Each keeps its own, because a shared array pushed from eight threads is a
  # data race and this harness has no business having one.
  THREADS.times do
    born << Thread.new do
      next if plain
      mine = [] of Array(UInt8)
      ALLOC_PER_THREAD.times { mine << Array(UInt8).new(ALLOC_BYTES, 1_u8) }
      mine.size
    end
  end
  # The main thread owns the sawtooth: the heap grows for SAWTOOTH rounds and is
  # then dropped whole, so the sweep releases chunks and the rounds after it map
  # fresh ones.
  MAIN_PER_ROUND.times { live << Array(UInt8).new(ALLOC_BYTES, 2_u8) } unless plain
  GC.collect
  born.each(&.join)
  live.clear if round % SAWTOOTH == 0
  if heap.heap_size > HEAP_CAP
    puts "bucket #{round} #{heap.chunk_index_only_now} #{heap.chunk_index_only_now_bytes} #{heap.heap_size} #{heap.chunks_mapped}"
    STDOUT.flush
    break
  end
  if round % every == 0
    puts "bucket #{round} #{heap.chunk_index_only_now} #{heap.chunk_index_only_now_bytes} #{heap.heap_size} #{heap.chunks_mapped}"
    STDOUT.flush
  end
end
