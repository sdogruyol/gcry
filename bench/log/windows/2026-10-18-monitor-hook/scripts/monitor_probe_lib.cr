# PROBE ONLY (branch probe/win-monitor-hook): what the runtime's Monitor is
# doing. Counts entries to and exits from the three calls of
# `Monitor#run_loop`, and on Windows suspends the Monitor for a moment to read
# its suspend count, PC, SP and the image addresses on its stack.

module Gcry::MonitorGate
  def self.probe_stopped : Int32
    @@stopped.get
  end

  def self.probe_busy : Int32
    @@busy.get
  end
end

{% if flag?(:win32) %}
  struct Exception::CallStack
    def self.probe_symbol(pc : UInt64) : String
      {% if flag?(:gnu) %}
        "0x#{pc.to_s(16)}"
      {% else %}
        load_debug_info
        @@mutex.synchronize do
          name = decode_function_name(pc) || "?"
          file, line, _ = decode_line_number(pc)
          "0x#{pc.to_s(16)} #{name} #{file}:#{line}"
        end
      {% end %}
    end
  end
{% end %}

module MonProbe
  @@t_in = 0_u64
  @@t_out = 0_u64
  @@i_in = 0_u64
  @@i_out = 0_u64
  @@c_in = 0_u64
  @@c_out = 0_u64
  @@last_t_ns = 0_u64

  def self.t_in : Nil
    @@t_in &+= 1
    @@last_t_ns = Gcry::Clock.monotonic_ns
  end

  def self.t_out : Nil
    @@t_out &+= 1
  end

  def self.i_in : Nil
    @@i_in &+= 1
  end

  def self.i_out : Nil
    @@i_out &+= 1
  end

  def self.c_in : Nil
    @@c_in &+= 1
  end

  def self.c_out : Nil
    @@c_out &+= 1
  end

  def self.transfers : UInt64
    @@t_in
  end

  def self.counters : String
    ago = @@last_t_ns == 0 ? -1_i64 : ((Gcry::Clock.monotonic_ns - @@last_t_ns) // 1_000_000).to_i64
    "transfer=#{@@t_in}/#{@@t_out} increase=#{@@i_in}/#{@@i_out} collect=#{@@c_in}/#{@@c_out} " \
    "last_transfer_ms_ago=#{ago} gate(enabled=#{Gcry::MonitorGate.enabled?} stopped=#{Gcry::MonitorGate.probe_stopped} " \
    "busy=#{Gcry::MonitorGate.probe_busy} site=#{Gcry::MonitorGate.site_name(Gcry::MonitorGate.site)} " \
    "blocks=#{Gcry::MonitorGate.monitor_blocks} stw_waits=#{Gcry::MonitorGate.stw_waits})"
  end

  def self.monitor_thread : Thread?
    found = nil.as(Thread?)
    Thread.unsafe_each { |t| found = t if t.@name == "SYSMON" }
    found
  end

  def self.thread_names : String
    names = [] of String
    Thread.unsafe_each { |t| names << (t.@name || "?") }
    names.join(",")
  end

  {% if flag?(:win32) %}
    private def self.image_range : {UInt64, UInt64}
      base = LibGcryImage.GetModuleHandleW(Pointer(UInt16).null).address
      lfanew = Pointer(Int32).new(base + 0x3c).value
      size = Pointer(UInt32).new(base + lfanew.to_u64 + 80).value
      {base, size.to_u64}
    end
  {% end %}

  def self.dump_monitor : Nil
    mon = monitor_thread
    unless mon
      STDERR.puts "  MONPROBE no SYSMON thread on Crystal's list (threads: #{thread_names})"
      return
    end
    fiber = mon.@current_fiber
    low = fiber ? fiber.@stack.pointer.address : 0_u64
    bottom = fiber ? fiber.@stack.bottom.address : 0_u64
    stack_top = fiber ? fiber.@context.stack_top.address : 0_u64
    STDERR.puts "  MONPROBE SYSMON exempt=#{Gcry::MonitorGate.signal_exempt?(mon)} fiber=#{fiber.try(&.name)} " \
                "stack=[0x#{low.to_s(16)},0x#{bottom.to_s(16)}) stack_top=0x#{stack_top.to_s(16)} threads=#{thread_names}"
    {% if flag?(:win32) %}
      handle = mon.to_unsafe
      words = uninitialized UInt64[48]
      offs = uninitialized UInt64[48]
      n = 0
      base, size = image_range
      prev = LibC.SuspendThread(handle)
      buffer = uninitialized UInt8[1248]
      ctx = buffer.to_unsafe.align_up(16).as(LibC::CONTEXT*)
      ctx.clear
      ctx.value.contextFlags = LibC::CONTEXT_FULL
      ok = LibC.GetThreadContext(handle, ctx)
      {% if flag?(:aarch64) %}
        pc = ctx.value.pc
        sp = ctx.value.sp
      {% else %}
        pc = ctx.value.rip
        sp = ctx.value.rsp
      {% end %}
      if ok != 0 && sp >= low && sp < bottom
        a = sp
        while a < bottom && n < 48
          w = Pointer(UInt64).new(a).value
          if w >= base && w < base + size
            words[n] = w
            offs[n] = a - sp
            n += 1
          end
          a += 8
        end
      end
      LibC.ResumeThread(handle)
      STDERR.puts "  MONPROBE SYSMON prev_suspend_count=#{prev} getctx=#{ok} pc=0x#{pc.to_s(16)} sp=0x#{sp.to_s(16)} " \
                  "depth=#{bottom > sp ? bottom - sp : 0} image=[0x#{base.to_s(16)},+0x#{size.to_s(16)})"
      STDERR.puts "    pc #{Exception::CallStack.probe_symbol(pc)}"
      n.times { |i| STDERR.puts "    sp+#{offs[i]} #{Exception::CallStack.probe_symbol(words[i])}" }
    {% end %}
  end
end

class Fiber::ExecutionContext::Monitor
  private def transfer_schedulers_blocked_on_syscall
    MonProbe.t_in
    previous_def
    MonProbe.t_out
  end

  private def increase_parallelism(now)
    MonProbe.i_in
    previous_def
    MonProbe.i_out
  end

  private def collect_stacks(now)
    MonProbe.c_in
    previous_def
    MonProbe.c_out
  end
end
