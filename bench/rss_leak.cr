# RSS / heap leak detection gate.
#
# Allocates, frees, collects in cycles and tracks RSS + heap_size.
# Warm-up cycles absorb heap/RSS ramp (empty-chunk retain, fragmentation).
# Gate samples only after warm-up:
#   - Primary: late-half median heap_size must not grow >limit% vs early-half
#   - Secondary: RSS late-half growth must not exceed rss_limit% (looser —
#     Linux reclaim / DONTNEED re-fault is noisy under CI load)
#
# Usage:
#   crystal build -Dgc_none bench/rss_leak.cr -o bin/rss_leak
#   ./bin/rss_leak [--warmup=15] [--cycles=20] [--objects=5000] [--limit=10] [--rss-limit=25]
#
# Writes bench/trend.json (gitignored) for local/CI artifact trending.

require "../src/gcry"
require "./bench_rss"
require "json"

HEAP = Gcry.default_heap.not_nil!

warmup = 15
cycles = 20
objects = 5000
limit_pct = 10.0
rss_limit_pct = 25.0
ARGV.each do |arg|
  if arg.starts_with?("--warmup=")
    warmup = arg.lchop("--warmup=").to_i
  elsif arg.starts_with?("--cycles=")
    cycles = arg.lchop("--cycles=").to_i
  elsif arg.starts_with?("--objects=")
    objects = arg.lchop("--objects=").to_i
  elsif arg.starts_with?("--limit=")
    limit_pct = arg.lchop("--limit=").to_f
  elsif arg.starts_with?("--rss-limit=")
    rss_limit_pct = arg.lchop("--rss-limit=").to_f
  end
end

# RSS is the secondary gate here (heap_size is the primary), so a platform that
# cannot answer must say so rather than compare zeros — see bench/bench_rss.cr.
unless BenchRss.available?
  STDERR.puts "cannot read this process's RSS on this platform; the RSS half of " \
              "this gate would compare zeros and pass."
  exit 64
end

def read_rss_kb : UInt64
  BenchRss.read_kb
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
heap_samples = [] of UInt64

puts "=== RSS leak detection (warmup=#{warmup}, cycles=#{cycles}, objects=#{objects}, heap_limit=#{limit_pct}%, rss_limit=#{rss_limit_pct}%) ==="

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
heap_start = HEAP.heap_size
puts "  post-warmup RSS=#{rss_start} kB heap_size=#{heap_start}"

cycles.times do |c|
  rss, hs = run_cycle(objects)
  ratio = hs > 0 ? (rss.to_f * 1024.0) / hs.to_f : 0.0
  ratios << ratio
  rss_samples << rss
  heap_samples << hs

  if c % 5 == 4 || c == cycles - 1
    puts "  cycle #{c + 1}: RSS=#{rss} kB heap=#{hs} ratio=#{ratio.round(2)}"
  end
end

rss_end = read_rss_kb
heap_end = HEAP.heap_size
growth_pct = rss_start > 0 ? ((rss_end.to_f - rss_start.to_f) / rss_start.to_f) * 100.0 : 0.0

# Compare halves of *post-warmup* samples only (ramp already discarded).
half = cycles // 2
early_rss = rss_samples[0...half]
late_rss = rss_samples[half..]
early_rss_med = early_rss.sort[early_rss.size // 2]
late_rss_med = late_rss.sort[late_rss.size // 2]
rss_late_growth = early_rss_med > 0 ? ((late_rss_med.to_f - early_rss_med.to_f) / early_rss_med.to_f) * 100.0 : 0.0

early_heap = heap_samples[0...half]
late_heap = heap_samples[half..]
early_heap_med = early_heap.sort[early_heap.size // 2]
late_heap_med = late_heap.sort[late_heap.size // 2]
heap_late_growth = early_heap_med > 0 ? ((late_heap_med.to_f - early_heap_med.to_f) / early_heap_med.to_f) * 100.0 : 0.0
final_ratio = ratios[-1]

puts ""
puts "  RSS post-warmup→end: #{rss_start}→#{rss_end} kB (#{growth_pct.round(2)}%)"
puts "  RSS early-median→late-median: #{early_rss_med}→#{late_rss_med} kB (#{rss_late_growth.round(2)}%)"
puts "  heap early-median→late-median: #{early_heap_med}→#{late_heap_med} (#{heap_late_growth.round(2)}%)"
puts "  final RSS/heap ratio=#{final_ratio.round(2)} (informational only)"

if heap_late_growth > limit_pct
  failures << "heap late-half grew #{heap_late_growth.round(2)}% vs early-half (limit #{limit_pct}%)"
end
if rss_late_growth > rss_limit_pct
  failures << "RSS late-half grew #{rss_late_growth.round(2)}% vs early-half (limit #{rss_limit_pct}%)"
end

trend_path = File.join(__DIR__, "trend.json")
trend = {
  "timestamp"            => Time.utc.to_s,
  "rss_start_kb"         => rss_start,
  "rss_end_kb"           => rss_end,
  "growth_pct"           => growth_pct.round(2),
  "late_growth_pct"      => rss_late_growth.round(2),
  "heap_late_growth_pct" => heap_late_growth.round(2),
  "rss_heap_ratio"       => final_ratio.round(3),
  "heap_size"            => heap_end,
  "warmup"               => warmup,
  "cycles"               => cycles,
  "objects"              => objects,
  "limit_pct"            => limit_pct,
  "rss_limit_pct"        => rss_limit_pct,
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
