# Trace + heap-dump smoke (Phase 7.1 / 7.2).
#
# Build: crystal build bench/trace_smoke.cr -o bin/trace_smoke
# Run:   GCRY_TRACE=1 GCRY_TRACE_ALLOC_SAMPLE=1 GCRY_TRACE_FILE=/tmp/gcry-trace.ndjson ./bin/trace_smoke
#
# Or: make trace-smoke

require "json"
require "../src/gcry"

trace_path = ENV["GCRY_TRACE_FILE"]? || File.tempname("gcry-trace", ".ndjson")
File.delete(trace_path) if File.exists?(trace_path)

# Force-enable even if env was not set at require time.
io = File.open(trace_path, "w")
Gcry::Trace.enable(io, alloc_sample: 1_u64)

heap = Gcry::Heap.new
keep = [] of Void*

10.times do |i|
  p = heap.malloc(32 + i)
  heap.add_root(p)
  keep << p
end

# Drop half, free them, collect — gone set should include freed addresses.
gone_expect = keep[5..].map(&.address).to_set
keep[5..].each do |p|
  heap.delete_root(p)
  heap.free(p)
end
keep = keep[0...5]

before = Gcry.dump_heap_addresses(heap)
heap.collect
after = Gcry.dump_heap_addresses(heap)

dump_io = IO::Memory.new
dump_count = Gcry.dump_heap(dump_io, heap)
raise "dump_count #{dump_count} != live #{heap.live_objects}" unless dump_count == heap.live_objects
raise "expected >= 5 live, got #{dump_count}" if dump_count < 5
raise "address set size #{after.size} != live #{heap.live_objects}" unless after.size.to_u64 == heap.live_objects

# Independent traversal: every dump line parses and addr is in `after`.
lines = 0_u64
dump_io.to_s.each_line do |line|
  next if line.empty?
  obj = JSON.parse(line)
  addr_s = obj["addr"].as_s
  raise "bad addr #{addr_s}" unless addr_s.starts_with?("0x")
  addr = addr_s[2..].to_u64(16)
  raise "dump addr missing from set: #{addr_s}" unless after.includes?(addr)
  lines += 1
end
raise "line count #{lines} != dump_count #{dump_count}" unless lines == dump_count

gone = Gcry.heap_dump_gone(before, after)
gone_expect.each do |a|
  raise "expected reclaimed 0x#{a.to_s(16)} still live" if after.includes?(a)
end

# Finalizer register event
fin_ran = false
obj = heap.malloc(64)
heap.add_finalizer(obj) { |_| fin_ran = true }
heap.free(obj) # notice_reclaim may drop finalizer without running if explicit free
heap.collect

Gcry::Trace.disable
io.close

# Parse NDJSON
events = [] of String
File.each_line(trace_path) do |line|
  next if line.empty?
  obj = JSON.parse(line)
  events << obj["event"].as_s
  raise "missing ts_ns" unless obj["ts_ns"]?
end

raise "no alloc events" unless events.any? { |e| e == "alloc" }
raise "no free events" unless events.any? { |e| e == "free" }
raise "no collect_start" unless events.any? { |e| e == "collect_start" }
raise "no collect_end" unless events.any? { |e| e == "collect_end" }
raise "no finalizer register" unless events.any? { |e| e == "finalizer" }

puts "trace_smoke ok events=#{events.size} dump=#{dump_count} file=#{trace_path}"
