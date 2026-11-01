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
# on nothing. Each arm runs in a process of its own. A heap that cannot run
# a sliced cycle (no page barrier; Linux only, as regression 85) prints
# `LARGE95_SKIP_MARK` and passes, and the parent then does not ask for the
# control's mark. `bench/log/linux/2026-11-02-large-cache-incr/FINDINGS.md`.

private LARGE95_SKIP_MARK    = "large95: this heap cannot run a sliced cycle, skipped"
private LARGE95_CONTROL_MARK = "large95: control carried the large-cache counters over"

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

private record C95Counters, since : UInt64, hits : UInt64, misses : UInt64, budget : UInt64

private def c95_counters(heap : Gcry::Heap) : C95Counters
  C95Counters.new(c95_since(heap), heap.large_cache_hits, heap.large_cache_misses, heap.large_recycle_budget)
end

# Runs one whole incremental cycle; false when none began. Any cycle an
# allocation had started is finished first.
private def c95_cycle(heap : Gcry::Heap) : Bool
  10_000.times do
    break unless heap.incremental_in_progress?
    heap.collect_a_little
  end
  majors = heap.major_collections
  finished = heap.collect_a_little
  return false unless finished || heap.incremental_in_progress?
  10_000.times do
    break if finished
    finished = heap.collect_a_little
  end
  fail "the incremental cycle never finished" unless finished
  # One major, and it was the sliced one.
  (heap.major_collections - majors).should eq(1)
  true
end

# *counters*: counts a miss, a hit and large bytes, plants the budget, then
# runs the cycle. The counters before and after it, or nil.
private def c95_counters_window(heap : Gcry::Heap) : {C95Counters, C95Counters}?
  keep = [GC.malloc(C95_MISS_BYTES)]
  first = GC.malloc(C95_HIT_BYTES)
  GC.free(first)
  keep << GC.malloc(C95_HIT_BYTES)
  heap.large_recycle_budget = C95_STALE
  before = c95_counters(heap)
  before.since.should be > 0
  before.hits.should be > 0
  before.misses.should be > 0
  return nil unless c95_cycle(heap)
  after = c95_counters(heap)
  keep.size.should eq(2)
  {before, after}
end

# Large blocks nothing refers to once this frame returns.
@[NoInline]
private def c95_drop_large : Nil
  8.times { GC.malloc(C95_DEAD_BYTES) }
end

# *recycle*: drops large blocks, plants the budget, then runs the cycle.
# Returns what the cache held after the flushes (seen at the first counter
# stage; 0 when the finish never reached it), the cache and the budget after
# the cycle, or nil.
private def c95_recycle_window(heap : Gcry::Heap) : {UInt64, UInt64, UInt64}?
  c95_drop_large
  heap.large_recycle_budget = C95_STALE
  flushed = Atomic(UInt64).new(0_u64)
  # On the collector's thread, inside the collection: allocates nothing.
  heap.post_stw_hook = ->(stage : Symbol) do
    flushed.set(heap.large_free_bytes) if stage == :before_large_take
    nil
  end
  ran = c95_cycle(heap)
  heap.post_stw_hook = nil
  return nil unless ran
  {flushed.get, heap.large_free_bytes, heap.large_recycle_budget}
end

describe "Regression: the incremental cycle's finish takes the large-cache counters as a major does" do
  {"counters", "recycle"}.each do |window|
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
    after.since.should eq(before.since)
    after.hits.should eq(before.hits)
    after.misses.should eq(before.misses)
    after.budget.should eq(before.budget)
    STDOUT.puts "#{LARGE95_CONTROL_MARK} (since=#{after.since}, hits=#{after.hits}, misses=#{after.misses}, budget=#{after.budget})"
    STDOUT.flush
  end

  it "large95 child recycle fixed" do
    next unless ENV["GCRY_LARGE95_CHILD"]? == "recycle-fixed"
    next c95_skip unless heap = c95_heap(true)
    next c95_skip unless window = c95_recycle_window(heap)
    flushed, cached, budget = window
    # The sweep cached dead blocks, and the finish did not keep them.
    flushed.should be >= C95_DEAD_BYTES
    cached.should be <= heap.large_cache_retain
    budget.should eq(0)
  end

  it "large95 child recycle control" do
    next unless ENV["GCRY_LARGE95_CHILD"]? == "recycle-control"
    next c95_skip unless heap = c95_heap(true)
    heap.inc_finish_large_settle = false
    next c95_skip unless window = c95_recycle_window(heap)
    _, _, budget = window
    budget.should eq(C95_STALE)
    STDOUT.puts "#{LARGE95_CONTROL_MARK} (budget=#{budget})"
    STDOUT.flush
  end
end
