require "../../Reg1/wt/src/gcry"

until Gcry::MonitorGate.loop_test_ready?
  sleep 1.millisecond
end
sleep 50.milliseconds
m = Gcry::MonitorGate.loop_test_block
sp = Gcry::MonitorGate.loop_test_sp
a = sp - 8704
plant = 0
while a < sp + 64
  v = Pointer(UInt64).new(a).value
  tag = (v ^ Gcry::MonitorGate::PLANT_KEY) == m ? "PLANT" : (((v ^ Gcry::MonitorGate::PLANT_KEY) >> 32) == (m >> 32) && (v >> 32) != 0 ? "HIGH" : "")
  plant += 1 if tag == "PLANT"
  STDERR.puts "#{a.to_i64 - sp.to_i64} 0x#{v.to_s(16)} #{tag}" if a > sp - 700 && v != 0
  a += 8
end
STDERR.puts "plant words=#{plant} test=#{Gcry::MonitorGate.loop_test}"
