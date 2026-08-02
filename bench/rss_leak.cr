# RSS leak detection gate.
#
# Allocates, frees, collects in cycles and tracks RSS within this process.
# Warm-up cycles absorb heap/RSS ramp (empty-chunk retain, fragmentation).
# Gate samples only after warm-up: late-half median RSS must not grow >limit%
# vs early-half (leak signal). Absolute RSS and RSS/heap ratio are logged for
# humans but never compared to a committed cross-host baseline (CI ≠ macOS ≠ WSL).
#
# Usage:
#   crystal build -Dgc_none bench/rss_leak.cr -o bin/rss_leak
#   ./bin/rss_leak [--warmup=15] [--cycles=20] [--objects=5000] [--limit=10]
#
# Writes bench/trend.json (gitignored) for local/CI artifact trending.

require "../src/gcry"
require "json"

HEAP = Gcry.default_heap.not_nil!

warmup = 15
cycles = 20
objects = 5000
limit_pct = 10.0
ARGV.each do |arg|
  if arg.starts_with?("--warmup=")
    warmup = arg.lchop("--warmup=").to_i
  elsif arg.starts_with?("--cycles=")
    cycles = arg.lchop("--cycles=").to_i
  elsif arg.starts_with?("--objects=")
    objects = arg.lchop("--objects=").to_i
  elsif arg.starts_with?("--limit=")
    limit_pct = arg.lchop("--limit=").to_f
  end
end

def read_rss_kb : UInt64
  {% if flag?(:linux) %}
    File.open("/proc/self/status") do |f|
      f.each_line do |line|
        if line.starts_with?("VmRSS:")
          return line.split[1].to_u64
        end
      end
    end
  {% end %}
  0_u64
end

# One alloc/free/collect cycle. Returns {rss_kb, heap_size}.
def run_cycle(objects : Int32) : {UInt64, UInt64}
  live = [] of Void*
  objects.times { |i| live << HEAP.malloc(64 + (i % 256)) }

  # Free half — leave fragmentation pressure
  live.each_with_index { |p, i| HEAP.free(p) if i.even? }
  live.clear
  GC.collect
  GC.collect

  {read_rss_kb, HEAP.heap_size}
end

failures = [] of String
ratios = [] of Float64
rss_samples = [] of UInt64

puts "=== RSS leak detection (warmup=#{warmup}, cycles=#{cycles}, objects=#{objects}, limit=#{limit_pct}%) ==="

# Tiny priming alloc so the process GC heap exists before warm-up.
primed = [] of Void*
1000.times { primed << HEAP.malloc(128) }
primed.each { |p| HEAP.free(p) }
GC.collect
GC.collect

# Warm-up: same pressure as measured cycles; not sampled for the gate.
warmup.times { run_cycle(objects) }
GC.collect

rss_start = read_rss_kb
puts "  post-warmup RSS=#{rss_start} kB heap_size=#{HEAP.heap_size}"

cycles.times do |c|
  rss, hs = run_cycle(objects)
  ratio = hs > 0 ? (rss.to_f * 1024.0) / hs.to_f : 0.0
  ratios << ratio
  rss_samples << rss

  if c % 5 == 4 || c == cycles - 1
    puts "  cycle #{c + 1}: RSS=#{rss} kB heap=#{hs} ratio=#{ratio.round(2)}"
  end
end

rss_end = read_rss_kb
growth_pct = rss_start > 0 ? ((rss_end.to_f - rss_start.to_f) / rss_start.to_f) * 100.0 : 0.0

# Compare halves of *post-warmup* samples only (ramp already discarded).
half = cycles // 2
early = rss_samples[0...half]
late = rss_samples[half..]
early_med = early.sort[early.size // 2]
late_med = late.sort[late.size // 2]
late_growth = early_med > 0 ? ((late_med.to_f - early_med.to_f) / early_med.to_f) * 100.0 : 0.0
final_ratio = ratios[-1]

puts ""
puts "  RSS post-warmup→end: #{rss_start}→#{rss_end} kB (#{growth_pct.round(2)}%)"
puts "  early-median→late-median: #{early_med}→#{late_med} kB (#{late_growth.round(2)}%)"
puts "  final RSS/heap ratio=#{final_ratio.round(2)} (informational only)"

if late_growth > limit_pct
  failures << "RSS late-half grew #{late_growth.round(2)}% vs early-half (limit #{limit_pct}%)"
end

trend_path = File.join(__DIR__, "trend.json")
trend = {
  "timestamp"       => Time.utc.to_s,
  "rss_start_kb"    => rss_start,
  "rss_end_kb"      => rss_end,
  "growth_pct"      => growth_pct.round(2),
  "late_growth_pct" => late_growth.round(2),
  "rss_heap_ratio"  => final_ratio.round(3),
  "heap_size"       => HEAP.heap_size,
  "warmup"          => warmup,
  "cycles"          => cycles,
  "objects"         => objects,
  "limit_pct"       => limit_pct,
}
File.write(trend_path, trend.to_json)
puts "  wrote #{trend_path}"

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
