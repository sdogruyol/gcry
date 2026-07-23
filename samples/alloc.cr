# Alloc churn under gcry (process GC).
# Build: crystal build -Dgc_none --release samples/alloc.cr -o alloc

require "../src/gcry"

rounds = (ARGV[0]? || "1000").to_i
keep = [] of Bytes

rounds.times do |i|
  buf = Bytes.new(64 + (i % 128))
  keep << buf if i % 10 == 0
  keep.clear if keep.size > 50
end

GC.collect
puts "rounds=#{rounds} heap_size=#{GC.stats.heap_size} total_bytes=#{GC.stats.total_bytes}"
