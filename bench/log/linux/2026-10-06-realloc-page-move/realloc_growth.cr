{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

# rb TARGET_BYTES REPS [SPINNERS]
# Grows an IO::Memory to TARGET by 1 KiB writes, REPS times; prints ns per build.
target = ARGV[0].to_i
reps = ARGV[1].to_i
spinners = (ARGV[2]? || "0").to_i
stop = Atomic(Int32).new(0)
threads = Array(Thread).new
spinners.times do
  threads << Thread.new do
    x = 0_u64
    while stop.get == 0
      x &+= 1
    end
  end
end
chunk = Bytes.new(1024, 7_u8)
sum = 0_u64
t0 = Time.instant
reps.times do
  io = IO::Memory.new
  (target // 1024).times { io.write(chunk) }
  sum &+= io.bytesize
end
el = Time.instant - t0
stop.set(1)
threads.each &.join
r = uninitialized LibC::RUsage
LibC.getrusage(0, pointerof(r))
puts "target=#{target} ns/build=#{(el.total_nanoseconds / reps).round(0)} minflt=#{r.ru_minflt} sum=#{sum}"
