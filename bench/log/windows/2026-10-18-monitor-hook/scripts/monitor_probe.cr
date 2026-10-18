# PROBE ONLY (branch probe/win-monitor-hook). Fresh process: does the Monitor
# loop run, does a hook in `increase_parallelism` get reached, and is a block
# held only in a frame 64 KiB below the Monitor's birth kept by a collection,
# with the SP the stop recorded and with the SP clamp off (no SP).
require "../src/gcry"
require "./monitor_probe_lib"

module DeepHold
  CANARY = 0x6d6f_6e69_746f_7221_u64
  MASK   = 0xa5a5_a5a5_a5a5_a5a5_u64
  WORDS  =                         6

  @@armed = Atomic(Int32).new(0)
  @@addr = Atomic(UInt64).new(0_u64)
  @@release = Atomic(Int32).new(0)
  @@intact = Atomic(Int32).new(-1)
  @@stage = 0
  @@pad_addr = 0_u64
  @@mon : Thread? = nil
  @@sp_at_mark = 0_u64
  @@marks = 0

  def self.arm : Nil
    @@addr.set(0_u64)
    @@release.set(0)
    @@intact.set(-1)
    @@stage = 0
    @@armed.set(1)
  end

  def self.stage : Int32
    @@stage
  end

  def self.pad_addr : UInt64
    @@pad_addr
  end

  def self.masked_addr : UInt64
    @@addr.get
  end

  def self.release : Nil
    @@release.set(1)
  end

  def self.intact : Int32
    @@intact.get
  end

  def self.mon=(t : Thread?)
    @@mon = t
  end

  def self.sp_at_mark : UInt64
    @@sp_at_mark
  end

  def self.marks : Int32
    @@marks
  end

  # Collector thread, world stopped: no allocation.
  def self.at_mark : Nil
    @@marks += 1
    if m = @@mon
      if sp = Gcry::Platform.thread_sp(m.to_unsafe)
        @@sp_at_mark = sp.address
      else
        @@sp_at_mark = 0_u64
      end
    end
  end

  def self.run_if_armed : Nil
    @@stage = 1 if @@armed.get == 1
    return unless @@armed.swap(0) == 1
    @@stage = 2
    padded
  end

  @[NoInline]
  def self.padded : Nil
    @@stage = 3
    pad = uninitialized StaticArray(UInt64, 8192)
    pad[0] = 0_u64
    @@pad_addr = pad.to_unsafe.address
    hold
    Gcry::Roots.keep_alive(pad.to_unsafe.as(Void*))
  end

  @[NoInline]
  def self.hold : Nil
    @@stage = 4
    block = Pointer(UInt64).malloc(WORDS)
    @@stage = 5
    WORDS.times { |i| block[i] = CANARY }
    @@addr.set(block.address ^ MASK)
    @@stage = 6
    until @@release.get == 1
      Intrinsics.pause
    end
    ok = true
    WORDS.times { |i| ok = false unless block[i] == CANARY }
    @@intact.set(ok ? 1 : 0)
    Gcry::Roots.keep_alive(block.as(Void*))
  end
end

class Fiber::ExecutionContext::Monitor
  private def increase_parallelism(now)
    DeepHold.run_if_armed
    previous_def
  end
end

def probe_arm(label : String, clamp : Bool, gregs : Bool = true) : Nil
  heap = Gcry.default_heap
  Gcry::Platform.stw_sp_clamp_enabled = clamp
  heap.disable_greg_roots = !gregs
  DeepHold.mon = MonProbe.monitor_thread
  DeepHold.arm
  deadline = Time.instant + 10.seconds
  while DeepHold.masked_addr == 0
    if Time.instant > deadline
      puts "#{label}: HOLD NOT REACHED stage=#{DeepHold.stage} #{MonProbe.counters}"
      STDOUT.flush
      MonProbe.dump_monitor
      Gcry::Platform.stw_sp_clamp_enabled = true
      heap.disable_greg_roots = false
      return
    end
    sleep 1.millisecond
  end

  hits = [] of UInt64
  falls = [] of UInt64
  sps = [] of UInt64
  heap.collection_event_hook = ->(event : Gcry::Heap::CollectionEvent) do
    DeepHold.at_mark if event.mark_start?
    nil
  end
  lazy = heap.lazy_sweep
  begin
    heap.lazy_sweep = false
    3.times do
      GC.collect
      hits << heap.sp_clamp_hits
      falls << heap.sp_clamp_fallbacks
      sps << DeepHold.sp_at_mark
    end
  ensure
    heap.lazy_sweep = lazy
    heap.collection_event_hook = nil
  end
  info = heap.debug_block_info(Pointer(Void).new(DeepHold.masked_addr ^ DeepHold::MASK))
  mon = MonProbe.monitor_thread
  fiber = mon.try(&.@current_fiber)
  low = fiber ? fiber.@stack.pointer.address : 0_u64
  bottom = fiber ? fiber.@stack.bottom.address : 0_u64
  stack_top = fiber ? fiber.@context.stack_top.address : 0_u64
  DeepHold.release
  deadline = Time.instant + 10.seconds
  while DeepHold.intact < 0
    if Time.instant > deadline
      puts "#{label}: monitor never left the hold"
      break
    end
    sleep 1.millisecond
  end
  Gcry::Platform.stw_sp_clamp_enabled = true
  heap.disable_greg_roots = false
  verdict = info[:found] && !info[:free] && DeepHold.intact == 1 ? "KEPT" : "LOST"
  puts "#{label}: #{verdict} found=#{info[:found]} free=#{info[:free]} intact=#{DeepHold.intact} " \
       "marks=#{DeepHold.marks} sp_clamp_hits=#{hits} sp_clamp_fallbacks=#{falls} " \
       "monitor_sp_at_mark=#{sps.map { |s| "0x#{s.to_s(16)}" }} pad=0x#{DeepHold.pad_addr.to_s(16)} " \
       "stack_top=0x#{stack_top.to_s(16)} stack=[0x#{low.to_s(16)},0x#{bottom.to_s(16)}) " \
       "exempt=#{mon ? Gcry::MonitorGate.signal_exempt?(mon) : "no-monitor"}"
  STDOUT.flush
end

platform = {% if flag?(:win32) %} "windows" {% elsif flag?(:darwin) %} "darwin" {% else %} "linux" {% end %}
arch = {% if flag?(:aarch64) %} "aarch64" {% else %} "x86_64" {% end %}
puts "monitor_probe #{platform} #{arch} crystal=#{Crystal::VERSION} threads=#{MonProbe.thread_names}"
sleep 1.second
puts "after 1 s: #{MonProbe.counters}"
STDOUT.flush
MonProbe.dump_monitor
probe_arm("clamp=on", true)
probe_arm("clamp=off", false)
probe_arm("clamp=on gregs=off", true, false)
probe_arm("clamp=off gregs=off", false, false)
puts "end: #{MonProbe.counters}"
