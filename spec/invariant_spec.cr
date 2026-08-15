require "./spec_helper"

describe Gcry::Invariant do
  it "is disabled by default" do
    # When GCRY_DEBUG_INVARIANTS is not set, the module starts disabled.
    unless ENV["GCRY_DEBUG_INVARIANTS"]? == "1"
      Gcry::Invariant.enabled?.should be_false
    end
  end

  it "can be enabled and disabled" do
    Gcry::Invariant.enable
    Gcry::Invariant.enabled?.should be_true
    Gcry::Invariant.disable
    Gcry::Invariant.enabled?.should be_false
  end

  it "passes check_live_objects on a fresh heap" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        Gcry::Invariant.check_live_objects(heap)
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end

  it "passes after_malloc and after_free on simple alloc/free cycle" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        ptr = heap.malloc(64)
        ptr.should_not be_nil
        heap.free(ptr)
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end

  it "passes after_collect on a heap with live objects" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        ptr = heap.malloc(128)
        ptr.should_not be_nil
        heap.add_root(ptr)
        heap.collect
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end

  it "passes freelist checks after alloc/free cycles" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        ptrs = [] of Void*
        10.times { ptrs << heap.malloc(32) }
        ptrs.each { |p| heap.free(p) }
        Gcry::Invariant.check_all_freelists(heap)
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end

  # `make invariants` failed here for three releases, and was carried as a Darwin
  # problem: the walk counted every block of a chunk the sweep had made dormant,
  # because a dormant chunk's headers have been advised away and read as neither
  # used nor FREE (Linux zeroes them, Darwin leaves them stale). Same collection
  # as spec/collect_spec.cr:202, with the checker on: 6 501 counted against
  # live_objects = 1. The `dormant_chunk_bytes` assertion is what keeps this from
  # passing vacuously if the sweep stops producing dormant chunks.
  it "does not count blocks in chunks the sweep made dormant" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        heap.gc_threshold = UInt64::MAX
        heap.release_empty_chunks = true
        heap.empty_chunk_retain = UInt64::MAX
        heap.nursery_enabled = false

        keep = heap.malloc(64)
        heap.add_root(keep)
        8_000.times { heap.malloc(64) }
        heap.collect(scan_stack: false)

        heap.dormant_chunk_bytes.should be > 0
        heap.live_objects.should eq(1)
        Gcry::Invariant.check_live_objects(heap)
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end

  # The other half of the same failure: `after_malloc` runs outside the
  # allocation lock, so with a second mutator thread the walk and the counter are
  # two different instants (measured `actual=40 reported=41` in mt_spec). The
  # check is skipped there, and the skip is counted rather than silent.
  it "skips the live-object walk while another thread can allocate" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        stop = Atomic(Int32).new(0)
        started = Atomic(Int32).new(0)
        # Two extra threads: multi_mutator_threads? trips above main + one.
        workers = Array(Thread).new(2) do
          Thread.new do
            started.add(1)
            while stop.get == 0
            end
          end
        end
        while started.get < 2
        end

        before = Gcry::Invariant.concurrent_skips
        heap.malloc(64)
        Gcry::Invariant.concurrent_skips.should be > before

        stop.set(1)
        workers.each(&.join)
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end

  it "passes hooks (malloc/free/collect) with invariants enabled" do
    Gcry::Invariant.enable
    begin
      heap = Gcry::Heap.new
      begin
        ptr = heap.malloc(64)
        ptr.should_not be_nil
        heap.free(ptr)

        ptr2 = heap.malloc(256)
        heap.add_root(ptr2)
        heap.collect
      ensure
        heap.destroy
      end
    ensure
      Gcry::Invariant.disable
    end
  end
end
