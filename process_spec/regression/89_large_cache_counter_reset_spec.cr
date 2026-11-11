require "../../src/gcry"
require "spec"

# Four large-cache counters are reset by the collector after the flushes,
# with the world running and no lock: `@large_alloc_since_major` and
# `@large_cache_hits`/`_misses` are zeroed every major, and
# `@large_recycle_budget` is set every collection (to the cache's bytes, or
# 0). Allocating threads write them all through that section: the large
# paths count and spend the budget under `@alloc_lock`, and `map_chunk`
# spends the budget for a size-class chunk under the class lock only. Each
# write was a plain load and store, so a mutator that had loaded before the
# reset stored the old cycle's value back over it: the next major kept the
# large bytes of two cycles for recycling, the adaptive retain read two
# cycles' hits, and the budget the cache may hold between majors came back
# from the cycle before. Now each counter is atomic: an add lands on the
# reset value, a subtraction that loaded first fails its compare-and-set and
# is recomputed from it, and the per-major counts are taken in one swap
# (`Heap#def_shared_counter`).
#
# The interleaving is forced. `Heap#post_stw_hook` brackets the resets with
# two pairs of stages (`:before_large_take`/`:after_large_take`,
# `:before_large_budget`/`:after_large_budget`; nothing between a pair takes
# a lock). At the first stage of a pair the collector lets a waiting thread
# go and waits until that thread has parked in `Heap.shared_counter_hook`,
# between its load of the counter and its store; at the second, after the
# reset, it releases it. The control arm (`Heap.shared_counters_atomic =
# false`, the code before) must lose the reset on the same construction, or
# the fixed arm passes on nothing. Each arm runs in a process of its own.
# `bench/log/linux/2026-11-01-large-cache-counters/FINDINGS.md`.

# Large sizes nothing else in the spec runner asks for.
private C89_LARGE_BYTES = 192 * 1024 + 4096
private C89_MISS_BYTES  = 320 * 1024 + 4096
# Five blocks to a chunk, in a class nothing in the spec runner allocates.
private C89_CHUNK_CLASS = 24576
# What the budget holds before the collection: far from anything a reset
# writes, so the control's stale store is unmistakable.
private C89_STALE_BUDGET = 1_u64 << 40
private C89_COUNTERS     = {"since", "hits", "misses", "budget"}

private def c89_heap(arm : String) : Gcry::Heap
  heap = Gcry.default_heap
  # The sweep in the stop, so nothing runs between the flushes and the
  # resets but the code under test. No recycling: the cache is then left
  # alone until after the counters are taken (`trim_large_cache(0)` at the
  # start of a recycling major would empty it), and the budget is set to 0.
  heap.lazy_sweep = false
  heap.large_recycle = false
  Gcry::Heap.shared_counters_atomic = arm == "fixed"
  heap
end

private def c89_since(heap : Gcry::Heap) : UInt64
  heap.@large_alloc_since_major.get
end

# Lets a thread run *action* at the collector's *before* stage; the first
# write of counter *name* it makes parks in `shared_counter_hook` between its
# load and its store, and the collector waits for that before it resets. The
# thread is released at *after*, once the reset is done. Returns whether the
# thread was parked when the collector left *before* (else the construction
# did not happen and the arm proves nothing).
private def c89_window(heap : Gcry::Heap, name : Symbol, before : Symbol, after : Symbol,
                       &action : Atomic(Int32) ->) : Bool
  go = Atomic(Int32).new(0)
  parked = Atomic(Int32).new(0)
  released = Atomic(Int32).new(0)
  parked_in_window = Atomic(Int32).new(0)
  armed = Atomic(UInt64).new(0_u64)
  # On the collector's thread, inside the collection: allocates nothing.
  heap.post_stw_hook = ->(stage : Symbol) do
    if stage == before && go.get == 0
      go.set(1)
      deadline = Time.instant + 10.seconds
      until parked.get == 1 || Time.instant >= deadline
        Intrinsics.pause
      end
      parked_in_window.set(parked.get)
    elsif stage == after && go.get == 1
      released.set(1)
    end
    nil
  end
  # Called with whatever lock the write holds, by every thread: parks only
  # the armed thread, and allocates nothing.
  Gcry::Heap.shared_counter_hook = ->(which : Symbol) do
    id = armed.get
    if which == name && parked.get == 0 && id != 0 && Thread.current.object_id == id
      parked.set(1)
      deadline = Time.instant + 10.seconds
      while released.get == 0 && Time.instant < deadline
        Intrinsics.pause
      end
    end
    nil
  end

  thread = Thread.new do
    deadline = Time.instant + 20.seconds
    until go.get == 1 || Time.instant >= deadline
      Intrinsics.pause
    end
    # Armed only now: nothing the thread wrote before the stage is under test.
    if go.get == 1
      armed.set(Thread.current.object_id)
      action.call(parked)
    end
  end
  GC.collect
  thread.join
  Gcry::Heap.shared_counter_hook = nil
  heap.post_stw_hook = nil
  parked_in_window.get == 1
end

# `@large_alloc_since_major`: large bytes counted before the major; the
# thread's large allocation (`alloc_large`'s add, under `@alloc_lock`) parks
# across the take. Returns the counter, what it held before, and the one
# allocation's bytes.
private def c89_since_arm(heap : Gcry::Heap) : {Bool, UInt64, UInt64, UInt64}
  start = c89_since(heap)
  keep = [GC.malloc(C89_LARGE_BYTES)]
  one = c89_since(heap) &- start
  one.should be > 0
  keep << GC.malloc(C89_LARGE_BYTES)
  stale = c89_since(heap)
  stale.should be > one
  taken = Atomic(UInt64).new(0_u64)
  parked = c89_window(heap, :large_since, :before_large_take, :after_large_take) do |_|
    taken.set(GC.malloc(C89_LARGE_BYTES).address)
  end
  taken.get.should_not eq(0)
  keep.size.should eq(2)
  {parked, c89_since(heap), stale, one}
end

# `@large_cache_hits`: one hit counted before the major, and a block of the
# same size cached; the thread's allocation takes it (`take_large_free`'s
# add, under `@alloc_lock`) and parks across the take.
private def c89_hits_arm(heap : Gcry::Heap) : {Bool, UInt64, UInt64}
  first = GC.malloc(C89_LARGE_BYTES)
  GC.free(first)
  again = GC.malloc(C89_LARGE_BYTES)
  stale = heap.large_cache_hits
  stale.should be > 0
  GC.free(again)
  (heap.large_free_bytes > 0).should be_true
  taken = Atomic(UInt64).new(0_u64)
  parked = c89_window(heap, :large_hits, :before_large_take, :after_large_take) do |_|
    taken.set(GC.malloc(C89_LARGE_BYTES).address)
  end
  taken.get.should_not eq(0)
  {parked, heap.large_cache_hits, stale}
end

# `@large_cache_misses`: misses counted before the major, the cache emptied;
# the thread's allocation misses (`alloc_large`'s add, under `@alloc_lock`)
# and parks across the take.
private def c89_misses_arm(heap : Gcry::Heap) : {Bool, UInt64, UInt64}
  keep = [GC.malloc(C89_MISS_BYTES), GC.malloc(C89_MISS_BYTES)]
  heap.trim_large_cache(0_u64, defer: false)
  heap.large_free_bytes.should eq(0)
  stale = heap.large_cache_misses
  stale.should be > 0
  taken = Atomic(UInt64).new(0_u64)
  parked = c89_window(heap, :large_misses, :before_large_take, :after_large_take) do |_|
    taken.set(GC.malloc(C89_MISS_BYTES).address)
  end
  taken.get.should_not eq(0)
  keep.size.should eq(2)
  {parked, heap.large_cache_misses, stale}
end

# `@large_recycle_budget`: a stale budget before the collection, which sets
# it to 0 (no recycling); the thread's refill maps a size-class chunk
# (`map_chunk`'s subtraction, under the class lock only) and parks across
# the set. Returns the budget after.
private def c89_budget_arm(heap : Gcry::Heap) : {Bool, UInt64}
  heap.large_recycle_budget = C89_STALE_BUDGET
  taken = [] of Void*
  parked = c89_window(heap, :large_budget, :before_large_budget, :after_large_budget) do |p|
    # The class's chunks fill within a few blocks, and the refill after
    # them maps one.
    64.times do
      break if p.get == 1
      taken << GC.malloc(C89_CHUNK_CLASS)
    end
  end
  taken.size.should be > 0
  {parked, heap.large_recycle_budget}
end

describe "Regression: the collector's large-cache counter resets are not lost to a running allocation" do
  C89_COUNTERS.each do |counter|
    {"fixed", "control"}.each do |arm|
      it "#{counter} #{arm} arm in a process of its own" do
        captured = IO::Memory.new
        env = {"GCRY_LARGE_COUNTER_CHILD" => "#{counter}-#{arm}"} of String => String?
        status = Process.run(Process.executable_path.not_nil!, ["-e", "large-counter child #{counter} #{arm}"],
          env: env, output: captured, error: captured)
        fail "child #{status.inspect}:\n#{captured}" unless status.success?
        if arm == "control"
          captured.to_s.should contain("counter89: control lost the collector's #{counter} reset")
        else
          captured.to_s.should contain("1 examples, 0 failures")
        end
      end
    end
  end

  it "large-counter child since fixed" do
    next unless ENV["GCRY_LARGE_COUNTER_CHILD"]? == "since-fixed"
    heap = c89_heap("fixed")
    parked, since, _, one = c89_since_arm(heap)
    parked.should be_true
    # The major's zero, then the parked allocation.
    since.should eq(one)
  end

  it "large-counter child since control" do
    next unless ENV["GCRY_LARGE_COUNTER_CHILD"]? == "since-control"
    heap = c89_heap("control")
    parked, since, stale, one = c89_since_arm(heap)
    parked.should be_true
    # The cycle before's bytes came back over the zero.
    since.should eq(stale &+ one)
    STDOUT.puts "counter89: control lost the collector's since reset (since=#{since}, before=#{stale}, parked=#{one})"
    STDOUT.flush
  end

  it "large-counter child hits fixed" do
    next unless ENV["GCRY_LARGE_COUNTER_CHILD"]? == "hits-fixed"
    heap = c89_heap("fixed")
    parked, hits, _ = c89_hits_arm(heap)
    parked.should be_true
    hits.should eq(1)
  end

  it "large-counter child hits control" do
    next unless ENV["GCRY_LARGE_COUNTER_CHILD"]? == "hits-control"
    heap = c89_heap("control")
    parked, hits, stale = c89_hits_arm(heap)
    parked.should be_true
    hits.should eq(stale &+ 1)
    STDOUT.puts "counter89: control lost the collector's hits reset (hits=#{hits}, before=#{stale})"
    STDOUT.flush
  end

  it "large-counter child misses fixed" do
    next unless ENV["GCRY_LARGE_COUNTER_CHILD"]? == "misses-fixed"
    heap = c89_heap("fixed")
    parked, misses, _ = c89_misses_arm(heap)
    parked.should be_true
    misses.should eq(1)
  end

  it "large-counter child misses control" do
    next unless ENV["GCRY_LARGE_COUNTER_CHILD"]? == "misses-control"
    heap = c89_heap("control")
    parked, misses, stale = c89_misses_arm(heap)
    parked.should be_true
    misses.should eq(stale &+ 1)
    STDOUT.puts "counter89: control lost the collector's misses reset (misses=#{misses}, before=#{stale})"
    STDOUT.flush
  end

  it "large-counter child budget fixed" do
    next unless ENV["GCRY_LARGE_COUNTER_CHILD"]? == "budget-fixed"
    heap = c89_heap("fixed")
    parked, budget = c89_budget_arm(heap)
    parked.should be_true
    # The collection's 0, and the parked chunk's subtraction saturating there.
    budget.should eq(0)
  end

  it "large-counter child budget control" do
    next unless ENV["GCRY_LARGE_COUNTER_CHILD"]? == "budget-control"
    heap = c89_heap("control")
    parked, budget = c89_budget_arm(heap)
    parked.should be_true
    # The stale budget less the one chunk, stored over the collection's 0.
    budget.should be > C89_STALE_BUDGET // 2
    budget.should be < C89_STALE_BUDGET
    STDOUT.puts "counter89: control lost the collector's budget reset (budget=#{budget}, before=#{C89_STALE_BUDGET})"
    STDOUT.flush
  end
end
