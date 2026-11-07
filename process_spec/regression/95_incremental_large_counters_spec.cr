require "../../src/gcry"
require "spec"

# A stop-the-world major takes the large-cache counters after its flushes:
# `@large_alloc_since_major` and `@large_cache_hits`/`_misses` are swapped to
# zero (the first sizes what recycling keeps, the other two move the
# adaptive retain) and `@large_recycle_budget` is set to what the cache
# holds, or 0. An incremental cycle (`GCRY_INCREMENTAL=1`) is a major too,
# and its finishing slice only trimmed the cache: the counts carried over
# from cycle to cycle, so the next stop-the-world major read the sum of
# every sliced cycle's since it, and the budget stayed the last one's. The
# finishing slice now runs the same code (`Heap#settle_large_cache`), which
# keeps a cycle's large frees for recycling only when a page barrier does not
# stop `Heap#recycle_large_mapping` from taking them, and under
# `GCRY_INCREMENTAL=1` one is always armed between cycles.
#
# Deterministic: the child runs one whole incremental cycle from this thread,
# `incremental_auto` on as `GCRY_INCREMENTAL=1` sets it, with nothing else
# allocating large blocks. Two windows:
#
# - *counters*, no recycling: a large allocation, a cache hit and a miss
#   counted and a budget planted far from anything a collection writes. The
#   fixed arm must find all four reset (the budget to 0).
# - *recycle*, recycling on: large blocks left unreachable for the cycle's
#   sweep to cache, and the planted budget. The fixed arm must find the
#   swept blocks trimmed and the budget 0 — kept, as a major without a
#   barrier keeps them, the budget would be their bytes.
#
# The control arm (`Heap#inc_finish_large_settle = false`, the code before)
# must find the counters and the budget as they were, or the fixed arm passes
# on nothing.
#
# A third window, *minor*, pins what the barrier condition must not touch: a
# minor collection (nursery, `-Dgcry_block_headers`) under an armed barrier
# keeps the program's own large frees, which `alloc_large` takes back in
# place under any barrier (`bench/gzip_free_loop.cr`). The first version of
# the condition applied to minors too and trimmed them at every minor. Its
# fixed arm must find a `GC.free`d block still cached after a minor; its
# control arm runs a major on the same construction, which trims the cache
# to 0 first, and must find the block gone, or the fixed arm passes on an
# instrument that sees nothing.
#
# Each arm runs in a process of its own. A heap that cannot reach its window
# (no page barrier, Linux only as regression 85; no nursery without block
# headers) prints `LARGE95_SKIP_MARK` and passes, and the parent then does
# not ask for the control's mark.
# `bench/log/linux/2026-11-02-large-cache-incr/FINDINGS.md`.

private LARGE95_SKIP_MARK    = "large95: this heap cannot reach the window, skipped"
private LARGE95_CONTROL_MARK = "large95: the control arm went wrong"

# Large sizes nothing else in the spec runner asks for.
private C95_HIT_BYTES  = 208 * 1024 + 4096
private C95_MISS_BYTES = 336 * 1024 + 4096
private C95_DEAD_BYTES = 272 * 1024 + 4096
private C95_STALE      = 1_u64 << 40

private def c95_skip : Nil
  STDOUT.puts LARGE95_SKIP_MARK
  STDOUT.flush
end

# Ready the heap for sliced cycles, or nil when it cannot run one. The
# barrier is mprotect, as regressions 83 and 85 use: on Linux it works
# whatever the kernel's soft-dirty does.
private def c95_heap(recycle : Bool) : Gcry::Heap?
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    heap.prefer_mprotect_barrier = true
    heap.incremental_auto = true
    heap.large_recycle = recycle
    heap
  {% else %}
    nil
  {% end %}
end

private def c95_since(heap : Gcry::Heap) : UInt64
  heap.@large_alloc_since_major.get
end

private record C95Counters, since : UInt64, hits : UInt64, misses : UInt64, budget : UInt64,
  cache : UInt64, mapped : UInt64

private def c95_counters(heap : Gcry::Heap) : C95Counters
  C95Counters.new(c95_since(heap), heap.large_cache_hits, heap.large_cache_misses,
    heap.large_recycle_budget, heap.large_free_bytes, heap.chunks_mapped)
end

# The control's budget, from the cycle's `Start` to its `End`. The finish it
# runs writes no budget, so the planted value is there at `End`, less only
# what chunks mapped meanwhile spent (`map_chunk`, saturating, and
# `chunks_mapped` counts every such mapping; the large paths that spend it
# also move `since`, which the control holds equal). With no chunk mapped it
# is the same to the byte. Sometimes one is mapped, 128 KiB, by *another*
# thread with the world running between slices (`heap_resize_hook` probe:
# 39 of 1 200 children in the full block-headers suite binary, never this
# thread, never in a stop); then the budget must have dropped and still be
# the planted value's, which nothing a finish that sets it writes can be: 0,
# or the cache's bytes.
private def c95_budget_kept(before : C95Counters, after : C95Counters) : Nil
  if after.mapped == before.mapped
    after.budget.should eq(before.budget)
  else
    after.budget.should be < before.budget
    after.budget.should be > C95_STALE // 2
  end
end

# Runs one whole incremental cycle and returns the counters as its `Start`
# event saw them and as its `End` event did, or nil when no cycle began. Any
# cycle an allocation had started is finished first.
#
# Read by `collection_event_hook`, on this thread inside the cycle: `Start`
# fires in `begin_incremental`, `End` after the finish's large-cache passes,
# and between the two this thread runs only `collect_a_little`. Read before
# and after the cycle instead, as until 2026-11-01, the control's budget
# equality also took in the spec's own allocations and any other thread's,
# and read the planted 2^40 less 128 KiB once in about 45 block-headers
# suite runs.
private def c95_cycle(heap : Gcry::Heap) : {C95Counters, C95Counters}?
  10_000.times do
    break unless heap.incremental_in_progress?
    heap.collect_a_little
  end
  majors = heap.major_collections
  zero = C95Counters.new(0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64)
  at = StaticArray(C95Counters, 2).new(zero)
  seen = StaticArray(Bool, 2).new(false)
  at_ptr = at.to_unsafe
  seen_ptr = seen.to_unsafe
  saved = heap.collection_event_hook
  # Inside the collection: allocates nothing (a record is a value).
  heap.collection_event_hook = ->(event : Gcry::Heap::CollectionEvent) do
    i = event.start? ? 0 : (event.end? ? 1 : -1)
    if i >= 0 && !seen_ptr[i]
      at_ptr[i] = c95_counters(heap)
      seen_ptr[i] = true
    end
    nil
  end
  finished = heap.collect_a_little
  began = finished || heap.incremental_in_progress?
  10_000.times do
    break if finished || !began
    finished = heap.collect_a_little
  end
  heap.collection_event_hook = saved
  return nil unless began
  fail "the incremental cycle never finished" unless finished
  # One major, and it was the sliced one, seen at both ends.
  (heap.major_collections - majors).should eq(1)
  seen[0].should be_true
  seen[1].should be_true
  {at[0], at[1]}
end

# *counters*: counts a miss, a hit and large bytes, plants the budget, then
# runs the cycle. The counters at its start and end, or nil.
private def c95_counters_window(heap : Gcry::Heap) : {C95Counters, C95Counters}?
  keep = [GC.malloc(C95_MISS_BYTES)]
  first = GC.malloc(C95_HIT_BYTES)
  GC.free(first)
  keep << GC.malloc(C95_HIT_BYTES)
  heap.large_recycle_budget = C95_STALE
  window = c95_cycle(heap)
  keep.size.should eq(2)
  return nil unless window
  start, _ = window
  start.since.should be > 0
  start.hits.should be > 0
  start.misses.should be > 0
  # Planted, less at most what the spec mapped before the cycle began.
  start.budget.should be > C95_STALE // 2
  window
end

# Large blocks nothing refers to once this frame returns.
@[NoInline]
private def c95_drop_large : Nil
  8.times { GC.malloc(C95_DEAD_BYTES) }
end

# *recycle*: drops large blocks, plants the budget, then runs the cycle.
# Returns what the cache held after the flushes (seen at the first counter
# stage; 0 when the finish never reached it) and the counters at the cycle's
# start and end, or nil.
private def c95_recycle_window(heap : Gcry::Heap) : {UInt64, C95Counters, C95Counters}?
  c95_drop_large
  heap.large_recycle_budget = C95_STALE
  flushed = Atomic(UInt64).new(0_u64)
  # On the collector's thread, inside the collection: allocates nothing.
  heap.post_stw_hook = ->(stage : Symbol) do
    flushed.set(heap.large_free_bytes) if stage == :before_large_take
    nil
  end
  window = c95_cycle(heap)
  heap.post_stw_hook = nil
  return nil unless window
  start, finish = window
  start.budget.should be > C95_STALE // 2
  {flushed.get, start, finish}
end

private C95_FREED_BYTES = 304 * 1024 + 4096

# A nursery heap with recycling, or nil when it cannot have one (headerless
# layout, or off Linux). The barrier is whatever the heap picks, soft-dirty
# where the kernel has it: the nursery under the mprotect barrier crashes in
# a minor after a large `GC.free`, on 0.40.0's base as well (reported, not
# this window's subject).
private def c95_minor_heap : Gcry::Heap?
  {% if flag?(:linux) && flag?(:gcry_block_headers) %}
    heap = Gcry.default_heap
    heap.large_recycle = true
    heap.nursery_enabled = true
    heap.nursery_enabled ? heap : nil
  {% else %}
    nil
  {% end %}
end

# *minor*: a minor first, which arms the barrier; then the program frees a
# large block of its own, and a minor (or, for the control, a major) runs.
# Returns what the cache held before and after that collection, or nil when
# no barrier was armed (the window needs one).
private def c95_minor_window(heap : Gcry::Heap, major : Bool) : {UInt64, UInt64}?
  heap.minor_collect
  return nil if heap.@barrier_backend.none?
  p = GC.malloc(C95_FREED_BYTES)
  GC.free(p)
  before = heap.large_free_bytes
  before.should be >= C95_FREED_BYTES
  collections = heap.collections
  majors = heap.major_collections
  if major
    GC.collect
  else
    heap.minor_collect
    (heap.major_collections - majors).should eq(0)
  end
  (heap.collections - collections).should eq(1)
  heap.@barrier_backend.none?.should be_false
  {before, heap.large_free_bytes}
end

describe "Regression: the incremental cycle's finish takes the large-cache counters as a major does" do
  {"counters", "recycle", "minor"}.each do |window|
    {"fixed", "control"}.each do |arm|
      it "#{window} #{arm} arm in a process of its own" do
        captured = IO::Memory.new
        env = {"GCRY_LARGE95_CHILD" => "#{window}-#{arm}"} of String => String?
        status = Process.run(Process.executable_path.not_nil!, ["-e", "large95 child #{window} #{arm}"],
          env: env, output: captured, error: captured)
        text = captured.to_s
        fail "child #{status.inspect}:\n#{text}" unless status.success?
        text.should contain("1 examples, 0 failures")
        if arm == "control" && !text.includes?(LARGE95_SKIP_MARK)
          text.should contain(LARGE95_CONTROL_MARK)
        end
      end
    end
  end

  it "large95 child counters fixed" do
    next unless ENV["GCRY_LARGE95_CHILD"]? == "counters-fixed"
    next c95_skip unless heap = c95_heap(false)
    next c95_skip unless window = c95_counters_window(heap)
    _, after = window
    # At the cycle's `End`: the finish took the counts and set the budget.
    after.since.should eq(0)
    after.hits.should eq(0)
    after.misses.should eq(0)
    after.budget.should eq(0)
  end

  it "large95 child counters control" do
    next unless ENV["GCRY_LARGE95_CHILD"]? == "counters-control"
    next c95_skip unless heap = c95_heap(false)
    heap.inc_finish_large_settle = false
    next c95_skip unless window = c95_counters_window(heap)
    before, after = window
    # Start to `End` of the cycle, with nothing but the cycle running.
    after.since.should eq(before.since)
    after.hits.should eq(before.hits)
    after.misses.should eq(before.misses)
    c95_budget_kept(before, after)
    STDOUT.puts "#{LARGE95_CONTROL_MARK} (since=#{after.since}, hits=#{after.hits}, misses=#{after.misses}, budget=#{after.budget}, chunks mapped in the cycle=#{after.mapped - before.mapped})"
    STDOUT.flush
  end

  it "large95 child recycle fixed" do
    next unless ENV["GCRY_LARGE95_CHILD"]? == "recycle-fixed"
    next c95_skip unless heap = c95_heap(true)
    next c95_skip unless window = c95_recycle_window(heap)
    flushed, _, after = window
    # The sweep cached dead blocks, and the finish did not keep them.
    flushed.should be >= C95_DEAD_BYTES
    after.cache.should be <= heap.large_cache_retain
    after.budget.should eq(0)
  end

  it "large95 child recycle control" do
    next unless ENV["GCRY_LARGE95_CHILD"]? == "recycle-control"
    next c95_skip unless heap = c95_heap(true)
    heap.inc_finish_large_settle = false
    next c95_skip unless window = c95_recycle_window(heap)
    _, before, after = window
    c95_budget_kept(before, after)
    STDOUT.puts "#{LARGE95_CONTROL_MARK} (budget=#{after.budget}, chunks mapped in the cycle=#{after.mapped - before.mapped})"
    STDOUT.flush
  end

  it "large95 child minor fixed" do
    next unless ENV["GCRY_LARGE95_CHILD"]? == "minor-fixed"
    next c95_skip unless heap = c95_minor_heap
    next c95_skip unless window = c95_minor_window(heap, major: false)
    before, after = window
    # The program's own free is still there for `alloc_large` to take.
    after.should eq(before)
  end

  it "large95 child minor control" do
    next unless ENV["GCRY_LARGE95_CHILD"]? == "minor-control"
    next c95_skip unless heap = c95_minor_heap
    next c95_skip unless window = c95_minor_window(heap, major: true)
    before, after = window
    after.should be < C95_FREED_BYTES
    STDOUT.puts "#{LARGE95_CONTROL_MARK} (the major trimmed the cache: #{before} -> #{after})"
    STDOUT.flush
  end
end
