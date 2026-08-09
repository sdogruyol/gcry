# STW root-scan lag pause guard.
#
# `GCRY_SOUND=1` sets `stw_multi_stack_lag = 0` and `stw_multi_pthread_lag = 0`
# (src/gcry/gc_override.cr, apply_sound_profile). Measured 2026-08-06: that pair
# is the *entire* pause cost of the sound profile — 19× at Kemal EC4
# (7.2 → 141.7 ms) and 14.5× on a fat app at EC1 once its heap passes ~60 MiB
# (17 → 213 ms), while the other five root-completeness heuristics stay within
# ±6% on every workload measured. See ROADMAP "Cheap root scan at scale" and
# `bench/log/linux/2026-08-06-085309-root-phase/FINDINGS.md`.
#
# Nothing in CI looked at pause under that profile — the sound correctness suite
# runs, and passes, at any pause. This closes that hole.
#
# What it reproduces, and what it does not:
#
#   `stw_multi_stack_lag = 0` makes `fiber_stack_scan_top` return `guard` for
#   every *parked* fiber under multi-mutator STW, so each collect scans the full
#   guard→bottom span (~8 MiB/fiber) instead of a LAG window. That needs only
#   >2 live OS threads and a parked fiber population — no preview_mt, no EC — so
#   it reproduces on a stock CI runner. The instrument parks worker threads on a
#   blocking pipe read to clear `multi_mutator_threads?` (>2).
#
#   `stw_multi_pthread_lag = 0` only bites when a suspended thread's SP sits
#   *off* its own pthread mapping — i.e. on a fiber stack, which means EC /
#   preview_mt. It is reported here for completeness but is expected to be flat
#   without EC; it is the +64% half, not the +1802% half.
#
# Methodology carried over from bench/sound_profile_ab.sh FINDINGS: configs are
# interleaved round-robin and the order is rotated each round, because blocked
# execution and fixed within-round order are *bias*, not variance — more rounds
# never remove them.
#
# Build: crystal build -Dgc_none bench/stw_lag_pause.cr -o bin/stw_lag_pause
# Run:   ./bin/stw_lag_pause [--fibers=32] [--rounds=5] [--max-ratio=30]
#        GCRY_SOUND=1 ./bin/stw_lag_pause   # asserts the profile *does* set 0/0
#
# Two assertions, both host-independent:
#   1. The lags the process booted with match GCRY_SOUND — non-zero without it,
#      zero with it. Fires if sound-by-default, or a lag default of 0, is ever
#      reintroduced before the cheap root scan lands.
#   2. The lag-0 pause penalty is at most --max-ratio× the tuned path. Upper
#      bound only: if the root scan is made cheap enough that lag 0 is
#      affordable, the ratio collapses toward 1 and this must pass, not fail.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  raise "stw_lag_pause requires -Dgc_none (gcry as process GC)"
{% end %}

HEAP = Gcry.default_heap.not_nil!

# Read before anything mutates them — locals, not constants, because Crystal
# initialises a constant at its first *use*, which here is after the A/B has
# already written the knobs.
boot_stack_lag = HEAP.stw_multi_stack_lag
boot_pthread_lag = HEAP.stw_multi_pthread_lag

# ---- CLI ----
# The ratio is not a universal constant — it falls as the fiber population
# shrinks, because the fiber-count-independent part of roots_ns (~20 ms here)
# dilutes it. 32 fibers reproduces 15× against the 19× seen at Kemal EC4, in
# ~8 s. Changing --fibers or --live-mb moves the ratio and invalidates
# --max-ratio; re-measure before retuning either.
fibers = 32
threads_n = 3
dirty_kb = 256
live_mb = 4
rounds = 5
max_ratio = 30.0
# Bound to use when the low-water skip is not available (see below): the old,
# pre-fix cost is the correct expectation there, not a regression.
max_ratio_nolw = 30.0

ARGV.each do |arg|
  case arg
  when /--fibers=(\d+)/            then fibers = $1.to_i
  when /--threads=(\d+)/           then threads_n = $1.to_i
  when /--dirty-kb=(\d+)/          then dirty_kb = $1.to_i
  when /--live-mb=(\d+)/           then live_mb = $1.to_i
  when /--rounds=(\d+)/            then rounds = $1.to_i
  when /--max-ratio-nolw=([\d.]+)/ then max_ratio_nolw = $1.to_f
  when /--max-ratio=([\d.]+)/      then max_ratio = $1.to_f
  end
end

# Defaults captured before anything mutates them, so a run under GCRY_SOUND=1
# still A/Bs against the tuned lags rather than against 0/0.
TUNED_STACK_LAG   = 256_u64 * 1024
TUNED_PTHREAD_LAG = 256_u64 * 1024

record Config, key : String, stack_lag : UInt64, pthread_lag : UInt64

CONFIGS = [
  Config.new("tuned", TUNED_STACK_LAG, TUNED_PTHREAD_LAG),
  Config.new("stack_lag0", 0_u64, TUNED_PTHREAD_LAG),
  Config.new("sound", 0_u64, 0_u64),
]

def ns_to_ms(ns : UInt64 | Float64) : Float64
  ns.to_f / 1_000_000.0
end

def median(xs : Array(Float64)) : Float64
  return 0.0 if xs.empty?
  s = xs.sort
  n = s.size
  n.odd? ? s[n // 2] : (s[n // 2 - 1] + s[n // 2]) / 2.0
end

# Walk the fiber stack down `kb`, dirtying one byte per page on the way. Parked
# fibers keep the pages resident, so the lag-0 scan reads real garbage rather
# than a shared zero page — that is the shape the server workloads have.
@[NoInline]
def dirty_stack(remaining_kb : Int32) : Int32
  buf = uninitialized UInt8[4096]
  buf[0] = (remaining_kb & 0xff).to_u8
  buf[2048] = (remaining_kb & 0x7f).to_u8
  return buf[0].to_i if remaining_kb <= 4
  buf[0].to_i &+ dirty_stack(remaining_kb - 4)
end

puts "=== STW lag pause guard ==="
puts "fibers=#{fibers} threads=#{threads_n} dirty=#{dirty_kb}KiB live=#{live_mb}MiB rounds=#{rounds}"
puts ""

# ── Park OS threads so multi_mutator_threads? (>2) holds ─────────────────
# A blocking pipe read parks the thread in the kernel with its SP inside its own
# pthread mapping — no scheduler needed, so this works in a non-MT build.
pipe_fds = uninitialized Int32[2]
raise "pipe() failed" unless LibC.pipe(pipe_fds) == 0

parked = [] of Thread
threads_n.times do
  parked << Thread.new do
    buf = uninitialized UInt8[1]
    # STW suspends via SIGPWR, which makes the blocking read return EINTR. Without
    # the retry the worker exits at the first collect, thread count falls back to
    # 1, `multi_mutator_threads?` goes false and the lag knobs are inert — the
    # instrument then measures nothing and reports a flat 1.0× ratio.
    loop do
      n = LibC.read(pipe_fds[0], buf.to_unsafe, 1_u64)
      break if n >= 0
      break unless Errno.value == Errno::EINTR
    end
  end
end

# Give them time to reach the read; then count what STW will actually see.
thread_count = 0
20.times do
  thread_count = 0
  Thread.unsafe_each { thread_count += 1 }
  break if thread_count > 2
  sleep 20.milliseconds
end
puts "threads visible to STW: #{thread_count} (multi_mutator=#{thread_count > 2})"
if thread_count <= 2
  STDERR.puts "FAIL: only #{thread_count} threads — the lag knobs are inert, nothing was measured"
  exit 1
end

# ── Park a fiber population with dirty stacks ────────────────────────────
ready = Channel(Nil).new(fibers)
park = Channel(Nil).new
fibers.times do
  spawn do
    dirty_stack(dirty_kb)
    ready.send(nil)
    park.receive
  end
end
fibers.times { ready.receive }

fiber_count = 0
Fiber.unsafe_each { fiber_count += 1 }
puts "fibers visible to STW: #{fiber_count}"
puts ""

# ── Live set so mark has real work ───────────────────────────────────────
HEAP.nursery_enabled = false
HEAP.incremental_auto = false
old_threshold = HEAP.gc_threshold
HEAP.gc_threshold = UInt64::MAX

live = [] of Void*
allocated = 0_u64
target = live_mb.to_u64 * 1024 * 1024
while allocated < target
  live << HEAP.malloc(4096)
  allocated += 4096_u64
end

# Pause is the headline, but roots_ns is where the lag actually lands
# (scan_all_fiber_roots is inside it, scrub excluded) — reporting both keeps the
# guard readable against bench/root_phase_ab.sh, which ranks on the same phase.
def measure(cfg : Config) : {Float64, Float64, UInt64}
  HEAP.stw_multi_stack_lag = cfg.stack_lag
  HEAP.stw_multi_pthread_lag = cfg.pthread_lag
  HEAP.reset_pause_stats
  GC.collect
  # low_water_skips resets every collect, so it has to be read here, per config.
  # Reading it once after an interleaved multi-config run reports whichever
  # config happened to collect last — which is how the first version of this
  # printed 2 skips for a lag-0 run that had made 34.
  {ns_to_ms(Gcry.pause_stats.max_ns), ns_to_ms(HEAP.last_phase_roots_ns),
   HEAP.low_water_skips}
end

# Warm up every config once — the first lag-0 collect faults the untouched half
# of each fiber span, and charging that one-off to the config would inflate it.
CONFIGS.each { |c| measure(c) }

samples = Hash(String, Array(Float64)).new { |h, k| h[k] = [] of Float64 }
roots = Hash(String, Array(Float64)).new { |h, k| h[k] = [] of Float64 }
skips = Hash(String, Array(UInt64)).new { |h, k| h[k] = [] of UInt64 }

rounds.times do |r|
  # Round-robin *and* rotate: whichever config runs first in a fixed order
  # absorbs the round's warm-up and comes out slow. Rotating cancels it.
  CONFIGS.rotate(r % CONFIGS.size).each do |cfg|
    pause_ms, roots_ms, lw_skips = measure(cfg)
    samples[cfg.key] << pause_ms
    roots[cfg.key] << roots_ms
    skips[cfg.key] << lw_skips
  end
end

# The knobs are inert unless >2 threads survive to the *end*. A worker that died
# mid-run (STW delivers SIGPWR; a naive blocking read returns EINTR and exits)
# silently turns every config into the same measurement.
final_threads = 0
Thread.unsafe_each { final_threads += 1 }
if final_threads <= 2
  STDERR.puts "FAIL: thread count fell to #{final_threads} during the run — the lag knobs went inert, nothing was measured"
  exit 1
end

HEAP.stw_multi_stack_lag = boot_stack_lag
HEAP.stw_multi_pthread_lag = boot_pthread_lag
HEAP.gc_threshold = old_threshold

puts "=== Pause per collect (ms, median of #{rounds} interleaved rounds) ==="
meds = {} of String => Float64
CONFIGS.each do |cfg|
  xs = samples[cfg.key]
  med = median(xs)
  meds[cfg.key] = med
  puts "  %-11s pause median=%8.2f  min=%8.2f  max=%8.2f   roots median=%8.2f" %
       [cfg.key, med, xs.min, xs.max, median(roots[cfg.key])]
end
puts ""

# Whether the low-water skip engaged at all is not visible from the pause
# numbers: it needs multi_mutator_threads? (> 2 threads), which a real app can
# sit right on the boundary of. A ratio near 1.0 could mean "the skip worked"
# or "the skip never ran and lag 0 was cheap here anyway" — these separate them.
puts "=== Low-water skip (median skips per collect, by config) ==="
CONFIGS.each do |cfg|
  xs = skips[cfg.key].map(&.to_f)
  puts "  %-11s skips median=%6.0f" % [cfg.key, median(xs)]
end
lw_on = HEAP.stack_low_water_scan && Gcry::Platform.pagemap_available?
if lw_on && CONFIGS.all? { |c| skips[c.key].sum == 0 }
  puts "  NOTE skip is enabled and pagemap readable, yet it never fired in any"
  puts "       config — the ratios below say nothing about it."
end
# The default path can only skip what a fiber never wrote inside its lag window,
# so `tuned` here is a function of --dirty-kb against the 256 KiB lag, not of the
# collector: 16 KiB dirty → 34 skips, 256 KiB → 2, 1024 KiB → 2. Real workloads
# do not dirty uniformly, which is why the default path skips heavily on Kemal
# EC4 and the fat app and barely at all here.
if lw_on
  rel = dirty_kb < 256 ? "below" : (dirty_kb == 256 ? "equal to" : "above")
  puts "  (--dirty-kb=#{dirty_kb} is #{rel} the 256 KiB lag — that, not the"
  puts "   collector, sets how much `tuned` has left to skip)"
end
puts ""

tuned = meds["tuned"]
failures = [] of String

# 1. The knobs the process actually booted with. An absolute ms budget was the
#    obvious guard here and is the wrong one: it is host-dependent, needs enough
#    headroom on a shared runner to stop flaking, and by then it no longer
#    separates 30 ms from 480 ms reliably. The config assertion catches the same
#    regression — sound-by-default, or a lag default of 0, reintroduced before
#    the cheap root scan lands — exactly and without flake.
want_sound = ENV["GCRY_SOUND"]? == "1"
{stack: boot_stack_lag, pthread: boot_pthread_lag}.each do |name, lag|
  if want_sound && lag != 0
    failures << "GCRY_SOUND=1 but #{name} lag booted at #{lag}, expected 0"
    puts "  FAIL boot #{name} lag: #{lag} (expected 0 under GCRY_SOUND=1)"
  elsif !want_sound && lag == 0
    failures << "default boot has #{name} lag 0 — the pause trap is now the default path"
    puts "  FAIL boot #{name} lag: 0 (expected non-zero without GCRY_SOUND)"
  else
    puts "  PASS boot #{name} lag: #{lag}"
  end
end

# 1b. The skip on the *default* path has to be exercised, not just present.
#     Every assertion above and below is about lag 0; the default path could
#     regress to the pre-2026-08-09 behaviour (skip gated on lag == 0) and this
#     instrument would stay green, because at --dirty-kb=256 the lag window is
#     fully written and `tuned` has nothing to skip either way.
#
#     So: only when the run is set up to give the default path something to skip
#     (dirty depth below the lag) is `tuned` required to actually skip. Silent
#     otherwise — this is a gate, not a preference for one --dirty-kb.
if lw_on && dirty_kb < 256 && !want_sound
  tuned_skips = skips["tuned"].sum
  if tuned_skips == 0
    failures << "default path never skipped with --dirty-kb=#{dirty_kb} below the 256 KiB lag"
    puts "  FAIL default-path skip: 0 skips across #{rounds} rounds"
  else
    puts "  PASS default-path skip: tuned skipped in #{skips["tuned"].count(&.>(0))}/#{rounds} rounds"
  end
end

# 2. Characterise the known trap. Upper bound only — if the root scan is ever
#    made cheap enough that lag 0 is affordable, the ratio collapses toward 1
#    and this must pass, not fail.
#
#    A tightened bound (the low-water skip took this from ~14× to ~1×) must not
#    make CI depend on an environment capability. The skip needs
#    /proc/self/pagemap, which a hardened kernel or a restricted container can
#    refuse; the collector then falls back to the full scan — correct, but back
#    at ~14×. Asserting the tight bound there would fail the build for something
#    that is not a regression, so the bound relaxes to --max-ratio-nolw and says
#    why, loudly enough that nobody reads the pass as the fast path working.
low_water = {% if flag?(:linux) %}
              HEAP.stack_low_water_scan && Gcry::Platform.pagemap_available?
            {% else %}
              false
            {% end %}
effective_max = low_water ? max_ratio : max_ratio_nolw
unless low_water
  puts "  NOTE low-water skip unavailable here (pagemap unreadable, or disabled)."
  puts "       Ratio bound relaxed #{max_ratio}× → #{effective_max}×; the scan is"
  puts "       correct but back on the full guard→bottom path."
end

if tuned > 0
  CONFIGS.each do |cfg|
    next if cfg.key == "tuned"
    ratio = meds[cfg.key] / tuned
    if ratio > effective_max
      failures << "#{cfg.key} pause ratio #{ratio.round(2)}× > #{effective_max}×"
      puts "  FAIL #{cfg.key} ratio: #{ratio.round(2)}× > #{effective_max}×"
    else
      puts "  PASS #{cfg.key} ratio: #{ratio.round(2)}× <= #{effective_max}×" \
           "#{low_water ? " (low-water on)" : ""}"
    end
  end
else
  puts "  WARN tuned median is 0 — skipping ratio checks"
end

puts ""
puts "=== Result ==="
if failures.empty?
  puts "PASS"
  exit 0
else
  puts "FAIL — #{failures.size} failure(s)"
  failures.each { |f| puts "  #{f}" }
  exit 1
end
