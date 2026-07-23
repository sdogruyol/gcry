# Build: crystal build -Dgc_none samples/hello.cr -o hello
# Run:   ./hello

require "../src/gcry"

puts "hello from gcry #{Gcry::VERSION}"

ptr = GC.malloc(64)
raise "expected gcry heap pointer" unless GC.is_heap_ptr(ptr)

GC.collect
puts "heap_size=#{GC.stats.heap_size} collections via stats"
puts "done"
