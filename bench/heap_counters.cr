# Do the allocation counters keep what they are given?
#
# `note_alloc_bytes` updates `live_objects` / `total_bytes` / `bytes_since_gc`
# with plain `set(get + n)` unless `heap_counters_atomic` is set, and two
# threads running that lose increments outright — measured as the process
# heap's counter permanently behind in 3 runs of 40, and as the residual
# failures of `spec/invariant_spec.cr` before the invariant learned to state
# itself only of a heap that can keep it (src/gcry/invariant.cr).
#
# The counters now flip to atomic the moment a **second thread is created**
# (`GC.pthread_create`), so a program that cannot race keeps the cheap path and
# one that can keeps its numbers. This gate is that claim, in both directions:
#
#   atomic    two threads allocate a known number of objects; the counter must
#             account for **every one** of them.
# The plain arm also pins `GCRY_BITMAP_ALLOC=0`. The bitmap allocator *implies*
# atomic counters — its streaming sweep settles a chunk's reclaim with one
# batched `live_objects_sub`, which a non-atomic get/set loses wholesale — so an
# inherited `GCRY_BITMAP_ALLOC=1` keeps the plain path from ever running and the
# control cannot lose the increments it exists to lose. Measured: `lost 0` where
# the arm requires a loss, and the gate correctly refused to certify the other
# arm on the strength of it.
#
#   plain     `GCRY_HEAP_COUNTERS_ATOMIC=0` puts the old path back, and the same
#             workload must **lose** some. Without this arm the first one is
#             just a run that happened not to race.
#
# The GC is disabled for the workload: a collection recomputes what a sweep
# finds, and this asks about the increment path, not about the sweep. The
# counter is read between a ready barrier and a done barrier so the window
# holds nothing but the hammer's own allocations: expected == counted on the
# atomic arm, and every loss on the plain arm is visible (10-29 per round
# here, where the read around Thread.new/join reported 0 with +5..9 of
# thread bootstrap covering it).
#
#   crystal build -Dgc_none bench/heap_counters.cr -o bin/heap_counters
#   bin/heap_counters
#   GCRY_HEAP_COUNTERS_ATOMIC=0 bin/heap_counters --plain

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "heap_counters requires -Dgc_none (gcry as process GC)" %}
{% end %}

PER_THREAD = 300_000
THREADS    =       4

class Sink
  @@keep = uninitialized StaticArray(Void*, THREADS)

  def self.keep(i : Int32, ptr : Void*) : Nil
    @@keep[i] = ptr
  end
end

# Every thread is created and parked on `go` before `before` is read, and
# `after` is read the moment the last one reports `done` - so the window
# holds only the hammer's own allocations. Reading around `Thread.new` /
# `join` instead let thread bootstrap allocations (+5..9 per round) hide
# the 0-5 increments the plain path now loses per round, and the control
# reported `lost 0` while losing.
# `Atomic` is a struct: handed to a method it is copied, and a thread would
# then spin on its own private zero. Both gates live in class variables.
class Gate
  @@ready = Atomic(Int32).new(0)
  @@go = Atomic(Int32).new(0)
  @@done = Atomic(Int32).new(0)

  def self.reset : Nil
    @@ready.set(0)
    @@go.set(0)
    @@done.set(0)
  end

  # A thread's own bootstrap (Thread.current, its fiber) allocates *inside*
  # the thread, so it can land after `before` was read unless every thread
  # reports in first. Measured: +4 on the atomic arm before this.
  def self.all_ready? : Bool
    @@ready.get >= THREADS
  end

  def self.open : Nil
    @@go.set(1)
  end

  def self.wait_open : Nil
    @@ready.add(1)
    while @@go.get == 0
      Intrinsics.pause
    end
  end

  def self.finished : Nil
    @@done.add(1)
  end

  def self.all_finished? : Bool
    @@done.get >= THREADS
  end
end

def hammer(slot : Int32) : Nil
  Gate.wait_open
  i = 0
  last = Pointer(Void).null
  while i < PER_THREAD
    last = GC.malloc(32)
    i += 1
  end
  Sink.keep(slot, last)
  Gate.finished
end

plain = ARGV.includes?("--plain")
heap = Gcry.default_heap

puts "=== heap counters ==="
puts "mode: #{plain ? "plain (GCRY_HEAP_COUNTERS_ATOMIC=0)" : "atomic (flipped by the second thread)"}"

# One round of the hammer; `lost` is how many increments the counter missed.
def round(heap) : {UInt64, UInt64, UInt64}
  GC.disable
  Gate.reset
  threads = (0...THREADS).map { |i| Thread.new { hammer(i) } }
  until Gate.all_ready?
    Intrinsics.pause
  end
  before = heap.live_objects
  Gate.open
  until Gate.all_finished?
    Intrinsics.pause
  end
  after = heap.live_objects
  threads.each(&.join)
  GC.enable
  expected = (PER_THREAD * THREADS).to_u64
  counted = after - before
  lost = counted >= expected ? 0_u64 : expected - counted
  {expected, counted, lost}
end

expected, counted, lost = round(heap)

# The plain arm is a race it has to *win*: four threads must overlap inside
# `lazy_set(lazy_get + 1)` - a load and a store a few instructions apart -
# and since 2026-09-05 (`lazy_set`, no `xchg`) that window is ~100x narrower
# than the `set(get + 1)` it replaced: 0-5 losses per 1 200 000 tries here,
# where the old path lost 300-2000. So the loss is *accumulated* over up to
# PLAIN_ROUNDS rounds (24 M tries) rather than asked of one; the atomic arm
# gets one round, since its claim is that no round loses anything.
PLAIN_ROUNDS = 20
rounds = 1
while plain && lost == 0 && rounds < PLAIN_ROUNDS
  rounds += 1
  _, c, l = round(heap)
  expected += (PER_THREAD * THREADS).to_u64
  counted += c
  lost += l
end

puts "atomic path: #{heap.heap_counters_atomic}"
puts "allocated #{expected}, counter moved #{counted}, lost #{lost}#{rounds > 1 ? " (round #{rounds})" : ""}"

failures = [] of String

if plain
  if heap.heap_counters_atomic
    failures << "the knob asked for the plain path and the heap is on the atomic one"
  end
  if lost == 0
    failures << "#{THREADS} threads ran `set(get + 1)` on the same word #{expected} times and the " \
                "counter kept every one — this arm cannot show the loss it exists to show, so the " \
                "other arm's exactness is not attributable to the atomic path"
  end
else
  unless heap.heap_counters_atomic
    failures << "a second thread was created and the counters are still on the plain path"
  end
  if lost > 0
    failures << "#{lost} of #{expected} increments were lost with the atomic path on"
  end
end

if failures.empty?
  puts
  puts plain ? "ok — the old path loses increments, which is what the atomic one is for" \
                : "ok — every allocation is accounted for, with four threads on the same counters"
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
