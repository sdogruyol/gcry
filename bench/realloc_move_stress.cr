# Does a collection that stops a thread in the middle of a `realloc` page move
# still find everything the moved pages point at?
#
# `Heap#move_large_contents` grows a large block by handing its pages to the
# new block with two `mremap` calls (`Platform.move_pages`): first to an
# address the kernel picks, then into the new chunk. Between the two the
# contents are in no chunk at all, and a mark that ran then would miss every
# object only they reach. The stop signal is blocked across both calls, so no
# stop can land there. This asks whether that holds under real stops:
#
#   workers    grow `Array(Parcel)` past 2 MiB by `<<`, so most growth steps
#              move pages, then check every box
#   collector  `GC.collect` in a loop
#   churn      every worker also allocates small garbage, so a box the
#              collector wrongly freed is soon overwritten
#
#   default                                  must survive, every box intact
#   GCRY_REALLOC_MOVE_TEST_UNBLOCKED_US=200  must fail: the signal is not
#                                            blocked and the window held open
#
#   crystal build -Dgc_none bench/realloc_move_stress.cr -o bin/realloc_move_stress
#   bin/realloc_move_stress
#   GCRY_REALLOC_MOVE_TEST_UNBLOCKED_US=200 bin/realloc_move_stress --child

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "realloc_move_stress requires -Dgc_none (gcry as process GC)" %}
{% end %}

WORKERS = 3
ROUNDS  = 4
# 400 000 references: the array's buffer ends at 4 MiB and passes
# `Heap::REALLOC_MOVE_MIN` (256 KiB) a dozen growth steps before that.
BOXES =         400_000
MAGIC = 0x5A5A_1234_u64

class Parcel
  getter id : UInt64
  getter check : UInt64

  def initialize(@id : UInt64)
    @check = @id ^ MAGIC
  end
end

class Verdict
  @@bad = Atomic(Int32).new(0)
  @@done = Atomic(Int32).new(0)

  def self.bad!
    @@bad.add(1)
  end

  def self.bad
    @@bad.get
  end

  def self.finish
    @@done.add(1)
  end

  def self.finished
    @@done.get
  end
end

if ARGV.includes?("--child")
  {% unless flag?(:win32) %}
    Gcry::SegvReport.install if ENV["GCRY_SEGV_REPORT"]? == "1"
  {% end %}
  threads = [] of Thread
  WORKERS.times do |w|
    threads << Thread.new do
      ROUNDS.times do |r|
        boxes = [] of Parcel
        base = (w.to_u64 << 40) | (r.to_u64 << 20)
        BOXES.times do |i|
          boxes << Parcel.new(base | i.to_u64)
          # Garbage between the pushes, so freed boxes are reused quickly.
          Bytes.new(48) if i % 4 == 0
        end
        boxes.each_with_index do |b, i|
          unless b.id == (base | i.to_u64) && b.check == (b.id ^ MAGIC)
            Verdict.bad!
            break
          end
        end
      end
      Verdict.finish
    end
  end
  # A short rest between collections, so the workers get far enough between
  # stops to grow: back to back, a child took minutes per round. `nanosleep`,
  # not `sleep`: a bare `Thread` has no event loop.
  collector = Thread.new do
    rest = LibC::Timespec.new(tv_sec: 0, tv_nsec: 1_000_000)
    until Verdict.finished >= WORKERS
      GC.collect
      LibC.nanosleep(pointerof(rest), nil)
    end
  end
  threads.each(&.join)
  collector.join
  heap = Gcry.default_heap
  puts "child: #{Verdict.bad} bad rounds, #{heap.realloc_moves} moves (#{heap.realloc_moved_bytes // 1048576} MiB), #{heap.collections} collections"
  exit(1) if heap.realloc_moves == 0 && ENV["GCRY_REALLOC_MOVE"]? != "0"
  exit(Verdict.bad > 0 ? 1 : 0)
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
attempts = (ENV["REALLOC_MOVE_STRESS_ATTEMPTS"]?.try(&.to_i?) || 3)

puts "=== realloc page-move stress ==="
puts "#{WORKERS} workers × #{ROUNDS} rounds of #{BOXES} boxes, one collector, #{attempts} attempts per arm"

# The default arm needs every attempt clean; the control needs one failure to
# show the harness can see the window, and stops at it.
def run_arm(exe : String, env : Hash(String, String), attempts : Int32, control : Bool) : {Int32, Int32}
  bad = 0
  tries = 0
  attempts.times do
    break if control && bad > 0
    tries += 1
    result = BoundedChild.run(exe, ["--child"], env)
    line = result.output.lines.find(&.starts_with?("child:"))
    puts "  #{control ? "control" : "default"}: #{result.ok ? "ok" : (result.timed_out ? "TIMED OUT" : "FAILED")}#{line ? " — #{line}" : ""}"
    unless result.ok
      bad += 1
      STDERR.puts result.output.lines.last(20).join("\n") unless control
    end
  end
  {bad, tries}
end

default_bad, default_tries = run_arm(exe, {"GCRY_SEGV_REPORT" => "1"}, attempts, false)
control_bad, control_tries = run_arm(exe, {"GCRY_REALLOC_MOVE_TEST_UNBLOCKED_US" => "200"}, attempts * 4, true)

puts ""
puts "default: #{default_bad} of #{default_tries} failed"
puts "control (unblocked, 200 µs window): #{control_bad} of #{control_tries} failed"
ok = default_bad == 0 && control_bad > 0
puts ok ? "PASS" : "FAIL"
exit(ok ? 0 : 1)
