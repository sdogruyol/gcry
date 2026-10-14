require "../../../../src/gcry"

# `GC.free` of a large block bigger than `LARGE_FREE_TRIM_SLACK`, with n
# other large chunks alive. The free puts the cache past the slack, so it
# trims at once, and with nothing else cached the trim takes the one chunk
# off the list and out of the index by itself (`Heap#unlink_chunk`).
#
# n live 64 KiB objects, with m 4 MiB objects spread evenly among them. A
# sweep's rebuild turns the chunk list round, so a block allocated early is
# not reliably deep in it; spread out, the m blocks sit about n/2 deep on
# average whichever way the list faces. Only the m frees are timed.
n = ARGV[0].to_i
m = (ARGV[1]? || "200").to_i
big_size = 4 * 1024 * 1024
small = Array(Pointer(Void)).new(n)
big = Array(Pointer(Void)).new(m)
every = n // m
every = 1 if every < 1
n.times do |i|
  small << GC.malloc_atomic(64 * 1024)
  big << GC.malloc_atomic(big_size) if i % every == every // 2 && big.size < m
end
heap = Gcry.default_heap.not_nil!
indexed = heap.@chunk_index_count
t0 = Time.instant
big.each { |p| GC.free(p) }
dt = (Time.instant - t0).total_milliseconds
puts "n=#{n} m=#{big.size} indexed=#{indexed} free_ms=#{dt.round(2)} per_free_us=#{(dt * 1000 / big.size).round(2)} live_check=#{small.size}"
