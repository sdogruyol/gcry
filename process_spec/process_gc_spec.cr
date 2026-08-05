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

      release.set(1)
      worker.join
    end
  end
{% end %}
