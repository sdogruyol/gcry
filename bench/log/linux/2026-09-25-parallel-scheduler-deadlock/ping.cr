# Minimal shape of stw_mt_property_test's traffic, with no gcry: Parallel
# workers send on an unbuffered channel and wait for an ack from the main
# fiber, which collects every 8 round trips. Built against Boehm.
workers = (ARGV[0]? || "2").to_i
rounds = (ARGV[1]? || "4000").to_i
out_ch = Channel(Int32).new
ack_ch = Channel(Nil).new
ctx = Fiber::ExecutionContext::Parallel.new("w", workers)
workers.times do |w|
  ctx.spawn do
    rng = Random.new(w)
    begin
      loop do
        out_ch.send w
        ack_ch.receive
        Fiber.yield if rng.rand(0..15) == 0
      end
    rescue Channel::ClosedError
    end
  end
end
rounds.times do |i|
  out_ch.receive
  ack_ch.send nil
  GC.collect if i % 8 == 7
end
out_ch.close
ack_ch.close
puts "ok"
