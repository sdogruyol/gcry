# What are the main thread's stack bounds, according to each source?
#
# The mark scans a running fiber's stack as `[sp, fiber.@stack.bottom)`, and on
# this host that bottom sits 8192 bytes below the end of the `[stack]` mapping —
# the bytes where `main`'s outermost frames live
# (`bench/log/linux/2026-08-26-debug-build-own-stack-root/FINDINGS.md`). An
# attempt to widen the bound to the `pthread_getattr_np` snapshot never fired,
# which means the two are not two descriptions of the same range. This prints
# all three so the gap stops being a guess.
require "../src/gcry"

fiber = Fiber.current
stack = fiber.@stack
puts "fiber.@stack.pointer 0x#{stack.pointer.address.to_s(16)}"
puts "fiber.@stack.bottom  0x#{stack.bottom.address.to_s(16)}"

if b = Gcry::Platform.pthread_stack_bounds(LibC.pthread_self)
  puts "pthread bounds       [0x#{b[0].address.to_s(16)}, 0x#{b[1].address.to_s(16)})"
else
  puts "pthread bounds       unavailable"
end

local = 0_u64
puts "a local in main      0x#{pointerof(local).address.to_s(16)}"

File.each_line("/proc/self/maps") do |line|
  next unless line.includes?("[stack]")
  puts "maps                 #{line.strip}"
end
