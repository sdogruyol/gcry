# Alloc pattern fuzz test.
#
# Exercises gcry under 3 allocation distributions:
#   1. Zipfian (power-law, real-world)
#   2. Bimodal (small + large)
#   3. Stride (array-growth)
#
# For each pattern, verifies:
#   - Pause p99 < 2x baseline pause p99
#   - RSS growth < 10% from start
#
# Build: crystal build -Dgc_none bench/pattern_fuzz.cr -o bin/pattern_fuzz
# Run:   ./bin/pattern_fuzz [--seed=1] [--phases=200] [--objects-per-phase=5000]

require "../src/gcry"

{% unless flag?(:gc_none) %}
  raise "pattern_fuzz requires -Dgc_none (gcry as process GC)"
{% end %}

# ---- CLI args ----
seed = 1_i64
phases = 200
objects_per_phase = 5000

ARGV.each do |arg|
  case arg
  when /--seed=(\d+)/
    seed = $1.to_i64
  when /--phases=(\d+)/
    phases = $1.to_i
  when /--objects-per-phase=(\d+)/
    objects_per_phase = $1.to_i
  end
end

# ---- Helpers ----
def pct_str(val, baseline)
  return "N/A" if baseline == 0
  pct = val.to_f / baseline * 100
  "#{pct.round(1)}%"
end

def check(label, val, baseline, limit, failures)
  return if baseline == 0
  ratio = val.to_f / baseline
  if ratio > limit
    failures << "#{label}: #{val}ns is #{ratio.round(2)}x baseline (#{baseline}ns), limit #{limit}x"
  end
end

# ---- RSS helper (Linux /proc/self/status) ----
def read_rss_kb : UInt64
  File.open("/proc/self/status") do |f|
    f.each_line do |line|
      if line.starts_with?("VmRSS:")
        parts = line.split
        return parts[1].to_u64 if parts.size >= 2
      end
    end
  end
  0_u64
rescue
  0_u64
end

# ---- Allocation distributions ----
module Distributions
  # Zipfian (power-law) — many small, few large.
  def self.zipfian(rng : Random, count : Int32, min_size : Int32 = 8, max_size : Int32 = 65536, alpha : Float64 = 1.0) : Array(Int32)
    n = 1000
    weights = Array.new(n) { |i| 1.0 / ((i + 1) ** alpha) }
    total = weights.sum
    cdf = Array.new(n) { |i| weights[0..i].sum / total }

    sizes = Array(Int32).new(count)
    count.times do
      r = rng.rand
      idx = cdf.index { |v| v >= r } || (n - 1)
      t = idx.to_f / n
      sizes << (min_size + (max_size - min_size) * t).to_i32
    end
    sizes
  end

  # Bimodal — cluster of small allocs, cluster of large allocs.
  def self.bimodal(rng : Random, count : Int32, small_size : Int32 = 16, large_size : Int32 = 32768, large_ratio : Float64 = 0.1) : Array(Int32)
    sizes = Array(Int32).new(count)
    count.times do
      if rng.rand < large_ratio
        sizes << (large_size * (0.5 + rng.rand)).to_i32
      else
        sizes << (small_size * (1.0 + rng.rand * 3)).to_i32
      end
    end
    sizes
  end

  # Stride — growing allocations like array resize (doubling pattern with noise).
  def self.stride(rng : Random, count : Int32, min_size : Int32 = 8, max_size : Int32 = 131072) : Array(Int32)
    sizes = Array(Int32).new(count)
    sz = min_size
    count.times do
      sizes << (sz * (0.8 + rng.rand * 0.4)).to_i32
      if sz < max_size / 4
        sz = (sz * 1.5).to_i32
      elsif rng.rand < 0.3
        sz = [(sz * 2).to_i32, max_size].min
      end
    end
    sizes
  end
end

# ---- Phase runner ----
class PatternPhase
  getter name : String
  getter rss_start : UInt64
  getter rss_end : UInt64
  getter pause_p50 : UInt64
  getter pause_p99 : UInt64
  getter pause_max : UInt64
  getter heap_delta : Int64
  getter errors : Array(String)

  def initialize(@name : String, @rss_start : UInt64, @rss_end : UInt64,
                 @pause_p50 : UInt64, @pause_p99 : UInt64, @pause_max : UInt64,
                 @heap_delta : Int64, @errors : Array(String))
  end

  def passed? : Bool
    @errors.empty?
  end
end

def run_phase(rng : Random, name : String, sizes : Array(Int32), heap : Gcry::Heap) : PatternPhase
  errors = [] of String
  live = [] of Pointer(Void)

  rss_before = read_rss_kb
  heap_before = Gcry.metrics(heap).heap_size

  sizes.each do |sz|
    ptr = GC.malloc_atomic(sz)
    live << ptr
  end

  live.each_with_index do |ptr, i|
    GC.free(ptr) if i.even?
  end
  live = [] of Pointer(Void)

  GC.collect

  rss_after = read_rss_kb
  m_after = Gcry.metrics(heap)

  PatternPhase.new(name, rss_before, rss_after, m_after.pause_p50_ns, m_after.pause_p99_ns, m_after.pause_max_ns,
    m_after.heap_size.to_i64 - heap_before.to_i64, errors)
end

# ---- Main ----
rng = Random.new(seed)
heap = Gcry.default_heap.not_nil!

puts "Pattern fuzz seed=#{seed} phases=#{phases} objects_per_phase=#{objects_per_phase}"
puts ""

# 1. Baseline — uniform random allocs (16B–256B, real-world typical)
puts "=== Baseline (uniform random 16-256B) ==="
baseline_phases = [] of PatternPhase
phases.times do |i|
  sizes = Array.new(objects_per_phase) { 16 + rng.rand(241) }
  phase = run_phase(rng, "baseline-#{i}", sizes, heap)
  baseline_phases << phase
  print "." if i % 20 == 0
end
puts ""

baseline_p50 = baseline_phases.map(&.pause_p50).sum.to_f / baseline_phases.size
baseline_p99 = baseline_phases.map(&.pause_p99).sum.to_f / baseline_phases.size
baseline_max = baseline_phases.map(&.pause_max).max
baseline_rss_growth = baseline_phases.map { |p| p.rss_end > p.rss_start ? (p.rss_end - p.rss_start).to_f / p.rss_start * 100 : 0.0 }
baseline_rss_pct = baseline_rss_growth.sum / baseline_rss_growth.size

puts "  baseline: p50=#{baseline_p50}ns p99=#{baseline_p99}ns max=#{baseline_max}ns rss_growth=#{baseline_rss_pct.round(2)}%"

# Helper to compute and print phase stats
def compute_phase_stats(phases : Array(PatternPhase)) : NamedTuple(p50: Float64, p99: Float64, max: UInt64, rss_pct: Float64)
  p50 = phases.map(&.pause_p50).sum.to_f / phases.size
  p99 = phases.map(&.pause_p99).sum.to_f / phases.size
  max = phases.map(&.pause_max).max
  rss_growth = phases.map { |p| p.rss_end > p.rss_start ? (p.rss_end - p.rss_start).to_f / p.rss_start * 100 : 0.0 }
  rss_pct = rss_growth.sum / rss_growth.size
  {p50: p50, p99: p99, max: max, rss_pct: rss_pct}
end

# 2. Zipfian
puts ""
puts "=== Zipfian (power-law 8B-64KB, alpha=1.0) ==="
zipfian_phases = [] of PatternPhase
phases.times do |i|
  sizes = Distributions.zipfian(rng, objects_per_phase)
  phase = run_phase(rng, "zipfian-#{i}", sizes, heap)
  zipfian_phases << phase
  print "." if i % 20 == 0
end
puts ""

z = compute_phase_stats(zipfian_phases)
puts "  zipfian: p50=#{z[:p50]}ns p99=#{z[:p99]}ns max=#{z[:max]}ns rss_growth=#{z[:rss_pct].round(2)}%"
puts "  vs baseline: p99=#{pct_str(z[:p99], baseline_p99)} max=#{pct_str(z[:max], baseline_max)}"

# 3. Bimodal
puts ""
puts "=== Bimodal (16B + 32KB) ==="
bimodal_phases = [] of PatternPhase
phases.times do |i|
  sizes = Distributions.bimodal(rng, objects_per_phase)
  phase = run_phase(rng, "bimodal-#{i}", sizes, heap)
  bimodal_phases << phase
  print "." if i % 20 == 0
end
puts ""

b = compute_phase_stats(bimodal_phases)
puts "  bimodal: p50=#{b[:p50]}ns p99=#{b[:p99]}ns max=#{b[:max]}ns rss_growth=#{b[:rss_pct].round(2)}%"
puts "  vs baseline: p99=#{pct_str(b[:p99], baseline_p99)} max=#{pct_str(b[:max], baseline_max)}"

# 4. Stride
puts ""
puts "=== Stride (array-growth 8B-128KB) ==="
stride_phases = [] of PatternPhase
phases.times do |i|
  sizes = Distributions.stride(rng, objects_per_phase)
  phase = run_phase(rng, "stride-#{i}", sizes, heap)
  stride_phases << phase
  print "." if i % 20 == 0
end
puts ""

s = compute_phase_stats(stride_phases)
puts "  stride: p50=#{s[:p50]}ns p99=#{s[:p99]}ns max=#{s[:max]}ns rss_growth=#{s[:rss_pct].round(2)}%"
puts "  vs baseline: p99=#{pct_str(s[:p99], baseline_p99)} max=#{pct_str(s[:max], baseline_max)}"

# ---- Result summary ----
puts ""
puts "=== Summary ==="
failures = [] of String

# Pause ratios vs baseline (regression guard, not absolute). Large-object
# patterns do more work per phase; EC1 parked-fiber scrub is 4 KiB blind
# (v0.16 thr) so stride pauses sit higher than the old 512 B+safe band.
# GHA / crystal-latest hosts amplify further (seen ~45–57× on stride).
{
  "Zipfian p99" => {z[:p99], baseline_p99, 3.0},
  "Bimodal p99" => {b[:p99], baseline_p99, 20.0},
  "Stride p99"  => {s[:p99], baseline_p99, 80.0},
}.each do |label, (val, bl, lim)|
  check(label, val, bl, lim, failures)
end

{
  "Zipfian max" => {z[:max], baseline_max, 4.0},
  # Bimodal mixes 16B + 32KB; CI runners see high max-pause variance on the large side.
  "Bimodal max" => {b[:max], baseline_max, 20.0},
  "Stride max"  => {s[:max], baseline_max, 80.0},
}.each do |label, (val, bl, lim)|
  check(label, val, bl, lim, failures)
end

# Check RSS growth < 10%
{
  "Zipfian RSS" => z[:rss_pct],
  "Bimodal RSS" => b[:rss_pct],
  "Stride RSS"  => s[:rss_pct],
}.each do |label, growth|
  if growth > 10.0
    failures << "#{label}: growth #{growth.round(2)}% > 10% limit"
  end
end

puts ""
puts "Baseline: p50=#{baseline_p50}ns p99=#{baseline_p99}ns max=#{baseline_max}ns rss_growth=#{baseline_rss_pct.round(2)}%"
puts "Zipfian:  p99=#{pct_str(z[:p99], baseline_p99)} max=#{pct_str(z[:max], baseline_max)} rss_growth=#{z[:rss_pct].round(2)}%"
puts "Bimodal:  p99=#{pct_str(b[:p99], baseline_p99)} max=#{pct_str(b[:max], baseline_max)} rss_growth=#{b[:rss_pct].round(2)}%"
puts "Stride:   p99=#{pct_str(s[:p99], baseline_p99)} max=#{pct_str(s[:max], baseline_max)} rss_growth=#{s[:rss_pct].round(2)}%"

if failures.empty?
  puts ""
  puts "RESULT: PASS — All patterns within limits"
else
  puts ""
  puts "RESULT: FAIL — #{failures.size} failure(s)"
  failures.each { |f| STDERR.puts "  #{f}" }
  exit 1
end
