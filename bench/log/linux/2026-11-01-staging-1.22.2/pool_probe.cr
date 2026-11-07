# Does `Parallel.new` + spawn create a thread when the thread pool holds one?
#
#   control — nothing parked;
#   moved   — park the main fiber's thread inside `Fiber.syscall` long enough
#             for the Monitor (every 10 ms) to hand its scheduler to another
#             thread; on return that thread checks itself into the pool;
#   seeded  — what the fixed spec does: an isolated context that ends.
#
# Then the old example's body (old_staged: its `> 0` read) and the fixed one's
# two checks (staged >= created, Thread.new staged > 0).
#
#   crystal build -Dgc_none bench/log/linux/2026-11-01-staging-1.22.2/pool_probe.cr -o bin/pool_probe
#   bin/pool_probe control|moved|seeded
require "../../../../src/gcry"

def thread_ids : Set(UInt64)
  ids = Set(UInt64).new
  Thread.unsafe_each { |t| ids << t.to_unsafe.unsafe_as(UInt64) }
  ids
end

arm = ARGV[0]? || "control"
main = Gcry::Platform.current_thread_id

case arm
when "moved"
  Fiber.syscall do
    req = LibC::Timespec.new(tv_sec: 0, tv_nsec: 200_000_000)
    LibC.nanosleep(pointerof(req), Pointer(LibC::Timespec).null)
  end
when "seeded"
  Fiber::ExecutionContext::Isolated.new("seed") { }.wait
end

listed = thread_ids
before = Gcry::Platform.staged_total
ec = Fiber::ExecutionContext::Parallel.new("staging-spec", 2)
done = Channel(UInt64).new(4)
4.times { ec.spawn { done.send(Gcry::Platform.current_thread_id) } }
ran_on = Array(UInt64).new(4) { done.receive }.uniq
staged = Gcry::Platform.staged_total - before
created = ran_on.count { |id| !listed.includes?(id) }

t0 = Gcry::Platform.staged_total
Thread.new { }.join
thread_new = Gcry::Platform.staged_total - t0

ok = staged >= created && thread_new > 0
puts "arm=#{arm} crystal=#{Crystal::VERSION} main_moved=#{Gcry::Platform.current_thread_id != main} " \
     "ec_threads=#{ran_on.size} reused=#{ran_on.size - created} reused_main=#{ran_on.includes?(main) && Gcry::Platform.current_thread_id != main} " \
     "created=#{created} old_staged=#{staged} thread_new_staged=#{thread_new} old=#{staged > 0 ? "pass" : "FAIL"} new=#{ok ? "pass" : "FAIL"}"
