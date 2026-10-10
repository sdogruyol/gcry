# Can the master end a parallel mark cycle while a worker still holds a batch?
#
# The master stops the drain when it sees `busy == 0 && stack empty`. That is
# only stable if a worker cannot be holding work while counted idle, and until
# 2026-09-04 it could: `pop_mark_batch` took the batch under `@mark_lock` and
# the worker incremented `@mark_workers_busy` *after* releasing it. In the gap
# the master reads zero, sees the (now emptied) stack empty, breaks, and its
# `ensure` waits on a counter that is already zero. The worker resumes, scans
# up to `MARK_POP_BATCH` objects and flushes their children onto a stack
# nothing will drain again — so everything reachable only through those
# children is unmarked when the sweep runs, and gets reclaimed while live.
#
# The counter is now incremented inside the same critical section that removes
# the entries, and both halves of the termination condition are read from one.
#
# The graph here is built so the end of the drain is where the work is: a wide
# ring of chains, each chain reachable only through its predecessor, so the
# mark stack stays populated to the last batches and every node is a node the
# mark must walk to. Every node carries a sentinel; after each collection the
# whole graph is walked and checked, so a reclaimed-and-reused node is caught
# whether it faults or not.
#
#   crystal build -Dgc_none bench/parallel_mark_termination.cr -o bin/parallel_mark_termination
#   bin/parallel_mark_termination
#   GCRY_MARK_BUSY_UNLOCKED=1 bin/parallel_mark_termination --unlocked   # red arm
#
# The arms run as child processes: the red one is expected to lose live
# objects, and a process that dies of that cannot report it.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "parallel_mark_termination requires -Dgc_none (gcry as process GC)" %}
{% end %}

CHAINS    =  64
CHAIN_LEN = 400
COLLECTS  =  60
WORKERS   =   4
# The longest an arm's child may run. The fixed arm takes about a second.
CHILD_LIMIT = 120.seconds

class Node
  property next : Node?
  property tag : String
  property fill : Array(Int64)

  def initialize(@tag : String)
    # A payload big enough that reuse overwrites the sentinel, and scanned, so
    # the node is a real edge the mark has to follow.
    @fill = Array(Int64).new(8) { |i| 0x5A5A_0000_u64.to_i64 + i }
  end
end

def build : Array(Node)
  heads = Array(Node).new(CHAINS)
  CHAINS.times do |c|
    head = Node.new("chain-#{c}-0")
    cur = head
    (1...CHAIN_LEN).each do |i|
      n = Node.new("chain-#{c}-#{i}")
      cur.next = n
      cur = n
    end
    heads << head
  end
  heads
end

# Returns the first damage found, or nil.
def check(heads : Array(Node)) : String?
  heads.each_with_index do |head, c|
    cur = head.as(Node?)
    i = 0
    while node = cur
      return "chain #{c} node #{i}: tag #{node.tag.inspect}" unless node.tag == "chain-#{c}-#{i}"
      f = node.fill
      return "chain #{c} node #{i}: fill size #{f.size}" unless f.size == 8
      return "chain #{c} node #{i}: fill[0] #{f[0]}" unless f[0] == 0x5A5A_0000_u64.to_i64
      cur = node.next
      i += 1
    end
    return "chain #{c} ended at #{i}, not #{CHAIN_LEN}" unless i == CHAIN_LEN
  end
  nil
end

unless ARGV.includes?("--child")
  exe = Process.executable_path.not_nil!
  puts "=== parallel mark termination ==="
  puts "#{CHAINS} chains x #{CHAIN_LEN} nodes, #{WORKERS} workers, #{COLLECTS} collections per arm"

  failures = [] of String
  [{"fixed", {} of String => String, ["--child"]},
   {"unlocked", {"GCRY_MARK_BUSY_UNLOCKED" => "1"}, ["--child", "--unlocked"]}].each do |(arm, env, args)|
    captured = IO::Memory.new
    child = Process.new(exe, args, env: env, output: captured, error: captured)
    # A bounded wait. The red arm loses live objects on purpose, and what that
    # does next is up to the memory it corrupts: it reports damage, dies of
    # it, or — seen once on Windows x86_64 CI, 2026-10-08 — spins on a
    # corrupted word until the job's timeout killed it 29 minutes later.
    hung = Atomic(Int32).new(0)
    done = Atomic(Int32).new(0)
    # A thread, not a fiber: `Process#wait` may block this one. It reads only
    # `done`, so it never races `wait` for the child's status.
    watchdog = Thread.new do
      deadline = Time.instant + CHILD_LIMIT
      while Time.instant < deadline && done.get == 0
        Thread.sleep(100.milliseconds)
      end
      if done.get == 0
        hung.set(1)
        begin
          child.terminate(graceful: false)
        rescue
          # It exited between the check and the kill.
        end
      end
    end
    status = child.wait
    done.set(1)
    watchdog.join
    text = captured.to_s
    verdict = text.lines.find(&.starts_with?("child ")) || "(no verdict line)"
    verdict = "(killed after #{CHILD_LIMIT.total_seconds.to_i} s) #{verdict}" if hung.get == 1
    puts "#{arm}: exit=#{status.exit_code?.inspect} #{verdict}"

    if arm == "fixed"
      failures << "fixed: hung past #{CHILD_LIMIT.total_seconds.to_i} s" if hung.get == 1
      failures << "fixed: exited #{status.exit_code?.inspect}" unless status.success?
      failures << "fixed: the graph was damaged — a live object was reclaimed" if text.includes?("damage=")
      failures << "fixed: the parallel marker never ran" if text.includes?("runs=0 ")
      failures << "fixed: no worker ever took a batch, so no arm here means anything" if text.includes?("stolen=0 ")
    else
      # It reported damage, died of it, or hung on it. All three are the defect.
      if hung.get == 0 && status.success? && !text.includes?("damage=")
        failures << "unlocked: the pre-fix protocol ran #{COLLECTS} collections " \
                    "with no damage, so the fixed arm's silence is not evidence"
      end
    end
  end

  if failures.empty?
    puts
    puts "ok — the mark cycle does not end while a worker holds a batch"
    exit 0
  else
    puts
    failures.each { |f| STDERR.puts "FAIL: #{f}" }
    exit 1
  end
end

heap = Gcry.default_heap
raise "expected the process GC" unless heap.stop_the_world
heap.parallel_mark_workers = WORKERS
# The graph is a few MiB, under the default's serial floor (32 MiB live).
heap.parallel_mark_min_live = 0_u64

heads = build
damage = nil.as(String?)
runs = 0_u64
stolen = 0_u64

COLLECTS.times do
  # Churn, so reclaimed nodes are handed out and overwritten rather than
  # sitting untouched and passing the check by luck.
  junk = Array(String).new(2000) { |i| "junk-#{i}-#{"q" * 48}" }
  raise "junk lost" if junk.size != 2000
  GC.collect
  damage ||= check(heads)
  break if damage
end
runs = heap.parallel_mark_runs
stolen = heap.parallel_mark_stolen

print "child runs=#{runs} stolen=#{stolen} "
print "damage=#{damage} " if damage
puts(damage ? "FAIL" : "ok")
exit(damage ? 1 : 0)
