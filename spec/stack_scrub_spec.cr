require "./spec_helper"

describe "Gcry stack scrub" do
  it "clear_stack zeros below SP without killing live roots" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.clear_stack_enabled = true
      heap.clear_stack_bytes = 1024
      keep = heap.malloc(32)
      heap.add_root(keep)
      before = heap.clear_stack_calls
      heap.clear_stack(1024)
      heap.clear_stack_calls.should be > before
      heap.collect(scan_stack: false)
      heap.live?(keep).should be_true
    ensure
      heap.destroy
    end
  end

  it "scrub_parked_fiber_stacks runs when enabled" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.scrub_fibers_enabled = true
      keep = heap.malloc(16)
      heap.add_root(keep)
      before = heap.fiber_scrub_runs
      heap.collect(scan_stack: true)
      heap.fiber_scrub_runs.should be > before
      heap.live?(keep).should be_true
    ensure
      heap.destroy
    end
  end

  it "scrub_parked_fiber_stacks is a no-op when scrub disabled" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.scrub_fibers_enabled = false
      keep = heap.malloc(16)
      heap.add_root(keep)
      before_fiber = heap.fiber_scrub_runs
      before_clear = heap.clear_stack_calls
      heap.collect(scan_stack: true)
      heap.fiber_scrub_runs.should eq before_fiber
      heap.clear_stack_calls.should eq before_clear
      heap.live?(keep).should be_true
    ensure
      heap.destroy
    end
  end

  it "maybe_clear_stack_on_alloc respects clear_stack_every" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.clear_stack_enabled = true
      heap.clear_stack_every = 3
      heap.clear_stack_bytes = 256
      before = heap.clear_stack_calls
      6.times { heap.malloc(8) }
      # roughly every 3rd alloc — at least one call
      heap.clear_stack_calls.should be > before
    ensure
      heap.destroy
    end
  end

  it "clear_stack does not recurse when Fiber.current allocates" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.clear_stack_enabled = true
      heap.clear_stack_bytes = 512
      # Warm Thread/Fiber TLS, then enable-path clear must not SEGV/stack-overflow.
      3.times { heap.malloc(16) }
      heap.clear_stack(512)
      heap.clear_stack_calls.should be > 0
    ensure
      heap.destroy
    end
  end

  it "scrubs its own dead stack at collection entry and exit, accounted apart" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      keep = heap.malloc(16)
      heap.add_root(keep)
      calls = heap.clear_stack_calls
      runs = heap.collect_scrub_runs
      heap.collect(scan_stack: true)
      heap.collect_scrub_runs.should eq runs + 2
      # On the main thread the pthread bounds are known, so both scrubs wipe
      # the full budget; a capped wipe would show here.
      heap.collect_scrub_bytes_total.should eq 2 * heap.collect_scrub_bytes
      heap.clear_stack_calls.should eq calls
      heap.live?(keep).should be_true
    ensure
      heap.destroy
    end
  end

  it "does not scrub when GCRY_COLLECT_SCRUB is 0" do
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      heap.collect_scrub_bytes = 0
      keep = heap.malloc(16)
      heap.add_root(keep)
      heap.collect(scan_stack: true)
      heap.collect_scrub_runs.should eq 0
      heap.collect_scrub_bytes_total.should eq 0
      heap.live?(keep).should be_true
    ensure
      heap.destroy
    end
  end
end
