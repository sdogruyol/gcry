require "../../../../src/gcry"
n = ARGV[0].to_i
ptrs = Array(Pointer(Void)).new(n) { GC.malloc_atomic(64 * 1024) }
t0 = Time.instant
ptrs.each { |p| GC.free(p) }
dt = (Time.instant - t0).total_milliseconds
puts "n=#{n} free_all_ms=#{dt.round(1)} per_free_us=#{(dt * 1000 / n).round(2)}"
