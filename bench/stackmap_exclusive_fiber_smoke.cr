# Exclusive (=2) must keep a String alive on a *parked* fiber across collects
# with NO reference from the collecting fiber. Hybrid hides this via
# conservative fiber word scans; exclusive must walk swapcontext frames.
#
# Build (probe Crystal):
#   CRYSTAL_EMIT_STACKMAP=1 CRYSTAL_STACKMAP_PER_FUN=32 crystal build -Dgc_none \
#     -Dpreview_mt -Dexecution_context --no-debug --frame-pointers=always \
#     -o bin/stackmap_exclusive_fiber_smoke bench/stackmap_exclusive_fiber_smoke.cr
#
# Run:
#   GCRY_PRECISE_STACK=2 GCRY_PRECISE_FIBERS=1 \
#     ./bin/stackmap_exclusive_fiber_smoke
#
# Default LEAF=8 KiB (plus FP-fill). LEAF=0 is research-only and currently
# fails this smoke — FP-fill spans miss the parked String slot.

require "../src/gcry"

ready = Channel(Nil).new
done = Channel(Nil).new
ok = Channel(Bool).new

spawn do
  keep = "parked-fiber-root-" + ("x" * 256)
  ready.send(nil)
  done.receive
  good = keep.starts_with?("parked-fiber-root-") && keep.bytesize == 256 + "parked-fiber-root-".bytesize
  ok.send(good)
end

ready.receive
10.times { GC.collect }

lookups = Gcry::StackMaps.lookups
hits = Gcry::StackMaps.hits
marked = Gcry.default_heap.precise_stack_roots_marked
puts "after_collect marked=#{marked} lookups=#{lookups} hits=#{hits} exclusive=#{Gcry.default_heap.precise_stack_exclusive}"

done.send(nil)
Fiber.yield
good = ok.receive

unless Gcry.default_heap.precise_stack_exclusive
  STDERR.puts "FAIL: set GCRY_PRECISE_STACK=2"
  exit 1
end

unless Gcry.default_heap.precise_stack_fibers_exclusive
  STDERR.puts "FAIL: set GCRY_PRECISE_FIBERS=1 (pure parked-fiber exclusive)"
  exit 1
end

unless Gcry::StackMaps.loaded? || Gcry::StackMaps.ensure_loaded
  STDERR.puts "FAIL: maps not loaded (build with CRYSTAL_EMIT_STACKMAP=1)"
  exit 1
end

unless good
  STDERR.puts "FAIL: parked fiber String swept/corrupted under exclusive"
  exit 1
end

puts "OK"
