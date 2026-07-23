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
puts "rounds=#{rounds} fibers_done=#{fibers_done} heap_size=#{stats.heap_size} total_bytes=#{stats.total_bytes} keep=#{keep.size}"
