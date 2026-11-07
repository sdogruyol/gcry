require "../../src/gcry"
require "spec"

# The execution-context Monitor's dead stack was a root. On Linux the Monitor
# (SYSMON) is never signalled and publishes no SP, so a stop reads its stack
# whole from the low-water mark, and every word its earlier, deeper calls had
# left below where it sleeps was scanned as a root. In regression 1's suite
# order one such word, about 650 bytes below the Monitor's sleeping SP, named
# a word inside a large block, and kept that block and the 16–70 thousand
# objects it reached until a later Monitor pass wrote over it, inside the
# spec's measured window: `drift=-15985` to `-70174` with block headers
# (`bench/log/linux/2026-11-04-reg1-drift/`). The
# Monitor now zeroes its stack below each gated call as the call ends
# (`MonitorGate.leave`), as the idle thread does before every park.
#
# Which word a call leaves where depends on the build, the heap and the
# Monitor's timing, so the regression plants it: while
# `MonitorGate.test_plant` is set, every gated call writes a block's address
# over 8 KiB of the Monitor's stack below `enter` before it does its work.
# The block is made on a fiber that scrubs its frames, its address kept
# masked in libc memory and, until the Monitor has planted, in a static slot
# that is then cleared. Then three collections. The fixed arm must free the
# block; the control arm (`MonitorGate.residue_kept`, the code before) must
# keep it, or the fixed arm could pass on a layout the scan does not read;
# and an arm with no plant must free it, or the control arm could be kept by
# something other than the plant.
#
# Each arm in a process of its own. Linux only, where the Monitor is not
# suspended; Darwin and Windows suspend it and scan it from its SP. Elsewhere,
# and in a build with no Monitor, the child prints `MONITOR105_SKIP_MARK`.

private MONITOR105_SKIP_MARK = "monitor105: not on this platform, skipped"
private MONITOR105_KEPT      = "monitor105: planted block kept"
private MONITOR105_FREED     = "monitor105: planted block freed"

# A size of its own, so nothing the child allocates afterwards takes the
# freed block's address before it is looked up.
private MONITOR105_BYTES = 20_000

# The block's one reference until the Monitor has planted: static data, a
# root no stack scan involves. Atomic, because a `--release` build dropped
# the plain store that cleared it, and the slot kept the block in every arm.
private module Monitor105Hold
  @@block = Atomic(UInt64).new(0_u64)

  def self.block=(p : Void*) : Nil
    @@block.set(p.address)
  end
end

@[NoInline]
private def monitor105_scrub_frames : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

# The block, in a frame of its own below the spawned fiber's entry, which the
# scrub after it then zeroes (regression 101's target, made in the spawned
# block itself, was kept by that fiber's top frame in a `--release` build).
# Its address masked with the plant's key in *masked*, and held in
# `Monitor105Hold`.
@[NoInline]
private def monitor105_alloc(masked : UInt64*) : Nil
  p = GC.malloc_atomic(MONITOR105_BYTES)
  masked.value = p.address ^ Gcry::MonitorGate::PLANT_KEY
  Monitor105Hold.block = p
end

private def monitor105_make(masked : UInt64*) : Nil
  done = Channel(Nil).new
  spawn do
    monitor105_alloc(masked)
    monitor105_scrub_frames
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

private def monitor105_child(arm : String) : Nil
  {% if flag?(:linux) && @top_level.has_constant?("Fiber") && Fiber.has_constant?("ExecutionContext") && Fiber::ExecutionContext.has_constant?("Monitor") %}
    heap = Gcry.default_heap
    Gcry::MonitorGate.residue_kept = arm == "control"
    masked = LibC.malloc(LibC::SizeT.new(sizeof(UInt64))).as(UInt64*)
    monitor105_make(masked)
    planted = Gcry::MonitorGate.test_plants
    if arm == "unplanted"
      # As long as the planting arms wait, give or take: a few Monitor passes.
      sleep 30.milliseconds
    else
      Gcry::MonitorGate.test_plant = masked.value
      deadline = Time.instant + 10.seconds
      while Gcry::MonitorGate.test_plants == planted
        fail "the Monitor did not plant" if Time.instant > deadline
        sleep 1.millisecond
      end
      Gcry::MonitorGate.test_plant = 0_u64
      # A call that read the plant before it was cleared ends with its own
      # `leave`, which a stop waits for (`MonitorGate.close`).
    end
    Monitor105Hold.block = Pointer(Void).null
    3.times { GC.collect }
    kept = !heap.find_object(Pointer(Void).new(masked.value ^ Gcry::MonitorGate::PLANT_KEY)).nil?
    STDERR.puts "monitor105: #{arm}: block #{kept ? "kept" : "freed"} after three collections, #{Gcry::MonitorGate.test_plants - planted} plant(s)"
    STDERR.puts(kept ? MONITOR105_KEPT : MONITOR105_FREED)
  {% else %}
    STDERR.puts MONITOR105_SKIP_MARK
  {% end %}
end

private def monitor105_run(arm : String, want : String) : Nil
  captured = IO::Memory.new
  status = Process.run(Process.executable_path.not_nil!, ["-e", "monitor105 child #{arm}"],
    env: {"GCRY_MONITOR105_CHILD" => arm}, output: captured, error: captured)
  text = captured.to_s
  text.each_line { |l| STDERR.puts "#{arm}: #{l}" if l.starts_with?("monitor105:") }
  fail "#{arm} child #{status.inspect}:\n#{text}" unless status.success?
  text.should contain("1 examples, 0 failures")
  unless text.includes?(MONITOR105_SKIP_MARK)
    fail "#{arm} child: expected '#{want}':\n#{text}" unless text.includes?(want)
  end
end

describe "Regression: the Monitor's dead stack is no root" do
  {"fixed", "control", "unplanted"}.each do |arm|
    it "#{arm} arm in a process of its own" do
      monitor105_run(arm, arm == "control" ? MONITOR105_KEPT : MONITOR105_FREED)
    end
  end

  {"fixed", "control", "unplanted"}.each do |arm|
    it "monitor105 child #{arm}" do
      next unless ENV["GCRY_MONITOR105_CHILD"]? == arm
      monitor105_child(arm)
    end
  end
end
