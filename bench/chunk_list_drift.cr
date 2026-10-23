# Does the chunk-list divergence accumulate with uptime, or is it one chunk?
#
# `map_chunk` prepends to `@chunks` under the list lock; the after-world sweep
# rebuilds `@chunks` from a walk it started earlier. Until 2026-10-09 a prepend
# that landed during that walk was not on the rebuilt list, and the chunk stayed
# in `@chunk_index`. It could not come back: the rebuild walks from `@chunks`,
# and nothing re-links a chunk the head no longer reaches. So the loss was
# permanent by construction — what was never measured was the **rate**, and the
# rate is what separates "128 KiB, once" from "an unbounded leak proportional to
# thread churn". The store now splices the prefix back
# (`Heap#publish_relinked_chunks`), and the gate is zero.
#
# Since 2026-09-13 the marks of such a chunk are cleared anyway (the clear walks
# the index), so this is an RSS question and not a soundness one. It is the last
# open piece of the 2026-08-23 live-object release
# (`bench/log/linux/2026-09-12-writer-frames/FINDINGS.md`).
#
# Seven arms. The natural event is rare on the shipped tree — about one run in
# fourteen of `make thread-churn-uaf`, then 0 in 12.1 million mappings — and a
# zero over a natural rate cannot tell "closed" from "not reached", so three
# arms act in the window on purpose:
#
#   shipped           the mutator count is latched, the churn workload
#   fast              `sweep_mutator_latch = false`: same race, higher rate,
#                     so the accumulation shape shows
#   startup regime    shipped, 24 short processes
#   window            a chunk mapped between the after-world sweep's walk and
#                     its store, every collection (`:before_relink_store`)
#   window control    the same with `chunk_list_splice = false`, the old store
#   window-free       a large block `GC.free`d in that window instead: its
#                     chunk must not leave the list under the rebuild
#   refused releases  shipped and fast with every empty-chunk release refused
#                     (`GCRY_REFUSE_EMPTY_RELEASE`): the shipped list must not
#                     close into a cycle, the fast one must, and hangs
#
# The fast arm restores half of the pre-fix shape, which is why it runs in a
# child process: that shape faulted 2 of 12 times on the churn reproducer, and a
# crash mid-measurement must cost the last bucket rather than the whole run.
# Buckets are printed as they complete for the same reason.
#
# It hangs as well, which is why every child runs under a deadline
# (`BoundedChild`). In that shape the list runs on into the sweep's unmap
# queue (the dropped chunk's `next` was pointed into it while the chunk stayed
# listed). When the flush then refuses to release a queued chunk — a mutator
# took a block from it, or holds it as a cursor (`Heap#refuse_occupied_release`,
# added 2026-09-14, after the latch) — it links the chunk back in front of
# `@chunks`, which already reaches it, and the list closes into a cycle. Every
# walk of it then runs forever: the collector's in
# `flush_pending_dormant_chunks`, a mutator's in `bitmap_take_pool_chunk`.
# Unbounded, one such child stalled the whole gate for 600 s in 0.39.0's
# overnight stress (2026-10-23); the tree before 0.39.0's third round hangs the
# same way. `bench/log/linux/2026-10-23-drift-stall/FINDINGS.md`.
#
# What the numbers mean: `chunk_index_only_now` is the count of chunks the index
# holds and the list does not, as of the last collection. Monotone, so the slope
# across buckets is chunks lost per collection, and each is `mapped_bytes` of
# retained memory that no sweep will ever visit.

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "chunk_list_drift requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% if flag?(:linux) %}
  lib LibDriftPtracer
    fun prctl(option : Int32, arg2 : UInt64, arg3 : UInt64, arg4 : UInt64, arg5 : UInt64) : Int32
  end
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
# The gate on both shipped arms: **zero**. It was 5 per 1000 while the race was
# open — a prepend landing between the after-world sweep's walk and its store
# was dropped from the list, rarely (0 of 12.1 million mappings, one sighting in
# 74 churn runs), and a cap of zero would have reddened CI on the real event.
# The store splices that prefix back now, so a stranded chunk is a defect; the
# window arms are what show the race is reached and closed rather than merely
# not sampled.
SHIPPED_MAX_STRANDED = 0_u64
# The pre-fix shape strands 80-181 per 1000. Below this the fast arm is not
# reaching the race, and the shipped arms' zero means nothing.
FAST_MIN_PER_1000 = 5.0
# The window arms: one thread, a collection a round, and in each the hook maps
# a chunk between the sweep's walk and its store. The object is kept, so its
# chunk is never reused and every collection maps afresh — about 12 MB over the
# arm.
WINDOW_ROUNDS =    300
WINDOW_BYTES  = 40_000
# Prepends in the window the arm must make for its zero to say anything. The
# hook reaches the window every collection, so this is well under what it gets.
WINDOW_MIN_PREPENDS = 100_u64
# The window-free arm frees a large block in that window instead — a chunk
# leaving the list under the rebuild rather than joining it. Past
# `LARGE_FREE_TRIM_SLACK` (2 MiB), with recycling off, so every free trims.
WINDOW_FREE_BYTES = 3_000_000_u64
# Below this the arm mapped too little to say anything. The first version of
# this harness churned threads and nothing else, mapped 32 chunks in 1200
# collections, and reported "nothing stranded in 90 000 collections" as if that
# were a bound. It was a bound on nothing, and this is the guard against
# publishing another one.
MIN_MAPPINGS = 5000_u64
# The fast arm crashes in a few children in a hundred (4 of 160 on 2026-09-25,
# all four in one burst of 20; rounds 200 to 1000), the pre-fix shape's
# use-after-free: the pool walk reading a chunk the sweep has unmapped. It
# also hangs, on a cycle in `@chunks` (above): 1 gate run in 6 on 0.39.0's
# night, and on a loaded host (four children at once) about half its children
# hang and most of the rest crash, on 0.39.0 and on the tree before it alike.
# Now and then either is before the first bucket, and such a child leaves no
# rate to read — which the verdict read as a rate of zero, "the workload no
# longer reaches the race", a red with no defect behind it. Such a child is
# run again; three in a row is a real finding and fails.
FAST_ATTEMPTS = 3
# Every child's deadline (`BoundedChild`). A child of 1200 rounds takes 10-20 s
# on a developer host, so this is several times that, and it grows with the
# rounds asked for (6000 by default). `BENCH_CHILD_TIMEOUT_S` sets it outright.
# A fast child that outlives it is the pre-fix shape hanging, counted with its
# crashes; any other child that does is a finding, and the gate fails with
# what its threads were doing.
CHILD_TIMEOUT = (ENV["BENCH_CHILD_TIMEOUT_S"]?.try(&.to_i?) || Math.max(120, ROUNDS // 10)).seconds
# The refused-releases arm. Every release the empty-chunk flush would make is
# refused (a budget no run spends), so every chunk the sweep queued for
# release is linked back in front of `@chunks`: on the shipped tree, where the
# sweep took it off the list before queueing it, that is one more chunk on the
# list; on the fast arm's, which still runs on into the queue, it is the
# cycle. Short children: a shipped one finishes in about 3 s, and the fast one
# closed the cycle in 8 of 8 children of 240 rounds outside the gate (6 of 6 of
# 1200), the latest between rounds 160 and 200.
REFUSE_ENV    = {"GCRY_REFUSE_EMPTY_RELEASE" => "1000000000"}
REFUSE_ROUNDS = 240
# The fast child there is expected to hang, so the gate waits this out on
# every run. One that does not hang finishes 240 rounds in 2-3 s, so a child
# still running at this is hung and not slow.
REFUSE_FAST_TIMEOUT = 20.seconds
# Tries for that child to hang before the arm calls the construction lost.
REFUSE_FAST_ATTEMPTS = 3
# Releases the shipped child must have refused for its clean exit to say the
# relinked chunks closed no cycle, rather than that there were none. It
# refused 6063 in its 240 rounds: a kept chunk that is still empty is queued
# again by the next major and refused again.
REFUSE_MIN = 1000_u64

record Bucket, round : Int32, chunks : UInt64, bytes : UInt64, heap_bytes : UInt64, mapped : UInt64

# The window arms' prepend, made on the collector's own thread between the
# after-world sweep's walk and its store. Class state and a proc that captures
# nothing: the process heap lives in libc memory the collector does not scan,
# so a closure only it held would be swept from under it.
module WindowPrepend
  @@kept = [] of Bytes
  @@limit = 0
  @@fired = 0_u64
  @@prepends = 0_u64

  # Room for every object up front, so the push in `call` maps nothing but
  # the object's own chunk.
  def self.reserve(limit : Int32) : Nil
    @@kept = Array(Bytes).new(limit)
    @@limit = limit
  end

  def self.call(stage : Symbol) : Nil
    return unless stage == :before_relink_store
    @@fired += 1
    return if @@kept.size >= @@limit
    heap = Gcry.default_heap
    before = heap.chunks_mapped
    # Large (past `LARGE_THRESHOLD`), and kept: a dead one would be cached by
    # the next sweep and taken again here, mapping nothing.
    @@kept << Bytes.new(WINDOW_BYTES)
    @@prepends += 1 if heap.chunks_mapped != before
  end

  def self.fired : UInt64
    @@fired
  end

  def self.prepends : UInt64
    @@prepends
  end
end

def parse_buckets(text : String) : Array(Bucket)
  buckets = [] of Bucket
  text.each_line do |line|
    next unless line.starts_with?("bucket ")
    f = line.split
    next unless f.size == 6
    buckets << Bucket.new(f[1].to_i, f[2].to_u64, f[3].to_u64, f[4].to_u64, f[5].to_u64)
  end
  buckets
end

# A child under the deadline: its buckets, and how it ended. stdout and stderr
# both come back in `output` — gcry's diagnostics included, which no reader
# here mistakes for a line of its own (`bucket`, `window`, `free`, `refused`).
def run_child(self_path : String, fast : Bool, plain : Bool = false,
              env : Hash(String, String) = {} of String => String,
              timeout : Time::Span = CHILD_TIMEOUT) : {Array(Bucket), BoundedChild::Result}
  args = ["--child"]
  args << "--fast" if fast
  args << "--plain" if plain
  env = env.merge({"CHUNK_DRIFT_ROUNDS" => PLAIN_ROUNDS.to_s}) if plain
  result = BoundedChild.run(self_path, args, env, timeout)
  {parse_buckets(result.output), result}
end

# How a child ended, for the reports: "crashed" or "hung", the latter for one
# `BoundedChild` killed at the deadline.
def death(result : BoundedChild::Result) : String
  result.timed_out ? "hung" : "crashed"
end

# A child that hung where a hang is a finding: the gate fails, and the log
# carries what `bench/stall_capture.sh` saw before the kill (every thread's
# state, and its stack where gdb may attach — the child consents, below).
def hang_finding(label : String, result : BoundedChild::Result, failures : Array(String)) : Nil
  return unless result.timed_out
  failures << "the #{label} child hung and was killed at its deadline; its threads are above"
  puts "--- the #{label} child, still running at its deadline:"
  puts result.capture || "(no capture)"
  puts ""
end

# A window child: its buckets, how it ended, and from its last `window` line
# how often the hook ran, how many chunks it mapped there, and how many large
# chunks' back-links the audits after its collections found not naming the
# chunk in front (`Heap#chunk_back_link_faults`, summed).
def run_window_child(self_path : String, splice : Bool) : {Array(Bucket), BoundedChild::Result, UInt64, UInt64, UInt64}
  args = ["--child", "--window"]
  args << "--no-splice" unless splice
  result = BoundedChild.run(self_path, args, timeout: CHILD_TIMEOUT)
  fired = 0_u64
  prepends = 0_u64
  link_faults = 0_u64
  result.output.each_line do |line|
    f = line.split
    next unless f.size == 4 && f[0] == "window"
    fired = f[1].to_u64
    prepends = f[2].to_u64
    link_faults = f[3].to_u64
  end
  {parse_buckets(result.output), result, fired, prepends, link_faults}
end

# The window-free arm's free: armed before each collection, held in class state
# so it is live when the collection marks, and handed to `GC.free` between the
# sweep's walk and its store — a second thread's free, as far as the rebuild
# can tell.
module WindowFree
  @@victim = Pointer(Void).null
  @@freed = 0_u64

  def self.arm(victim : Void*) : Nil
    @@victim = victim
  end

  def self.call(stage : Symbol) : Nil
    return unless stage == :before_relink_store
    victim = @@victim
    return if victim.null?
    @@victim = Pointer(Void).null
    @@freed += 1
    GC.free(victim)
  end

  def self.freed : UInt64
    @@freed
  end
end

record FreeReport, freed : UInt64, declined : UInt64, list_only : UInt64,
  index_only : UInt64, cached : UInt64, in_flight : UInt64

# The window-free child: how it ended, and its last `free` line — frees made
# in the window, trims that declined, chunks listed and not indexed and the
# reverse (summed over the audits), the large cache's bytes, and the listed
# chunks the audits excused as mid-publication
# (`Heap#chunk_list_publishing_excused`).
def run_free_child(self_path : String) : {BoundedChild::Result, FreeReport?}
  result = BoundedChild.run(self_path, ["--child", "--window-free"], timeout: CHILD_TIMEOUT)
  report = nil
  result.output.each_line do |line|
    f = line.split
    next unless f.size == 7 && f[0] == "free"
    report = FreeReport.new(f[1].to_u64, f[2].to_u64, f[3].to_u64, f[4].to_u64, f[5].to_u64, f[6].to_u64)
  end
  {result, report}
end

# The last `refused` line of a child: the empty-chunk releases its flushes
# refused so far (`Heap#release_refused_forced`).
def refused_count(result : BoundedChild::Result) : UInt64
  n = 0_u64
  result.output.each_line do |line|
    f = line.split
    n = f[1].to_u64 if f.size == 2 && f[0] == "refused"
  end
  n
end

def report(label : String, buckets : Array(Bucket), result : BoundedChild::Result) : {Float64, UInt64}
  ok = result.ok
  puts "=== #{label} ==="
  if buckets.empty?
    puts "  no buckets#{ok ? "" : " — the child #{death(result)} before the first one"}"
    puts ""
    return {0.0, 0_u64}
  end
  puts "  collections   off-list   retained B   heap B   chunks mapped"
  buckets.each do |b|
    puts "  #{b.round.to_s.rjust(11)}   #{b.chunks.to_s.rjust(8)}   #{b.bytes.to_s.rjust(10)}   #{b.heap_bytes.to_s.rjust(6)}   #{b.mapped.to_s.rjust(13)}"
  end
  last = buckets.last
  puts "  child #{death(result)} after bucket #{last.round} — the arm restores half the pre-fix shape" unless ok
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
      puts "  one bucket only#{ok ? "" : " — the child #{death(result)} before a second"}, so there is no slope to read"
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
  failures = [] of String
  shipped, shipped_run = run_child(self_path, false)
  fast, fast_run = run_child(self_path, true)
  fast_attempts = 1
  fast_hangs = fast_run.timed_out ? 1 : 0
  while fast.empty? && fast_attempts < FAST_ATTEMPTS
    fast, fast_run = run_child(self_path, true)
    fast_attempts += 1
    fast_hangs += 1 if fast_run.timed_out
  end
  _, shipped_mapped = report("shipped — mutator count latched in the stop", shipped, shipped_run)
  hang_finding("shipped", shipped_run, failures)
  if fast_attempts > 1
    puts "fast arm: #{fast_attempts - 1} child(ren) crashed or hung before the first bucket and were run again"
  end
  if fast_hangs > 0
    puts "fast arm: #{fast_hangs} child(ren) hung and were killed after #{CHILD_TIMEOUT.total_seconds.to_i} s — " \
         "the pre-fix shape hangs as it crashes, on a cycle in `@chunks` (the refused-releases arm forces it)"
  end
  fast_rate, fast_mapped = report("fast — `sweep_mutator_latch = false`, the pre-fix reads", fast, fast_run)

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
    buckets, run = run_child(self_path, false, plain: true)
    plain_crashed += 1 unless run.ok
    hang_finding("startup-regime", run, failures)
    next if buckets.empty?
    last = buckets.last
    plain_lost += last.chunks
    plain_mapped += last.mapped
    plain_with_loss += 1 if last.chunks > 0
  end
  puts "  processes that stranded a chunk: #{plain_with_loss} of #{PLAIN_CHILDREN}#{plain_crashed > 0 ? " (#{plain_crashed} crashed or hung)" : ""}"
  puts "  stranded: #{plain_lost} chunk(s) of #{plain_mapped} mapped"
  if plain_lost > 0
    puts "  rate: #{(plain_lost * 1000.0 / plain_mapped).round(2)} per 1000 mappings, #{(plain_lost * 128).round} KiB across the run"
    puts "  so the residual lives in the heap-growth regime, not in steady state"
  else
    puts "  nothing stranded: below 1 per #{plain_mapped} mappings in this regime too"
  end
  puts ""

  # The arms above sample the natural race, and on the shipped tree they find
  # nothing — which alone cannot tell "closed" from "not reached": the store
  # that dropped the prefix also measured 0 in 12.1 million mappings. These
  # two put a prepend between the after-world sweep's walk and its store in
  # every collection. The splice must keep every one; without it every one
  # strands, which is what proves the hook is in the window. The prepend also
  # writes the back-link of the chunk the walk started from, which the
  # rebuild has meanwhile put behind another (`ChunkHeader.large_prev`); the
  # store rewrites it, and the audits after each collection count the links
  # left wrong.
  puts "=== window — a chunk mapped between the after-world sweep's walk and its store, #{WINDOW_ROUNDS} collections ==="
  window, window_run, window_fired, window_prepends, window_link_faults = run_window_child(self_path, true)
  window_lost = window.empty? ? 0_u64 : window.last.chunks
  puts "  splice:    hook ran #{window_fired} time(s), mapped #{window_prepends} chunk(s) in the window, stranded #{window_lost}, " \
       "back-links wrong #{window_link_faults}#{window_run.ok ? "" : " — the child #{death(window_run)}"}"
  control, control_run, control_fired, control_prepends, _ = run_window_child(self_path, false)
  control_lost = control.empty? ? 0_u64 : control.last.chunks
  puts "  no splice: hook ran #{control_fired} time(s), mapped #{control_prepends} chunk(s) in the window, stranded #{control_lost}#{control_run.ok ? "" : " — the child #{death(control_run)}"}"
  puts ""
  hang_finding("window", window_run, failures)

  # The rebuild's other edge: a chunk *leaving* the list during the walk. A
  # trim's detach went back on the list in `kept` and was then released while
  # still listed; a trim now declines while the rebuild runs. The tree before
  # faults in the first collection.
  puts "=== window-free — a large block freed between the after-world sweep's walk and its store, #{WINDOW_ROUNDS} collections ==="
  free_run, free_report = run_free_child(self_path)
  if r = free_report
    puts "  freed #{r.freed} in the window, #{r.declined} trim(s) declined; listed and not indexed #{r.list_only}, " \
         "indexed and not listed #{r.index_only}; large cache #{r.cached} B at the end#{free_run.ok ? "" : " — the child #{death(free_run)}"}"
    puts "  excused: #{r.in_flight} listed chunk(s) whose mapper the stop caught between the list and the index"
  else
    puts "  no report — the child #{death(free_run)} before its first"
  end
  puts ""
  hang_finding("window-free", free_run, failures)

  # The fast arm's hang, forced, and the shipped tree's answer to the same
  # construction. With every empty-chunk release refused, every chunk the
  # sweep queued goes back in front of `@chunks`
  # (`flush_pending_empty_chunks_locked`). The shipped sweep took each off the
  # list before queueing it, so that is one chunk more on the list and the
  # child finishes. The fast arm's list still runs on into the queue, so the
  # relink closes it into a cycle and the child hangs in its next walk of it:
  # the stall of 2026-10-23, in every child instead of one gate run in six.
  # It must hang, or the shipped child's clean exit says nothing about
  # cycles; and the gate must come back from it, which is the deadline every
  # child runs under — without one, this arm hangs the gate.
  puts "=== refused releases — every empty-chunk release refused, #{REFUSE_ROUNDS} collections ==="
  refuse_env = REFUSE_ENV.merge({"CHUNK_DRIFT_ROUNDS" => REFUSE_ROUNDS.to_s})
  _, refuse_shipped = run_child(self_path, false, env: refuse_env)
  refused = refused_count(refuse_shipped)
  puts "  shipped: #{refuse_shipped.ok ? "exited cleanly" : death(refuse_shipped)}, #{refused} release(s) refused"
  refuse_tries = 0
  refuse_fast_hung = false
  while !refuse_fast_hung && refuse_tries < REFUSE_FAST_ATTEMPTS
    _, run = run_child(self_path, true, env: refuse_env, timeout: REFUSE_FAST_TIMEOUT)
    refuse_tries += 1
    refuse_fast_hung = run.timed_out
    ended = run.timed_out ? "hung, killed after #{REFUSE_FAST_TIMEOUT.total_seconds.to_i} s" : run.ok ? "exited cleanly" : "crashed"
    puts "  fast:    #{ended}, #{refused_count(run)} release(s) refused by its last bucket"
  end
  puts ""
  hang_finding("refused-releases shipped", refuse_shipped, failures)

  shipped_lost = shipped.empty? ? 0_u64 : shipped.last.chunks
  if shipped_mapped < MIN_MAPPINGS
    failures << "the shipped arm mapped only #{shipped_mapped} chunks (want #{MIN_MAPPINGS}): it measured nothing"
  end
  if fast.empty?
    failures << "the fast arm crashed or hung before its first bucket #{FAST_ATTEMPTS} times in a row: " +
                "it no longer lives long enough to measure anything"
  elsif fast_rate <= FAST_MIN_PER_1000
    failures << "the fast arm stranded #{fast_rate.round(2)} per 1000 mappings (want above #{FAST_MIN_PER_1000}): " +
                "the workload no longer reaches the race, so the shipped arm's number means nothing"
  end
  if shipped_lost > SHIPPED_MAX_STRANDED
    failures << "the shipped arm stranded #{shipped_lost} of #{shipped_mapped} chunks mapped (want #{SHIPPED_MAX_STRANDED}): " +
                "chunks are leaving the list"
  end
  if plain_lost > SHIPPED_MAX_STRANDED
    failures << "the startup-regime arm stranded #{plain_lost} of #{plain_mapped} chunks mapped (want #{SHIPPED_MAX_STRANDED}): " +
                "chunks are leaving the list"
  end
  if window_run.timed_out
    # Its own finding, with its threads, above (`hang_finding`).
  elsif window.empty? || !window_run.ok
    failures << "the window arm #{window.empty? ? "printed no bucket" : "crashed"}: it measured nothing"
  elsif window_prepends < WINDOW_MIN_PREPENDS
    failures << "the window arm mapped #{window_prepends} chunk(s) in the window (want at least #{WINDOW_MIN_PREPENDS}): " +
                "the hook no longer reaches the after-world store, so its zero means nothing"
  elsif window_lost > 0
    failures << "the window arm stranded #{window_lost} of the #{window_prepends} chunks mapped in the window: " +
                "the store is dropping what was prepended during the sweep's walk"
  end
  if window_link_faults > 0
    failures << "the window arm left #{window_link_faults} large chunk back-link(s) not naming the chunk in front: " +
                "the store no longer rewrites the walk head's link the prepend overwrote"
  end
  if control_lost == 0
    failures << "the window control stranded nothing of #{control_prepends} chunk(s) mapped in the window: " +
                "the window arm no longer reaches the race it exists to show closed"
  end
  if free_run.timed_out
    # As the window arm's.
  elsif !free_run.ok || free_report.nil?
    failures << "the window-free arm crashed: a chunk freed during the sweep's walk was released while still on the list"
  elsif r = free_report
    if r.declined < WINDOW_MIN_PREPENDS
      failures << "the window-free arm's trims declined #{r.declined} time(s) (want at least #{WINDOW_MIN_PREPENDS}): " +
                  "its frees no longer reach the rebuild's window, so its clean exit means nothing"
    end
    # Not counted here: a chunk whose mapper the stop *suspended* between
    # `map_chunk`'s list publish and its index insert — in flight, harmless,
    # and excused by the audit (`r.in_flight`, printed above). A mapper the
    # stop left running still counts: it is inserting into the index under
    # the collector's unlocked reads. This arm's one CI red (job 114713693560)
    # came from that: the idle thread, born at the end of the first
    # collection, mapped its first chunk as the second stopped the world, and
    # was exempt from the stop signal from birth (now only once born, as the
    # Monitor is only once in its loop). Suspended there instead, it is caught
    # mid-publication in 38 of 1000 children, every time inside
    # `index_insert_locked` before the radix entries were written.
    if r.list_only > 0 || r.index_only > 0
      failures << "the window-free arm left the list and the index disagreeing " +
                  "(#{r.list_only} listed and not indexed, #{r.index_only} indexed and not listed)"
    end
    if r.cached >= WINDOW_FREE_BYTES
      failures << "the window-free arm ended with #{r.cached} B in the large cache: a declined trim parked its chunk past the collection"
    end
  end
  if refuse_shipped.timed_out
    # As the window arm's: a cycle on the shipped list, most likely.
  elsif !refuse_shipped.ok
    failures << "the refused-releases shipped child crashed: a refused chunk linked back in front of `@chunks` broke the list"
  elsif refused < REFUSE_MIN
    failures << "the refused-releases shipped child refused #{refused} release(s) (want at least #{REFUSE_MIN}): " +
                "it queued too little for its clean exit to say anything"
  end
  unless refuse_fast_hung
    failures << "the refused-releases fast child did not hang in #{REFUSE_FAST_ATTEMPTS} tries: the construction " +
                "no longer closes the pre-fix shape's list into a cycle, so the shipped child's clean exit means nothing"
  end
  unless failures.empty?
    failures.each { |f| puts "FAIL #{f}" }
    exit 1
  end
  puts "ok — shipped: 0 stranded over #{shipped_mapped} mappings and 0 over #{plain_mapped} in short processes (cap 0);"
  puts "     window: 0 of #{window_prepends} prepends in the window stranded and no back-link left wrong, " \
       "#{control_lost} of #{control_prepends} stranded without the splice;"
  puts "     window-free: #{free_report.try(&.freed)} large frees in the window, none released while still listed;"
  puts "     refused releases: #{refused} chunk(s) back on the shipped list and no cycle; the pre-fix shape's hung, and was killed;"
  puts "     the pre-fix shape #{fast_rate.round(1)} per 1000 and #{(fast.last.bytes * 100.0 / fast.last.heap_bytes).round(1)}% of its heap stranded."
  exit 0
end

# ── child ────────────────────────────────────────────────────────────
# Traceable by any process, so `bench/stall_capture.sh` can attach gdb to a
# hung child under Ubuntu's default `ptrace_scope=1`. Without it the one stall
# this gate has had (0.39.0's overnight run, 2026-10-23: a `--fast` child, two
# threads spinning, 600 s) left nothing but thread states.
{% if flag?(:linux) %}
  LibDriftPtracer.prctl(0x59616d61, UInt64::MAX, 0, 0, 0) # PR_SET_PTRACER, ANY
{% end %}
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

# `--window`: one thread — so the latch reads single-mutator and every
# collection takes the after-world sweep that relinks — and the hook maps a
# chunk on the collector's thread between that sweep's walk and its store.
# `--no-splice` publishes the rebuild the way it was published before.
if ARGV.includes?("--window")
  heap.chunk_list_splice = false if ARGV.includes?("--no-splice")
  # Collections the arm does not ask for run the hook too; past this it stops
  # mapping rather than growing the array, which would map chunks of its own.
  WindowPrepend.reserve(WINDOW_ROUNDS * 2)
  heap.post_stw_hook = ->(stage : Symbol) { WindowPrepend.call(stage) }
  window_every = WINDOW_ROUNDS // BUCKETS
  link_faults = 0_u64
  WINDOW_ROUNDS.times do |i|
    # Some garbage, so each sweep has something to reclaim.
    64.times { Array(UInt8).new(512, 3_u8) }
    GC.collect
    link_faults &+= heap.chunk_back_link_faults
    next unless (i + 1) % window_every == 0
    puts "bucket #{i + 1} #{heap.chunk_index_only_now} #{heap.chunk_index_only_now_bytes} #{heap.heap_size} #{heap.chunks_mapped}"
    puts "window #{WindowPrepend.fired} #{WindowPrepend.prepends} #{link_faults}"
    STDOUT.flush
  end
  exit 0
end

# `--window-free`: one thread again, and the hook frees the large block armed
# before the collection in the same window. Recycling off, so every free past
# `LARGE_FREE_TRIM_SLACK` trims rather than waiting on a budget.
if ARGV.includes?("--window-free")
  heap.large_recycle = false
  heap.post_stw_hook = ->(stage : Symbol) { WindowFree.call(stage) }
  free_every = WINDOW_ROUNDS // BUCKETS
  WINDOW_ROUNDS.times do |i|
    WindowFree.arm(GC.malloc_atomic(WINDOW_FREE_BYTES))
    GC.collect
    next unless (i + 1) % free_every == 0
    puts "free #{WindowFree.freed} #{heap.relink_trims_declined} #{heap.chunk_list_only} #{heap.chunk_index_only} #{heap.large_free_bytes} #{heap.chunk_list_publishing_excused}"
    STDOUT.flush
  end
  exit 0
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
    puts "refused #{heap.release_refused_forced}"
    STDOUT.flush
    break
  end
  if round % every == 0
    puts "bucket #{round} #{heap.chunk_index_only_now} #{heap.chunk_index_only_now_bytes} #{heap.heap_size} #{heap.chunks_mapped}"
    # The refused-releases arm's count (`GCRY_REFUSE_EMPTY_RELEASE`), 0 elsewhere.
    puts "refused #{heap.release_refused_forced}"
    STDOUT.flush
  end
end
