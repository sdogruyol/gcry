require "../../../../src/gcry"
# n large objects stay live; each round k more are allocated, dropped, and the
# collection's sweep caches and then trims them (Linux retain 0).
live_n = ARGV[0].to_i
k = ARGV[1].to_i
rounds = 8
SZ = 64 * 1024
live = Array(Pointer(Void)).new(live_n) { GC.malloc_atomic(SZ) }
GC.collect
times = [] of Float64
rounds.times do
  tmp = Array(Pointer(Void)).new(k) { GC.malloc_atomic(SZ) }
  tmp.fill(Pointer(Void).null)
  tmp = nil
  t0 = Time.instant
  GC.collect
  times << (Time.instant - t0).total_milliseconds
end
heap = Gcry.default_heap.not_nil!
puts "live=#{live_n} k=#{k} collect_ms median=#{times.sort[times.size // 2].round(1)} min=#{times.min.round(1)} index=#{heap.@chunk_index_count} live_check=#{live.size}"
