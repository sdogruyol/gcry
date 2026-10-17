# Is the out-of-memory reserve (`GCRY_OOM_RESERVE_KB`, 4 MiB by default)
# resident? Prints the reserve's mapping from /proc/self/smaps — its Size
# and Rss — after allocating and collecting enough to have run the heap
# through several majors.
#
#   crystal build --release -Dgc_none oom_reserve_rss.cr -o oom-reserve-rss
#   ./oom-reserve-rss
require "gcry"

heap = Gcry.default_heap
keep = [] of String
200_000.times { |i| keep << i.to_s; keep.shift if keep.size > 1000 }
GC.collect
base = heap.@oom_reserve_base
size = heap.oom_reserve_bytes
puts "reserve: base 0x#{base.to_s(16)} size #{size // 1024} KiB"
lines = File.read("/proc/self/smaps").lines
lines.each_with_index do |line, i|
  next unless line =~ /^([0-9a-f]+)-([0-9a-f]+) /
  lo = $1.to_u64(16)
  hi = $2.to_u64(16)
  next unless lo <= base && base < hi
  puts line
  lines[i + 1, 6].each { |l| puts "  #{l}" }
end
