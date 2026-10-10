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
# Six arms. The natural event is rare on the shipped tree — about one run in
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
# use-after-free: the pool walk reading a chunk the sweep has unmapped. Now
# and then that is before the first bucket, and such a child leaves no rate to
# read — which the verdict read as a rate of zero, "the workload no longer
# reaches the race", a red with no defect behind it. Such a child is run
# again; three in a row is a real finding and fails.
FAST_ATTEMPTS = 3

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

def run_child(self_path : String, fast : Bool, plain : Bool = false) : {Array(Bucket), Bool}
  args = ["--child"]
  args << "--fast" if fast
  args << "--plain" if plain
  sink = IO::Memory.new
  env = plain ? {"CHUNK_DRIFT_ROUNDS" => PLAIN_ROUNDS.to_s} : nil
  status = Process.run(self_path, args, env: env,
    output: sink, error: Process::Redirect::Close)
  {parse_buckets(sink.to_s), status.success?}
end

# A window child: its buckets, whether it exited cleanly, and from its last
# `window` line how often the hook ran and how many chunks it mapped there.
def run_window_child(self_path : String, splice : Bool) : {Array(Bucket), Bool, UInt64, UInt64}
  args = ["--child", "--window"]
  args << "--no-splice" unless splice
  sink = IO::Memory.new
  status = Process.run(self_path, args, output: sink, error: Process::Redirect::Close)
  fired = 0_u64
  prepends = 0_u64
  sink.to_s.each_line do |line|
    f = line.split
    next unless f.size == 3 && f[0] == "window"
    fired = f[1].to_u64
    prepends = f[2].to_u64
  end
  {parse_buckets(sink.to_s), status.success?, fired, prepends}
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
  index_only : UInt64, cached : UInt64

# The window-free child: whether it exited cleanly, and its last `free` line —
# frees made in the window, trims that declined, chunks listed and not indexed
# and the reverse (summed over the audits), and the large cache's bytes.
def run_free_child(self_path : String) : {Bool, FreeReport?}
  sink = IO::Memory.new
  status = Process.run(self_path, ["--child", "--window-free"], output: sink, error: Process::Redirect::Close)
  report = nil
  sink.to_s.each_line do |line|
    f = line.split
    next unless f.size == 6 && f[0] == "free"
    report = FreeReport.new(f[1].to_u64, f[2].to_u64, f[3].to_u64, f[4].to_u64, f[5].to_u64)
  end
  {status.success?, report}
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
  fast_attempts = 1
  while fast.empty? && fast_attempts < FAST_ATTEMPTS
    fast, fast_ok = run_child(self_path, true)
    fast_attempts += 1
  end
  _, shipped_mapped = report("shipped — mutator count latched in the stop", shipped, shipped_ok)
  if fast_attempts > 1
    puts "fast arm: #{fast_attempts - 1} child(ren) crashed before the first bucket and were run again"
  end
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

  # The arms above sample the natural race, and on the shipped tree they find
  # nothing — which alone cannot tell "closed" from "not reached": the store
  # that dropped the prefix also measured 0 in 12.1 million mappings. These
  # two put a prepend between the after-world sweep's walk and its store in
  # every collection. The splice must keep every one; without it every one
  # strands, which is what proves the hook is in the window.
  puts "=== window — a chunk mapped between the after-world sweep's walk and its store, #{WINDOW_ROUNDS} collections ==="
  window, window_ok, window_fired, window_prepends = run_window_child(self_path, true)
  window_lost = window.empty? ? 0_u64 : window.last.chunks
  puts "  splice:    hook ran #{window_fired} time(s), mapped #{window_prepends} chunk(s) in the window, stranded #{window_lost}#{window_ok ? "" : " — the child crashed"}"
  control, control_ok, control_fired, control_prepends = run_window_child(self_path, false)
  control_lost = control.empty? ? 0_u64 : control.last.chunks
  puts "  no splice: hook ran #{control_fired} time(s), mapped #{control_prepends} chunk(s) in the window, stranded #{control_lost}#{control_ok ? "" : " — the child crashed"}"
  puts ""

  # The rebuild's other edge: a chunk *leaving* the list during the walk. A
  # trim's detach went back on the list in `kept` and was then released while
  # still listed; a trim now declines while the rebuild runs. The tree before
  # faults in the first collection.
  puts "=== window-free — a large block freed between the after-world sweep's walk and its store, #{WINDOW_ROUNDS} collections ==="
  free_ok, free_report = run_free_child(self_path)
  if r = free_report
    puts "  freed #{r.freed} in the window, #{r.declined} trim(s) declined; listed and not indexed #{r.list_only}, " \
         "indexed and not listed #{r.index_only}; large cache #{r.cached} B at the end#{free_ok ? "" : " — the child crashed"}"
  else
    puts "  no report — the child crashed before its first"
  end
  puts ""

  shipped_lost = shipped.empty? ? 0_u64 : shipped.last.chunks
  failures = [] of String
  if shipped_mapped < MIN_MAPPINGS
    failures << "the shipped arm mapped only #{shipped_mapped} chunks (want #{MIN_MAPPINGS}): it measured nothing"
  end
  if fast.empty?
    failures << "the fast arm crashed before its first bucket #{FAST_ATTEMPTS} times in a row: " +
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
  if window.empty? || !window_ok
    failures << "the window arm #{window.empty? ? "printed no bucket" : "crashed"}: it measured nothing"
  elsif window_prepends < WINDOW_MIN_PREPENDS
    failures << "the window arm mapped #{window_prepends} chunk(s) in the window (want at least #{WINDOW_MIN_PREPENDS}): " +
                "the hook no longer reaches the after-world store, so its zero means nothing"
  elsif window_lost > 0
    failures << "the window arm stranded #{window_lost} of the #{window_prepends} chunks mapped in the window: " +
                "the store is dropping what was prepended during the sweep's walk"
  end
  if control_lost == 0
    failures << "the window control stranded nothing of #{control_prepends} chunk(s) mapped in the window: " +
                "the window arm no longer reaches the race it exists to show closed"
  end
  if !free_ok || free_report.nil?
    failures << "the window-free arm crashed: a chunk freed during the sweep's walk was released while still on the list"
  elsif r = free_report
    if r.declined < WINDOW_MIN_PREPENDS
      failures << "the window-free arm's trims declined #{r.declined} time(s) (want at least #{WINDOW_MIN_PREPENDS}): " +
                  "its frees no longer reach the rebuild's window, so its clean exit means nothing"
    end
    if r.list_only > 0 || r.index_only > 0
      failures << "the window-free arm left the list and the index disagreeing " +
                  "(#{r.list_only} listed and not indexed, #{r.index_only} indexed and not listed)"
    end
    if r.cached >= WINDOW_FREE_BYTES
      failures << "the window-free arm ended with #{r.cached} B in the large cache: a declined trim parked its chunk past the collection"
    end
  end
  unless failures.empty?
    failures.each { |f| puts "FAIL #{f}" }
    exit 1
  end
  puts "ok — shipped: 0 stranded over #{shipped_mapped} mappings and 0 over #{plain_mapped} in short processes (cap 0);"
  puts "     window: 0 of #{window_prepends} prepends in the window stranded, #{control_lost} of #{control_prepends} without the splice;"
  puts "     window-free: #{free_report.try(&.freed)} large frees in the window, none released while still listed;"
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
  WINDOW_ROUNDS.times do |i|
    # Some garbage, so each sweep has something to reclaim.
    64.times { Array(UInt8).new(512, 3_u8) }
    GC.collect
    next unless (i + 1) % window_every == 0
    puts "bucket #{i + 1} #{heap.chunk_index_only_now} #{heap.chunk_index_only_now_bytes} #{heap.heap_size} #{heap.chunks_mapped}"
    puts "window #{WindowPrepend.fired} #{WindowPrepend.prepends}"
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
    puts "free #{WindowFree.freed} #{heap.relink_trims_declined} #{heap.chunk_list_only} #{heap.chunk_index_only} #{heap.large_free_bytes}"
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
    STDOUT.flush
    break
  end
  if round % every == 0
    puts "bucket #{round} #{heap.chunk_index_only_now} #{heap.chunk_index_only_now_bytes} #{heap.heap_size} #{heap.chunks_mapped}"
    STDOUT.flush
  end
end
