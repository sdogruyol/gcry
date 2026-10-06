require "../../src/gcry"
require "spec"

# Boehm's collection entry points against what Boehm does with them (PR #44
# review). `GC_collect_a_little` returned 1 when a cycle *finished* — the
# inverse of Boehm, whose result is "an incremental collection is still in
# progress" — so `while (GC_collect_a_little()) {}` either stopped at once or,
# called until it said 0, started a fresh cycle on every call. It ignored
# `GC_disable`. And `GC_gcollect` / `GC.collect` collected while collection
# was disabled, where Boehm's `GC_try_to_collect_inner` returns at
# `GC_dont_gc`.

# Allocates past the heap's threshold with collection disabled, so a
# collection is due the moment it is enabled again. libc-free: only `LibGC`
# calls and plain loops, so nothing here allocates once the debt is built.
private def build_debt(heap) : Nil
  sink = Pointer(Void).null
  while heap.bytes_since_gc < heap.gc_threshold
    sink = LibGC.malloc_atomic(64 * 1024)
  end
  sink.null?.should be_false
end

describe "GC_collect_a_little (Boehm parity)" do
  it "returns 0 and collects nothing when no collection is due, so a loop on it finishes" do
    heap = Gcry.default_heap
    LibGC.collect
    before = heap.collections
    calls = 0
    while LibGC.collect_a_little != 0
      calls += 1
      break if calls > 10_000
    end
    calls.should eq(0)
    heap.collections.should eq(before)
  end

  it "runs the collection allocation would have run once it is due, then returns 0" do
    heap = Gcry.default_heap
    LibGC.disable
    begin
      build_debt(heap)
    ensure
      LibGC.enable
    end
    before = heap.collections
    result = LibGC.collect_a_little
    heap.collections.should be > before
    result.should eq(0)
    LibGC.collect_a_little.should eq(0)
  end

  # The in-progress answer: with sliced majors on, a due collection starts a
  # cycle, every call is one slice, and the loop ends when the cycle does.
  # Where no page-dirty barrier can be armed the cycle cannot start and the
  # call is the full collection instead; the loop must end either way.
  it "is 1 only while a sliced cycle is in progress, and a loop on it ends with the cycle" do
    heap = Gcry.default_heap
    saved = heap.incremental_auto
    saved_work = heap.incremental_work
    heap.incremental_auto = true
    # Small slices, so the cycle spans several calls (two at 16 on Linux's
    # soft-dirty barrier; the default 1024 finishes this heap in one).
    heap.incremental_work = 16
    begin
      LibGC.disable
      begin
        build_debt(heap)
      ensure
        LibGC.enable
      end
      before = heap.collections
      calls = 0
      while LibGC.collect_a_little != 0
        heap.incremental_in_progress?.should be_true
        calls += 1
        break if calls > 100_000
      end
      calls.should be <= 100_000
      heap.incremental_in_progress?.should be_false
      heap.collections.should be > before
    ensure
      heap.incremental_auto = saved
      heap.incremental_work = saved_work
    end
  end

  it "does nothing and returns 0 while collection is disabled" do
    heap = Gcry.default_heap
    LibGC.disable
    begin
      build_debt(heap)
      before = heap.collections
      LibGC.collect_a_little.should eq(0)
      GC.collect_a_little.should eq(0)
      heap.collections.should eq(before)
    ensure
      LibGC.enable
    end
  end
end

describe "GC_gcollect / GC.collect while disabled (Boehm parity)" do
  it "collect nothing until collection is enabled again" do
    heap = Gcry.default_heap
    GC.disable
    begin
      before = heap.collections
      GC.collect
      LibGC.collect
      heap.collections.should eq(before)
    ensure
      GC.enable
    end
    before = heap.collections
    GC.collect
    heap.collections.should be > before
  end

  it "nest: an inner enable leaves an explicit collection refused" do
    heap = Gcry.default_heap
    LibGC.disable
    LibGC.disable
    LibGC.enable
    begin
      before = heap.collections
      LibGC.collect
      heap.collections.should eq(before)
    ensure
      LibGC.enable
    end
  end
end
