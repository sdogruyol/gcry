require "../src/gcry"
require "wait_group"

{% unless flag?(:gc_none) %}
  raise "need -Dgc_none"
{% end %}

n = (ENV["EC"]? || "4").to_i
iters = (ENV["ITERS"]? || "200000").to_i
Fiber::ExecutionContext.default.resize(n)
# Default: no auto-collect (allocator race surface). Set GCRY_THRESHOLD for GC.
unless ENV["GCRY_THRESHOLD"]?
  Gcry.default_heap.gc_threshold = UInt64::MAX
end
puts "ec_capacity=#{Fiber::ExecutionContext.default.capacity} tlab=#{Gcry.default_heap.tlab_enabled?} thr=#{Gcry.default_heap.gc_threshold}"

wg = WaitGroup.new(n)
failed = Atomic(Int32).new(0)
n.times do |t|
  spawn(name: "w#{t}") do
    begin
      iters.times do |i|
        buf = GC.malloc_atomic((64 + (i % 200)).to_u64).as(UInt8*)
        buf[0] = 1_u8
        if i % 3 == 0
          buf = GC.realloc(buf.as(Void*), (128 + (i % 100)).to_u64).as(UInt8*)
          buf[0] = 2_u8
        end
      end
    rescue e
      failed.add(1)
      STDERR.puts "worker=#{t} #{e.class}: #{e.message}"
    ensure
      wg.done
    end
  end
end
wg.wait
GC.collect
if failed.get != 0
  STDERR.puts "FAIL workers=#{failed.get} collections=#{Gcry.default_heap.collections}"
  exit 1
end
puts "OK collections=#{Gcry.default_heap.collections}"
