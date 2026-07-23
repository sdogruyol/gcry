require "../src/gcry"

puts "start"
ptr = GC.malloc(64)
puts "malloc ok heap?=#{GC.is_heap_ptr(ptr)}"
puts "calling collect"
GC.collect
puts "collect ok stats=#{GC.stats.heap_size}"
puts "done"
