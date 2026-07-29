# RSS leak detection gate.
#
# Allocates, frees, collects in cycles and tracks RSS within this process.
# Gate is host-relative only: late-half median RSS must not grow >10% vs
# early-half (leak signal). Absolute RSS and RSS/heap ratio are logged for
# humans but never compared to a committed cross-host baseline (CI ≠ macOS ≠ WSL).
#
# Usage:
#   crystal build -Dgc_none bench/rss_leak.cr -o bin/rss_leak
#   ./bin/rss_leak [--cycles=20] [--objects=5000]
#
# Writes bench/trend.json (gitignored) for local/CI artifact trending.

require "../src/gcry"
require "json"

HEAP = Gcry.default_heap.not_nil!

cycles = 20
objects = 5000
ARGV.each do |arg|
  if arg.starts_with?("--cycles=")
    cycles = arg.lchop("--cycles=").to_i
  elsif arg.starts_with?("--objects=")
    objects = arg.lchop("--objects=").to_i
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

failures = [] of String
ratios = [] of Float64
rss_samples = [] of UInt64

puts "=== RSS leak detection (cycles=#{cycles}, objects=#{objects}) ==="

# Warm-up
warm = [] of Void*
1000.times { warm << HEAP.malloc(128) }
warm.each { |p| HEAP.free(p) }
GC.collect
GC.collect

rss_start = read_rss_kb
puts "  start RSS=#{rss_start} kB heap_size=#{HEAP.heap_size}"

cycles.times do |c|
  live = [] of Void*
  objects.times { |i| live << HEAP.malloc(64 + (i % 256)) }

  # Free half — leave fragmentation pressure
  live.each_with_index { |p, i| HEAP.free(p) if i.even? }
  live.clear
  GC.collect

  rss = read_rss_kb
  hs = HEAP.heap_size
  ratio = hs > 0 ? (rss.to_f * 1024.0) / hs.to_f : 0.0
  ratios << ratio
  rss_samples << rss

  if c % 5 == 4 || c == cycles - 1
    puts "  cycle #{c + 1}: RSS=#{rss} kB heap=#{hs} ratio=#{ratio.round(2)}"
  end
end

rss_end = read_rss_kb
growth_pct = rss_start > 0 ? ((rss_end.to_f - rss_start.to_f) / rss_start.to_f) * 100.0 : 0.0

# Discard first half (warm-up / ramp), compare second-half median RSS
half = cycles // 2
early = rss_samples[0...half]
late = rss_samples[half..]
early_med = early.sort[early.size // 2]
late_med = late.sort[late.size // 2]
late_growth = early_med > 0 ? ((late_med.to_f - early_med.to_f) / early_med.to_f) * 100.0 : 0.0
final_ratio = ratios[-1]

puts ""
puts "  RSS start→end: #{rss_start}→#{rss_end} kB (#{growth_pct.round(2)}%)"
puts "  early-median→late-median: #{early_med}→#{late_med} kB (#{late_growth.round(2)}%)"
puts "  final RSS/heap ratio=#{final_ratio.round(2)} (informational only)"

# Only gate: late-half RSS should not grow >10% vs early-half
if late_growth > 10.0
  failures << "RSS late-half grew #{late_growth.round(2)}% vs early-half (limit 10%)"
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
  "cycles"          => cycles,
  "objects"         => objects,
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
