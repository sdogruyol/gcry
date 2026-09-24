# Is the idle collector's own stack a root?
#
# 0.27.0 skipped the `gc-idle` thread's stack in both stack scans on the
# grounds that it held no GC reference. Its thread-entry frames do, and Darwin
# CI (run `35995083083`, `make scheduler-roots --control`) freed a block that
# eight slots of that stack still held, then faulted on the freed-block poison.
# Linux never reproduced it (0 of 90): the window is timing, and waiting for
# timing is not a gate. So this constructs it.
#
# `GCRY_IDLE_TEST_HOLD=1` makes the idle thread allocate one block, fill it with
# a pattern, and keep its address only in a stack slot of its own loop frame —
# the harness knows it as `address ^ HOLD_KEY`, which roots nothing. Once the
# thread is parked, this runs collections from the main thread with churn in
# between and freed payloads poisoned, then asks whether the block is still
# live and intact. On Linux the thread is not suspended, so it is found from
# the SP it publishes while parked; on Darwin it is suspended like any thread.
#
# The red arm is `GCRY_IDLE_SCAN_SKIP=1`, the 0.27.0 skip, which must lose it.
#
#   crystal build -Dgc_none bench/idle_thread_roots.cr -o bin/idle_thread_roots
#   GCRY_IDLE_TEST_HOLD=1 GCRY_POISON_FREED=1 bin/idle_thread_roots                         # PASS
#   GCRY_IDLE_TEST_HOLD=1 GCRY_POISON_FREED=1 GCRY_IDLE_SCAN_SKIP=1 bin/idle_thread_roots   # FAIL

require "../src/gcry"

unless Gcry::IdleRelease.test_hold?
  STDERR.puts "set GCRY_IDLE_TEST_HOLD=1: this harness needs the idle thread's research hold"
  exit 2
end

heap = Gcry.default_heap
# The idle thread starts at the end of the first collection.
GC.collect

masked = 0_u64
200.times do
  masked = Gcry::IdleRelease.hold_masked
  break if masked != 0 && Gcry::IdleRelease.parked_sp != 0
  sleep 10.milliseconds
end
if masked == 0
  puts "FAIL: the idle thread never published its held block"
  exit 1
end

class Churn
  @pad = StaticArray(UInt64, 12).new(0_u64)
end

before = heap.collections
6.times do
  sink = nil.as(Churn?)
  20_000.times { sink = Churn.new }
  GC.collect
end

address = masked ^ Gcry::IdleRelease::HOLD_KEY
block = Pointer(UInt64).new(address)
live = heap.live?(block.as(Void*))
bad = -1
if live
  Gcry::IdleRelease::HOLD_WORDS.times do |i|
    if block[i] != Gcry::IdleRelease::HOLD_PATTERN
      bad = i
      break
    end
  end
end

puts "=== the idle collector's stack as a root ==="
puts "block held only by the gc-idle thread's stack; #{heap.collections - before} collections from main since"
puts "  parked sp 0x#{Gcry::IdleRelease.parked_sp.to_s(16)}"
puts "  live? #{live}"
if !live
  puts "FAIL: the block the idle thread holds was swept — its stack is not being scanned"
  exit 1
elsif bad >= 0
  puts "FAIL: the block is live but word #{bad} reads 0x#{block[bad].to_s(16)} — it was freed and reused"
  exit 1
end
puts "PASS: the block the idle thread's stack holds survived and reads back intact"
