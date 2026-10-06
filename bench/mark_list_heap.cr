# Parallel mark on a heap with no parallelism in it: one long singly linked
# list.
#
# Every node is reachable only through its predecessor, so whoever pops the
# head marks the whole list and nothing is ever published for anyone else.
# Extra mark workers can only cost here, and this measures what they cost:
# the pause and the mark phase of each collection, and the process CPU over
# the collections and over the whole run, per arm. An arm is a value of
# `GCRY_PARALLEL_MARK` (`default` leaves it unset), each run is a fresh child
# process, and arm order is shuffled per trial.
#
# The list is 3 M nodes of 24 bytes by default, above the 32 MiB live floor
# under which the process default marks serially.
#
#   crystal build --release -Dgc_none bench/mark_list_heap.cr -o bin/mark_list_heap
#   bin/mark_list_heap [--nodes=3000000] [--collects=20] [--trials=5]
#                      [--arms=1,default,4] [--exe=LABEL:PATH ...]
#
# `--exe` adds another build of this file as a second set of arms, so a
# before/after comparison runs interleaved in one session.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "mark_list_heap requires -Dgc_none (gcry as process GC)" %}
{% end %}

class ListNode
  property next_node : ListNode?
  property payload = 0_i64

  def initialize(@next_node)
  end
end

def arg_value(name : String, default : String) : String
  ARGV.each do |a|
    return a[(name.size + 3)..] if a.starts_with?("--#{name}=")
  end
  default
end

# Built in a frame that has returned, with the head only in `holder`'s buffer:
# the list is reachable through one root and one edge per node.
@[NoInline]
def build_list(holder : Array(ListNode?), count : Int32) : Nil
  head = nil.as(ListNode?)
  count.times { |i| head = ListNode.new(head).tap { |n| n.payload = i.to_i64 } }
  holder << head
end

@[NoInline]
def list_length(holder : Array(ListNode?)) : Int32
  length = 0
  node = holder[0]
  while node
    length += 1
    node = node.next_node
  end
  length
end

# NaN for a field an older build of this file does not print.
def median(xs : Array(Float64)) : Float64
  return Float64::NAN if xs.empty?
  s = xs.sort
  n = s.size
  n.odd? ? s[n // 2] : (s[n // 2 - 1] + s[n // 2]) / 2
end

def cpu_seconds : Float64
  t = Process.times
  t.utime + t.stime
end

if ARGV.includes?("--child")
  start_cpu = cpu_seconds
  start = Time.instant
  nodes = arg_value("nodes", "3000000").to_i
  collects = arg_value("collects", "20").to_i
  heap = Gcry.default_heap

  holder = [] of ListNode?
  build_list(holder, nodes)
  # Two collections first: the live floor is read from the last major's sweep.
  GC.collect
  GC.collect
  runs0 = heap.parallel_mark_runs
  stolen0 = heap.parallel_mark_stolen

  pauses = [] of Float64
  marks = [] of Float64
  cpu0 = cpu_seconds
  t0 = Time.instant
  collects.times do
    GC.collect
    pauses << heap.last_pause_ns / 1e6
    marks << heap.last_phase_mark_ns / 1e6
  end
  window = (Time.instant - t0).total_seconds
  window_cpu = cpu_seconds - cpu0
  runs = heap.parallel_mark_runs - runs0
  stolen = heap.parallel_mark_stolen - stolen0

  length = list_length(holder)
  unless length == nodes
    STDERR.puts "FAIL list has #{length} nodes, built #{nodes}"
    exit 1
  end
  total = (Time.instant - start).total_seconds
  total_cpu = cpu_seconds - start_cpu
  printf("child workers=%d parallel=%d stolen=%d pause_ms=%.3f pause_min_ms=%.3f mark_ms=%.3f " \
         "gc_cpu_per_wall=%.3f cpu_per_wall=%.3f wall_s=%.3f cpu_s=%.3f\n",
    heap.parallel_mark_workers, runs, stolen // collects, median(pauses), pauses.min, median(marks),
    window_cpu / window, total_cpu / total, total, total_cpu)
  exit 0
end

trials = arg_value("trials", "5").to_i
arms = arg_value("arms", "1,default,4").split(',')
exes = [{"self", Process.executable_path.not_nil!}]
ARGV.each do |a|
  next unless a.starts_with?("--exe=")
  label, path = a[6..].split(':', 2)
  exes << {label, path}
end
child_args = ["--child", "--nodes=#{arg_value("nodes", "3000000")}", "--collects=#{arg_value("collects", "20")}"]

FIELDS = %w(stolen pause_ms pause_min_ms mark_ms gc_cpu_per_wall cpu_per_wall wall_s)
results = Hash(String, Hash(String, Array(Float64))).new { |h, k| h[k] = Hash(String, Array(Float64)).new { |hh, kk| hh[kk] = [] of Float64 } }
workers_of = {} of String => String
order = exes.flat_map { |(label, path)| arms.map { |arm| {label, path, arm} } }

puts "=== mark on a list-shaped heap: #{arg_value("nodes", "3000000")} nodes, " \
     "#{arg_value("collects", "20")} collections, #{trials} trials ==="
trials.times do |t|
  order.shuffle.each do |(label, path, arm)|
    env = {} of String => String?
    env["GCRY_PARALLEL_MARK"] = arm == "default" ? nil : arm
    captured = IO::Memory.new
    status = Process.run(path, child_args, env: env, output: captured, error: captured)
    line = captured.to_s.lines.find(&.starts_with?("child "))
    unless status.success? && line
      STDERR.puts "FAIL #{label} GCRY_PARALLEL_MARK=#{arm}: exit #{status.exit_code?.inspect}\n#{captured}"
      exit 1
    end
    key = "#{label} #{arm}"
    line.split.each do |kv|
      k, _, v = kv.partition('=')
      workers_of[key] = "#{v}w/#{line[/parallel=(\d+)/, 1]}p" if k == "workers"
      results[key][k] << v.to_f if FIELDS.includes?(k)
    end
  end
  STDERR.puts "trial #{t + 1}/#{trials}"
end

# `stolen`: entries helpers popped per collection (median); 0 means the
# master marked everything.
printf("%-22s %8s %8s %9s %9s %9s %10s %9s\n", "arm (workers/par.runs)", "stolen", "pause", "min", "mark", "gc cpu/w", "proc cpu/w", "wall s")
order.each do |(label, _, arm)|
  key = "#{label} #{arm}"
  r = results[key]
  printf("%-22s %8.0f %6.1fms %7.1fms %7.1fms %9.2f %10.2f %9.3f\n",
    "#{key} (#{workers_of[key]})", median(r["stolen"]), median(r["pause_ms"]), r["pause_min_ms"].min,
    median(r["mark_ms"]), median(r["gc_cpu_per_wall"]), median(r["cpu_per_wall"]), median(r["wall_s"]))
end
