# Process-GC stress under gcry.
# Build: crystal build -Dgc_none --release samples/stress.cr -o stress
# Run:   ./stress [rounds]

require "../src/gcry"

rounds = (ARGV[0]? || "200").to_i
keep = [] of String
fibers_done = 0

rounds.times do |i|
  keep << ("x" * (32 + i % 64))
  keep.shift if keep.size > 40

  if i % 20 == 0
    spawn do
      buf = Bytes.new(128)
      buf[0] = 1_u8
      fibers_done += 1
    end
    Fiber.yield
  end

  GC.collect if i % 50 == 49
end

GC.collect
stats = GC.stats
pause = Gcry.pause_stats
puts "rounds=#{rounds} fibers_done=#{fibers_done} heap_size=#{stats.heap_size} total_bytes=#{stats.total_bytes} keep=#{keep.size}"
puts "pause last_us=#{pause.last_ns // 1000} p50_us=#{pause.p50_ns // 1000} p99_us=#{pause.p99_ns // 1000} max_us=#{pause.max_ns // 1000} count=#{pause.count} majors=#{Gcry.default_heap.major_collections}"
