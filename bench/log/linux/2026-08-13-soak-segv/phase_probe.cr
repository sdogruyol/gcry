# How long is the window a Monitor munmap would have to land inside?
require "gcry"

heap = Gcry.default_heap.not_nil!
live = [] of String
100.times { spawn { sleep 50.milliseconds } }
Fiber.yield

stacks = [] of UInt64
total = [] of UInt64
40.times do
  2000.times { live << "x" * 64 }
  live.clear if live.size > 20_000
  GC.collect
  stacks << heap.last_phase_stacks_ns
  total << heap.last_pause_ns
end

def med(a)
  s = a.sort
  s[s.size // 2]
end

puts "collections=#{stacks.size}"
puts "phase_stacks median=#{med(stacks)} ns  max=#{stacks.max} ns"
puts "pause       median=#{med(total)} ns  max=#{total.max} ns"
