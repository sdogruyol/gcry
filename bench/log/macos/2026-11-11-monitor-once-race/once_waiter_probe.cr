module Crystal::Once
  def self.spin_nm : UInt64
    p = LibC.getenv("SPIN_NM"); p.null? ? 0_u64 : String.new(p).to_u64(16)
  end

  private def self.run_initializer(flag, &)
    if Thread.current.name == "SYSMON"
      msg = "probe: SYSMON runs initializer off=#{(flag.address &- pointerof(@@spin).address &+ spin_nm).to_s(16)}\n"
      LibC.write(2, msg.to_unsafe, msg.bytesize)
    elsif !LibC.getenv("PROBE_DELAY").null?
      ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 2_000_000); LibC.nanosleep(pointerof(ts), nil)
    end
    previous_def { yield }
  end

  private def self.wait_initializer(operation)
    t = Thread.current
    msg = "probe: waiter thread=#{t.name.inspect} ec=#{!Fiber.current.execution_context?.nil?} off=#{(operation.value.flag.address &- pointerof(@@spin).address &+ spin_nm).to_s(16)}\n"
    LibC.write(2, msg.to_unsafe, msg.bytesize)

    previous_def
  end
end

require "../../../../src/gcry"
puts "ok"
