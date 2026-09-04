# Does the collector's stack scrub ask libc where the stack is?
#
# `GCRY_COLLECT_SCRUB` is on by default and runs twice per collection, at
# `run_collection`'s entry and exit. The wipe is 16 KiB of `memset`. The
# *bounds lookup* in front of it was the expensive half: `clear_stack_body`
# asked `pthread_getattr_np(pthread_self)`, and for the **initial** thread
# glibc answers that by opening and parsing `/proc/self/maps` — the cost
# `src/gcry/platform/linux_stack.cr` already documents, and snapshots its way
# around, to keep out of the pause. A Crystal program collects on the main
# pthread, so every collection paid two parses whose cost grows with the
# process's mapping count, and both landed *outside* the pause window, so no
# `pause_p50`/`pause_p99` could show them.
#
# `Fiber#@stack` already holds the bounds — for a thread's main fiber they are
# the real pthread bounds, filled in once at thread start
# (`fiber.cr`: `@stack = Stack.new(stack, stack_bottom)`) — so the collector
# reads two words instead. `clear_stack_libc_bounds` counts the collector
# scrubs that fell back to libc anyway, and it must be zero.
#
# The property is structural: **the collector never asks libc**. The cost of
# one call is reported beside it, at two mapping counts, because that is what
# the property is worth. Whole-collection timing is deliberately not the gate:
# with thousands of parked fibers the fiber-stack scan dominates it, which
# would let this number pass or fail for reasons that are not the scrub.
#
#   crystal build -Dgc_none bench/collect_scrub_cost.cr -o bin/collect_scrub_cost
#   bin/collect_scrub_cost
#   GCRY_SCRUB_LIBC_BOUNDS=1 bin/collect_scrub_cost --libc   # red arm
#
# Each parked fiber is two VMAs (guard + stack), so fibers are the axis.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "collect_scrub_cost requires -Dgc_none (gcry as process GC)" %}
{% end %}

FIBERS   = (ENV["SCRUB_COST_FIBERS"]? || "4000").to_i
COLLECTS = 20

# One libc lookup must stay under this at any mapping count for the old code
# to have been cheap. It does not: the numbers below are milliseconds.
BUDGET_US = 100.0

libc_arm = ARGV.includes?("--libc")
heap = Gcry.default_heap

def libc_bounds_us(n : Int32) : Float64
  t = Gcry::Clock.monotonic_ns
  n.times do
    attr = uninitialized LibC::PthreadAttrT
    if LibC.pthread_getattr_np(LibC.pthread_self, pointerof(attr)) == 0
      LibC.pthread_attr_getstack(pointerof(attr), out _, out _)
      LibC.pthread_attr_destroy(pointerof(attr))
    end
  end
  (Gcry::Clock.monotonic_ns - t) / 1000.0 / n
end

def fiber_bounds_us(n : Int32) : Float64
  sink = 0_u64
  t = Gcry::Clock.monotonic_ns
  n.times do
    stack = Fiber.current.@stack
    sink &+= stack.pointer.address ^ stack.bottom.address
  end
  us = (Gcry::Clock.monotonic_ns - t) / 1000.0 / n
  raise "optimised away" if sink == 0
  us
end

def maps_lines : Int32
  File.read_lines("/proc/self/maps").size
end

puts "=== collector scrub: where do the stack bounds come from? ==="
puts "mode: #{libc_arm ? "libc (GCRY_SCRUB_LIBC_BOUNDS=1, as gcry did before 2026-09-04)" : "the running fiber"}"

quiet_lines = maps_lines
quiet_libc = libc_bounds_us(200)
quiet_fiber = fiber_bounds_us(200_000)
puts "#{quiet_lines} maps lines: libc lookup #{quiet_libc.round(1)} µs, " \
     "fiber lookup #{quiet_fiber.round(4)} µs"

ch = Channel(Nil).new
FIBERS.times { spawn { ch.receive } }
Fiber.yield

loaded_lines = maps_lines
loaded_libc = libc_bounds_us(20)
loaded_fiber = fiber_bounds_us(200_000)
puts "#{loaded_lines} maps lines (#{FIBERS} parked fibers): libc lookup " \
     "#{loaded_libc.round(1)} µs, fiber lookup #{loaded_fiber.round(4)} µs"

libc_before = heap.clear_stack_libc_bounds
runs_before = heap.collect_scrub_runs
COLLECTS.times { GC.collect }
libc_calls = heap.clear_stack_libc_bounds - libc_before
runs = heap.collect_scrub_runs - runs_before
puts "#{runs} scrubs over #{COLLECTS} collections, #{heap.collect_scrub_bytes_total} bytes wiped, " \
     "#{libc_calls} libc bounds lookups"
puts "  a collection would have paid #{(2 * loaded_libc / 1000).round(2)} ms " \
     "in bounds lookups alone at this mapping count"

failures = [] of String
if loaded_lines - quiet_lines < FIBERS
  failures << "the fibers added #{loaded_lines - quiet_lines} mappings, not #{FIBERS}: " \
              "this run never loaded the axis the cost grows on"
end
failures << "the scrub never ran" if runs == 0
failures << "nothing was wiped, so the run is not about the scrub" if heap.collect_scrub_bytes_total == 0
if loaded_libc <= BUDGET_US
  failures << "one libc lookup cost #{loaded_libc.round(1)} µs at #{loaded_lines} " \
              "mappings, under the #{BUDGET_US} µs budget — on this host the old " \
              "path was cheap and neither arm means anything"
end

if libc_arm
  if libc_calls == 0
    failures << "the libc arm did not take the libc path, so the counter is unread"
  end
else
  if libc_calls > 0
    failures << "#{libc_calls} collector scrubs asked libc for stack bounds — " \
                "on the main thread that is a /proc/self/maps parse per call"
  end
end

if failures.empty?
  puts
  puts(libc_arm ? "ok — the red arm takes the libc path, so the counter can move" \
                   : "ok — the collector reads the fiber's bounds and never asks libc")
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
