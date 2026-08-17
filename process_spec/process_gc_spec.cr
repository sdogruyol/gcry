# Process-GC smoke under `-Dgc_none`.
# Not under `spec/` so default `crystal spec` (Boehm) ignores these.
# Build: crystal spec -Dgc_none process_spec --error-trace

require "spec"
require "http"
require "../src/gcry"

{% unless flag?(:gc_none) %}
  raise "process_spec requires -Dgc_none (gcry as process GC)"
{% end %}

class ProcessGcFinalizable
  @@ran : Atomic(Int32)? = nil

  def self.ran=(v : Atomic(Int32))
    @@ran = v
  end

  def finalize
    @@ran.try &.add(1)
  end
end

describe "process GC (-Dgc_none)" do
  it "reports a version" do
    Gcry::VERSION.should_not be_empty
  end

  it "malloc / malloc_atomic / free via GC" do
    p = GC.malloc(64)
    GC.is_heap_ptr(p).should be_true
    64.times { |i| p.as(UInt8*)[i].should eq(0) }
    GC.free(p)

    a = GC.malloc_atomic(32)
    GC.is_heap_ptr(a).should be_true
    GC.free(a)
  end

  it "realloc preserves contents" do
    p = GC.malloc(16)
    16.times { |i| p.as(UInt8*)[i] = i.to_u8 }
    grown = GC.realloc(p, 128)
    16.times { |i| grown.as(UInt8*)[i].should eq(i.to_u8) }
    GC.free(grown)
  end

  it "collect keeps live Crystal objects" do
    keep = Array(Int32).new(100) { |i| i }
    drop = Array(Int32).new(100) { |i| i * 2 }
    drop = nil
    GC.collect
    keep.sum.should eq((0...100).sum)
  end

  # Crystal prepare_args omitted argv NULL; Boehm over-alloc hid it (#14).
  it "runs Process / command literals (argv NULL terminator)" do
    `echo gcry-process-argv`.should eq("gcry-process-argv\n")
    Process.run("echo", ["direct"], output: Process::Redirect::Pipe) do |proc|
      proc.output.gets_to_end.should eq("direct\n")
    end
    Process.run("echo shell", shell: true, output: Process::Redirect::Pipe) do |proc|
      proc.output.gets_to_end.should eq("shell\n")
    end
  end

  it "alloc storm + periodic collect" do
    live = [] of String
    500.times do |i|
      live << "storm-#{i}-#{"x" * (i % 40)}"
      live.shift if live.size > 40
      GC.collect if i % 100 == 99
    end
    live.size.should be > 0
  end

  it "exposes stats after activity" do
    20.times { String.build { |io| io << "stats" << Random.rand(1000) } }
    GC.collect
    s = GC.stats
    s.heap_size.should be > 0
  end

  it "pause_stats are populated after collect" do
    GC.collect
    ps = Gcry.pause_stats
    ps.count.should be > 0
    ps.last_ns.should be > 0
  end

  it "fibers + collect" do
    ch = Channel(Int32).new
    spawn do
      xs = Array(Int32).new(50) { |i| i }
      GC.collect
      ch.send(xs.sum)
    end
    ch.receive.should eq((0...50).sum)
  end

  it "finalizer path does not crash" do
    ran = Atomic(Int32).new(0)
    ProcessGcFinalizable.ran = ran
    10.times { ProcessGcFinalizable.new }
    GC.collect
    GC.collect
    ran.get.should be >= 0
  end

  it "frequent manual collect under alloc storm" do
    100.times do |i|
      _ = "#{"y" * (i % 20)}-#{i}"
      GC.collect if i % 10 == 0
    end
  end

  it "exposes TLAB / parallel-mark knobs on the process heap" do
    heap = Gcry.default_heap
    heap.should_not be_nil
    h = heap.not_nil!
    h.tlab_enabled?.should be_false # default; GCRY_TLAB=1 enables at init
    h.parallel_mark_workers.should eq(1)
    h.tlab_refills.should eq(0)
  end

  it "registers pthread_atfork by default" do
    Gcry::Platform.atfork_installed?.should be_true
  end
end

{% if flag?(:darwin) %}
  describe "process GC Darwin Mach STW" do
    it "stop_world_threads / start_world_threads round-trip" do
      # Wake ExecutionContext Monitor so STW has another OS thread.
      ch = Channel(Nil).new
      spawn { ch.send(nil) }
      ch.receive

      Gcry::Platform.install_stw_sp_capture
      Gcry::Platform.stw_sp_capture_installed?.should be_true

      current = Thread.current
      Gcry::Platform.stop_world_threads(current)
      begin
        # World is stopped; do not allocate. Resume must succeed.
      ensure
        Gcry::Platform.start_world_threads(current)
        Gcry::Platform.clear_thread_sps
      end

      # Alloc + collect after resume proves threads are live again.
      p = GC.malloc(32)
      GC.is_heap_ptr(p).should be_true
      GC.free(p)
      GC.collect
    end

    it "GC.collect exercises Mach STW SP clamp" do
      # Park a real OS thread (Monitor-only wake races on Darwin CI).
      # Thread.new has no Fiber execution_context — spin on Atomic.
      ready = Atomic(Int32).new(0)
      release = Atomic(Int32).new(0)
      worker = Thread.new do
        ready.set(1)
        while release.get == 0
        end
      end
      until ready.get == 1
      end

      GC.collect
      Gcry::Platform.stw_sp_capture_installed?.should be_true
      h = Gcry.default_heap
      (h.sp_clamp_hits + h.sp_clamp_fallbacks).should be > 0

      # The same thread_get_state feeds the register scan. Until 2026-08-11 it
      # fed only the clamp above: `each_thread_greg` was an empty stub while
      # `collect_scan` called it, so a reference the compiler kept in a register
      # and never spilled had no root and its object was swept. Zero here is
      # what that stub looks like from the outside.
      h.thread_greg_candidates.should be > 0

      # And the table must not outlive the stop: start_world clears it, so no
      # thread can read registers out of it now. A stale slot marked next
      # collection would be naming objects that have since been freed.
      after = 0
      Gcry::Platform.each_thread_greg(worker.to_unsafe) { after += 1 }
      Gcry::Platform.each_thread_greg(Thread.current.to_unsafe) { after += 1 }
      after.should eq(0)

      release.set(1)
      worker.join
    end
  end
{% end %}

describe "process GC realloc" do
  # `Heap#realloc`'s grow path documents, at length, why it must not free the
  # old block: Crystal stores the result *after* realloc returns, so until that
  # store the caller's ivar still holds the old pointer, and freeing it lets a
  # peer collect reuse the block underneath a live owner. The `size == 0` path
  # used to free immediately — the same defect through a second door. It fires
  # zero times in practice, which is why this is a gate on a trap rather than on
  # a live bug.
  it "does not free the old block when reallocating to zero" do
    heap = Gcry.default_heap
    ptr = GC.malloc(256)
    fresh = GC.realloc(ptr, 0)

    info = heap.debug_block_info(ptr)
    info[:found].should be_true
    info[:free].should be_false

    # And it still hands back something usable, so the caller's store is safe.
    fresh.should_not be_nil
  end
end

describe "process GC free-path flag" do
  # `Flags::SWEPT` is what lets a use-after-free report say whether the
  # collector decided the block was garbage or the program asked. It is only
  # worth having if it survives everything that rewrites a free block's header
  # — the freelist *rebuild* paths re-link blocks that are already free, and
  # constructing the header with a bare `FREE` erased the bit. A CI catch on
  # 2026-08-16 was then written up as "an explicit free" and was in fact a
  # swept block whose flag a rebuild had dropped.
  it "marks swept blocks and leaves explicitly freed ones clear" do
    heap = Gcry.default_heap
    addrs = [] of UInt64
    # Enough to fill and empty whole chunks, which is what makes the sweep run
    # its freelist *rebuild* — the path that used to drop the flag. Measured:
    # with the rebuild constructing a bare `FREE`, 0 of 278 surviving free
    # blocks carry SWEPT; with the flag carried, 278 of 278 do.
    20_000.times { addrs << GC.malloc(256).address }
    4.times { GC.collect }

    freed = 0
    swept = 0
    addrs.each do |a|
      info = heap.debug_block_info(Pointer(Void).new(a))
      next unless info[:free]
      freed += 1
      swept += 1 if (info[:flags] & Gcry::BlockHeader::Flags::SWEPT) != 0
    end

    # Most chunks are released outright and report no block at all; what is left
    # is plenty, and the point is that every block the sweep reclaimed still
    # says so after the rebuild.
    freed.should be > 50
    swept.should eq(freed)

    # And the other direction, which is what makes the flag a discriminator
    # rather than a decoration.
    ptr = GC.malloc(256)
    GC.free(ptr)
    info = heap.debug_block_info(ptr)
    info[:free].should be_true
    (info[:flags] & Gcry::BlockHeader::Flags::SWEPT).should eq(0)
  end
end

{% if flag?(:linux) %}
  describe "process GC pthread stack-bounds snapshot" do
    # The other half of "the platform answered nothing", on the pthread side.
    # `snapshot_pthread_stack_bounds` asks libc for each thread's stack range
    # before the suspend signals go out; a thread it visits but gets no bounds
    # for loses the pthread-mapping half of that thread's root coverage. The
    # call has also SEGV'd twice on aarch64 CI
    # (bench/log/linux/2026-08-16-scheduler-roots-aarch64-segv/FINDINGS.md),
    # which is why the id being queried is readable at all.
    #
    # Linux only: Darwin queries the descriptor at lookup time rather than
    # snapshotting, and reports zeros by design — the same assertion there
    # would be red on a platform that is working.
    it "reads stack bounds for every thread the snapshot visits" do
      GC.collect
      visited = Gcry::Platform.stack_bounds_visited
      read = Gcry::Platform.stack_bounds_read

      # Zero visits is the stub shape: a snapshot that walks nothing also
      # reports no gap, which is how a missing platform path passes for
      # releases at a time. Broken on purpose and observed red: making
      # `pthread_stack_bounds` return nil gives visited=6, read=0.
      visited.should be > 0
      read.should eq(visited)

      # Non-zero only while the query is running, so a crash handler reading it
      # is reading the thread the fault is about. Nothing is in flight here.
      Gcry::Platform.stack_bounds_in_flight.should eq(0)

      # Every thread whose bounds were read is remembered, so a fault can say
      # whether the thread it died on had ever worked. Checked against a live
      # thread rather than a constant: an always-false predicate would pass a
      # test that only asked about an unknown id.
      id = Thread.current.to_unsafe.unsafe_as(UInt64)
      Gcry::Platform.stack_bounds_seen_before?(id).should be_true
      Gcry::Platform.stack_bounds_seen_before?(0xdead_beef_u64).should be_false
      Gcry::Platform.stack_bounds_seen_full?.should be_false
    end
  end
{% end %}
