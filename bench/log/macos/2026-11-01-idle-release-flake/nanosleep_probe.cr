# How long does a 12.5 ms `nanosleep` take on this runner? The idle thread
# polls with exactly that sleep (`IdleRelease.loop_forever` at
# GCRY_IDLE_RELEASE_MS=50: a quarter of the idle time) while the program
# sleeps in Crystal's event loop, as `make idle-release` does between bursts.
# Plain Crystal, no gcry: `crystal build -Dgc_none nanosleep_probe.cr`.
N = (ENV["N"]? || "2000").to_i

lib LibC
  fun nanosleep(req : Timespec*, rem : Timespec*) : Int
end

durations = Pointer(Int64).malloc(N)
done = Atomic(Int32).new(0)
t = Thread.new do
  req = LibC::Timespec.new
  req.tv_sec = typeof(req.tv_sec).new(0)
  req.tv_nsec = typeof(req.tv_nsec).new(12_500_000)
  rem = LibC::Timespec.new
  N.times do |i|
    t0 = Time.instant
    LibC.nanosleep(pointerof(req), pointerof(rem))
    durations[i] = (Time.instant - t0).total_nanoseconds.to_i64
  end
  done.set(1)
end
while done.get == 0
  sleep 200.milliseconds
end
t.join
ms = (0...N).map { |i| durations[i] / 1_000_000.0 }.sort!
pct = ->(q : Float64) { ms[{(ms.size * q).to_i, ms.size - 1}.min] }
puts "nanosleep 12.5 ms x #{N}: p50=#{pct.call(0.5).round(2)} p90=#{pct.call(0.9).round(2)} " \
     "p99=#{pct.call(0.99).round(2)} p99.9=#{pct.call(0.999).round(2)} max=#{ms.last.round(2)} ms; " \
     "over 25 ms: #{ms.count { |x| x > 25.0 }}, over 50 ms: #{ms.count { |x| x > 50.0 }}, over 100 ms: #{ms.count { |x| x > 100.0 }}"
