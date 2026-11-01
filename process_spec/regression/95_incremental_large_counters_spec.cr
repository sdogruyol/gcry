require "../../src/gcry"
require "spec"

# A stop-the-world major takes the large-cache counters after its flushes:
# `@large_alloc_since_major` and `@large_cache_hits`/`_misses` are swapped to
# zero (the first sizes what recycling keeps, the other two move the
# adaptive retain) and `@large_recycle_budget` is set to what the cache
# holds, or 0. An incremental cycle (`GCRY_INCREMENTAL=1`) is a major too,
# and its finishing slice only trimmed the cache: the counts carried over
# from cycle to cycle, so the next stop-the-world major read the sum of
# every sliced cycle's since it, and the budget stayed the last one's.
# The finishing slice now runs the same code (`Heap#settle_large_cache`).
#
# Deterministic: the child counts a large allocation, a cache hit and a miss
# and plants a budget far from anything a collection writes, then runs one
# whole incremental cycle from this thread with nothing else allocating
# large blocks. The fixed arm must find the four reset; the control arm
# (`Heap#inc_finish_large_settle = false`, the code before) must find all
# four as they were, or the fixed arm passes on nothing. Each arm runs in a
# process of its own. A heap that cannot run a sliced cycle (no page barrier;
# Linux only, as regression 85) prints `LARGE95_SKIP_MARK` and passes, and
# the parent then does not ask for the control's mark.
# `bench/log/linux/2026-11-02-large-cache-incr/FINDINGS.md`.

private LARGE95_SKIP_MARK    = "large95: this heap cannot run a sliced cycle, skipped"
private LARGE95_CONTROL_MARK = "large95: control carried the large-cache counters over"

# Large sizes nothing else in the spec runner asks for.
private C95_HIT_BYTES  = 208 * 1024 + 4096
private C95_MISS_BYTES = 336 * 1024 + 4096
private C95_STALE      = 1_u64 << 40

private def c95_skip : Nil
  STDOUT.puts LARGE95_SKIP_MARK
  STDOUT.flush
end

# Ready the heap for a sliced cycle; false when it cannot run one. The
# barrier is mprotect, as regressions 83 and 85 use: on Linux it works
# whatever the kernel's soft-dirty does. No recycling, so the budget a
# collection writes is 0 and the cache is left alone until the counts are
# taken.
private def c95_heap : Gcry::Heap?
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    heap.prefer_mprotect_barrier = true
    heap.large_recycle = false
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

# Counts a miss, a hit and large bytes, plants the budget, then runs one
# whole incremental cycle. Returns the counters before and after the cycle,
# or nil when no sliced cycle began.
private def c95_window(heap : Gcry::Heap) : {C95Counters, C95Counters}?
  keep = [GC.malloc(C95_MISS_BYTES)]
  first = GC.malloc(C95_HIT_BYTES)
  GC.free(first)
  keep << GC.malloc(C95_HIT_BYTES)
  heap.large_recycle_budget = C95_STALE
  before = c95_counters(heap)
  before.since.should be > 0
  before.hits.should be > 0
  before.misses.should be > 0
  majors = heap.major_collections
  finished = heap.collect_a_little
  return nil unless finished || heap.incremental_in_progress?
  10_000.times do
    break if finished
    finished = heap.collect_a_little
  end
  fail "the incremental cycle never finished" unless finished
  # One major, and it was the sliced one.
  (heap.major_collections - majors).should eq(1)
  after = c95_counters(heap)
  keep.size.should eq(2)
  {before, after}
end

describe "Regression: the incremental cycle's finish takes the large-cache counters as a major does" do
  {"fixed", "control"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      captured = IO::Memory.new
      env = {"GCRY_LARGE95_CHILD" => arm} of String => String?
      status = Process.run(Process.executable_path.not_nil!, ["-e", "large95 child #{arm}"],
        env: env, output: captured, error: captured)
      text = captured.to_s
      fail "child #{status.inspect}:\n#{text}" unless status.success?
      text.should contain("1 examples, 0 failures")
      if arm == "control" && !text.includes?(LARGE95_SKIP_MARK)
        text.should contain(LARGE95_CONTROL_MARK)
      end
    end
  end

  it "large95 child fixed" do
    next unless ENV["GCRY_LARGE95_CHILD"]? == "fixed"
    next c95_skip unless heap = c95_heap
    next c95_skip unless window = c95_window(heap)
    _, after = window
    after.since.should eq(0)
    after.hits.should eq(0)
    after.misses.should eq(0)
    after.budget.should eq(0)
  end

  it "large95 child control" do
    next unless ENV["GCRY_LARGE95_CHILD"]? == "control"
    next c95_skip unless heap = c95_heap
    heap.inc_finish_large_settle = false
    next c95_skip unless window = c95_window(heap)
    before, after = window
    after.since.should eq(before.since)
    after.hits.should eq(before.hits)
    after.misses.should eq(before.misses)
    after.budget.should eq(before.budget)
    STDOUT.puts "#{LARGE95_CONTROL_MARK} (since=#{after.since}, hits=#{after.hits}, misses=#{after.misses}, budget=#{after.budget})"
    STDOUT.flush
  end
end
