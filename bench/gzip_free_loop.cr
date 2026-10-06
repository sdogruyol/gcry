# Does a large block the program frees with `GC.free` get reused, or does
# every free unmap it and every allocation map and fault in a fresh one?
#
# zlib allocates its stream state through `GC.malloc` and releases it through
# `GC.free` (`Compress::Deflate`'s allocator hooks), and its window, hash and
# pending buffers are large blocks. One `Compress::Gzip::Writer` per
# iteration allocates and frees them all. Under large-object recycling the
# cache kept only what the last major left (`Heap#large_recycle_budget`),
# which is nothing in a loop that never collects, so each free unmapped its
# chunk: 515 ms for 20 000 iterations, against 113 ms with
# `GCRY_LARGE_RECYCLE=0` and 520-570 ms under Boehm (2026-10-06).
#
#   crystal build --release -Dgc_none bench/gzip_free_loop.cr -o bin/gzip_free_loop
#   bin/gzip_free_loop [iterations]
#
# Exits 1 under gcry when the warm loop unmaps more than a kilobyte per
# iteration: one deflate stream's large blocks are hundreds of KiB, so that
# is well under one stream in a hundred going back to the kernel
# (`make gzip-free-reuse`).
{% if flag?(:gc_none) %}
  require "../src/gcry"
{% end %}
require "compress/gzip"

iterations = (ARGV[0]? || "20000").to_i
payload = Bytes.new(4096) { |i| (i * 7 % 256).to_u8 }

def gzip_once(payload : Bytes) : Int32
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io, &.write(payload))
  io.bytesize
end

# Warm: the first iterations map the chunks the rest should reuse.
100.times { gzip_once(payload) }

{% if flag?(:gc_none) %}
  heap = Gcry.default_heap
  unmapped0 = heap.unmapped_bytes
  mapped0 = heap.chunks_mapped
{% end %}
t0 = Time.instant
total = 0_i64
iterations.times { total += gzip_once(payload) }
elapsed = Time.instant - t0
puts "gzip_free_loop: #{iterations} iterations in #{elapsed.total_milliseconds.round(1)} ms (#{total} bytes out)"

{% if flag?(:gc_none) %}
  # Cumulative, and not reset by a collection (`Heap#unmapped_bytes`).
  unmapped = heap.unmapped_bytes - unmapped0
  puts "unmapped #{unmapped // 1024} KiB, #{heap.chunks_mapped - mapped0} chunks mapped, #{heap.collections} collections"
  if unmapped > iterations.to_u64 * 1024
    puts "FAIL: the loop unmapped more than 1 KiB per iteration"
    exit 1
  end
{% end %}
