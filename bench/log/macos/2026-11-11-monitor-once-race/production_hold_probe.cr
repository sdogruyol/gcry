lib LibC
  fun strtoll(s : Char*, e : Char**, b : Int) : LongLong
end

# No GCRY_* knob: main is held 50 ms inside one named class variable's
# initializer (PROBE_FLAG, an nm offset from Crystal::Once::spin), as a
# slow machine would leave it there when the Monitor's first gated call comes.
module Crystal::Once
  private def self.run_initializer(flag, &)
    p = LibC.getenv("PROBE_FLAG")
    if !p.null? && Thread.current.name != "SYSMON" && flag.address &- pointerof(@@spin).address == LibC.strtoll(p, nil, 10).to_u64!
      ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 50_000_000); LibC.nanosleep(pointerof(ts), nil)
    end
    previous_def { yield }
  end
end

require "../../../../src/gcry"
puts "ok"
