require "../../../../src/gcry"

# A gcry parent that waits on a slow child in a poll loop, the shape of
# BoundedChild.run: two minutes or more with no allocation, which is when the
# idle collector runs. Prints when it is done; a hang here is the finding.
child_s = (ARGV[0]? || "200").to_i
deadline_s = (ARGV[1]? || "150").to_i
# Start the idle thread (it starts after the first collection) and leave
# allocation activity behind for it to see go quiet.
GC.collect
junk = Array(String).new(2000) { |i| "junk-#{i}" * 4 }
puts "IDLEWAIT warmed: #{junk.size} strings, collections=#{Gcry.metrics.collections}"
junk = nil
t0 = Time.instant
cmd = {{ flag?(:win32) ? "ping" : "sleep" }}
args = {{ flag?(:win32) }} ? ["-n", (child_s + 1).to_s, "127.0.0.1"] : [child_s.to_s]
process = Process.new(cmd, args, output: Process::Redirect::Close)
deadline = t0 + deadline_s.seconds
timed_out = false
loop do
  break if process.terminated?
  if Time.instant >= deadline
    timed_out = true
    break
  end
  sleep 20.milliseconds
end
process.terminate(graceful: false) rescue nil if timed_out
status = process.wait
m = Gcry.metrics
puts "IDLEWAIT done after #{(Time.instant - t0).total_seconds.round(1)}s timed_out=#{timed_out} collections=#{m.collections}"
