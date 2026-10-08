# Does a thread's main fiber survive a collection that stops it mid-birth?
#
# `Thread#start` publishes the thread before it has a fiber:
#
#     Thread.threads.push(self)                              # stop_world suspends it now
#     Thread.current = self
#     @main_fiber = Fiber.new(stack_address, self)           # allocates, then
#                                                            # pushes onto the fiber list
#
# Between the allocation and the push, the new `Fiber` is on the new thread's
# stack and nowhere else. On Windows gcry bounded a thread's stack by its main
# fiber, so a thread stopped there was not scanned: the sweep freed the fiber,
# the push published the freed block, and the next fiber walk read it —
# `Fiber#running?` at C0000005 in `make tls-roots`, 3 of 100 runs on the
# Windows default job (2026-09-29). Linux and macOS ask the OS for the bounds
# and never had the gap; this runs there too so it stays that way.
#
# One thread collects back to back while main starts threads one at a time.
# Each new thread calls `GC.collect` once itself — the collection that answers
# it began after the call, on this thread or the collector, and walks every
# listed fiber, so a freed one is reported as free rather than kept by it —
# and then asks whether its own main fiber is still an allocated block whose
# stack is the thread's own.
#
#   crystal build -Dgc_none bench/thread_birth_fiber.cr -o bin/thread_birth_fiber
#   bin/thread_birth_fiber [births]    default 300

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "thread_birth_fiber requires -Dgc_none (gcry as process GC)" %}
{% end %}

births = (ARGV[0]? || "300").to_i
heap = Gcry.default_heap.not_nil!

stop = Atomic(Int32).new(0)
collections = Atomic(Int64).new(0_i64)
lost = Atomic(Int32).new(0)
foreign = Atomic(Int32).new(0)

# The collector collects with no gap, and each birth thread's own `GC.collect`
# queues behind it. Until 2026-10-09 this loop yielded after each collection:
# the collection mutex did not hand over, and a peer that re-took it the
# instant it dropped it kept a birth thread asleep on it indefinitely — 2 of
# 173 runs on one windows-latest runner, the collector still collecting
# (2026-09-30). The section now goes to waiters in arrival order, and the
# birth thread's call is answered by the next collection, so the loop is back
# to the shape that stalled.
collector = Thread.new(name: "collector") do
  until stop.get == 1
    GC.collect
    collections.add(1)
  end
end

births.times do |i|
  t = Thread.new(name: "birth") do
    GC.collect
    fiber = Fiber.current
    bounds = Gcry::Platform.current_pthread_stack_bounds
    if !heap.live?(Pointer(Void).new(fiber.object_id))
      lost.add(1)
      STDERR.puts "birth #{i}: main fiber 0x#{fiber.object_id.to_s(16)} is not an allocated block"
    elsif bounds && fiber.@stack.bottom.address != bounds[1].address
      foreign.add(1)
      STDERR.puts "birth #{i}: main fiber 0x#{fiber.object_id.to_s(16)} holds another thread's stack"
    end
  end
  t.join
end

stop.set(1)
collector.join

unborn = {% if flag?(:win32) %}Gcry::Platform.unborn_stack_bounds_total{% else %}"n/a"{% end %}
exited = {% if flag?(:win32) %}Gcry::Platform.stop_skipped_exited{% else %}"n/a"{% end %}
puts "births #{births}, concurrent collections #{collections.get}, " \
     "fibers freed #{lost.get}, reused #{foreign.get}, " \
     "threads bounded before their fiber existed #{unborn}, listed but exited at a stop #{exited}"

if lost.get + foreign.get > 0
  puts "FAIL a thread's main fiber was collected while the thread was being born"
  exit 1
end
puts "ok"
