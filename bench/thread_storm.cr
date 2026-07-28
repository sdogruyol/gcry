# Thread death / spawn storm test.
#
# Exercises gcry under concurrent OS-thread create/destroy during GC cycles:
#   1. Thread spawn storm — N threads created, each allocates/collects/frees
#   2. Rapid thread create/destroy — threads created and joined in rapid succession
#   3. Signal safety — GC allocation inside signal handlers
#
# 1000 iterations total across all phases.
#
# Build: crystal build -Dgc_none bench/thread_storm.cr -o bin/thread_storm
# Run:   ./bin/thread_storm [--iterations=1000] [--workers=10]

require "../src/gcry"

{% unless flag?(:gc_none) %}
  raise "thread_storm requires -Dgc_none (gcry as process GC)"
{% end %}

# ---- CLI args ----
iterations = 1000
workers = 10

ARGV.each do |arg|
  case arg
  when /--iterations=(\d+)/
    iterations = $1.to_i
  when /--workers=(\d+)/
    workers = $1.to_i
  end
end

# ---- Thread storm test ----
class ThreadStormTest
  @errors : Array(String)
  @errors_mutex : Mutex

  def initialize
    @errors = [] of String
    @errors_mutex = Mutex.new(:reentrant)
  end

  def record_error(msg : String)
    @errors_mutex.synchronize { @errors << msg }
  end

  def error_count : Int32
    @errors_mutex.synchronize { @errors.size }
  end

  def report_errors
    @errors_mutex.synchronize do
      @errors.each { |e| STDERR.puts "  #{e}" }
    end
  end

  # Worker: allocate/free/collect inside an OS thread.
  # Each worker does its own GC cycle and thread registration.
  def worker_run(id : Int32, iters : Int32)
    rng = Random.new(id.to_i64 + 1000)
    iters.times do |j|
      ptrs = [] of Pointer(Void)
      10.times { ptrs << GC.malloc_atomic(32 + rng.rand(256)) }

      ptrs.each_with_index { |p, i| GC.free(p) if i.even? rescue nil }

      GC.collect if j % 3 == 0

      ptrs.each_with_index { |p, i| GC.free(p) if i.odd? rescue nil }
    end
  rescue ex
    record_error("worker #{id}: #{ex}")
  end

  # Phase 1: Thread spawn storm.
  # Spawn N threads, each doing alloc/free/collect cycles.
  # Between batches, the main thread also calls GC.collect to exercise
  # thread registration during active GC state.
  def phase1_spawn_storm(iters : Int32, wrkrs : Int32) : Int32
    puts "Phase 1: Thread spawn storm (#{iters} iterations, #{wrkrs} workers)"

    start = Time.instant
    batches = 10
    per_batch = wrkrs // batches
    per_batch = 1 if per_batch < 1

    batches.times do |batch|
      iters_per = iters // wrkrs
      threads = [] of Thread

      per_batch.times do |i|
        tid = batch * per_batch + i
        t = Thread.new { worker_run(tid, iters_per) }
        threads << t
      end

      # Wait for this batch to finish
      threads.each(&.join)

      # GC between batches to exercise thread tracking
      GC.collect
      _ = GC.malloc_atomic(64)

      print "." if batch % 3 == 0
    end
    puts ""

    elapsed = (Time.instant - start).total_seconds
    puts "  Phase 1 done: #{wrkrs} threads across #{batches} batches, #{elapsed.round(2)}s"
    report_errors
    error_count
  end

  # Phase 2: Rapid thread create/destroy — many short-lived threads.
  def phase2_rapid_create_destroy(iters : Int32) : Int32
    puts "Phase 2: Rapid thread create/destroy (#{iters} iterations)"

    # Heap pressure
    garbage = [] of Pointer(Void)
    10_000.times { garbage << GC.malloc_atomic(128) }
    garbage.each { |p| GC.free(p) rescue nil }

    start = Time.instant
    threads = [] of Thread
    completed = Atomic(UInt64).new(0_u64)

    iters.times do |i|
      t = Thread.new do
        _ = GC.malloc_atomic(64)
        _ = GC.malloc_atomic(128) if i % 3 == 0
        completed.add(1)
      rescue ex
        record_error("rapid #{i}: #{ex}")
      end
      threads << t

      if threads.size >= 20
        threads.each(&.join)
        threads.clear
      end

      print "." if i % 100 == 0
    end

    threads.each(&.join)
    puts ""

    elapsed = (Time.instant - start).total_seconds
    puts "  Phase 2 done: #{iters} threads, #{elapsed.round(2)}s (#{(iters / elapsed).round(0)} threads/s)"
    report_errors
    error_count
  end

  # Phase 3: Signal safety — GC alloc inside SIGUSR1 handler.
  # Signals are delivered to the main event loop via Crystal's Signal.trap.
  def phase3_signal_safety(iters : Int32) : Int32
    puts "Phase 3: Signal safety — GC alloc in signal handler (#{iters} iterations)"

    signaled = Atomic(UInt64).new(0_u64)
    handled = Atomic(UInt64).new(0_u64)

    Signal::USR1.trap do
      _p = GC.malloc_atomic(64)
      handled.add(1)
    end

    start = Time.instant

    iters.times do |i|
      p = GC.malloc_atomic(256)
      signaled.add(1)
      Process.signal(Signal::USR1, Process.pid)
      sleep(0.001.seconds)
      GC.free(p) rescue nil
      _ = GC.malloc_atomic(128)

      print "." if i % 50 == 0
    end
    puts ""

    Signal::USR1.reset

    elapsed = (Time.instant - start).total_seconds
    puts "  Phase 3 done: #{iters} iterations, signals=#{signaled.get}, handled=#{handled.get}, #{elapsed.round(2)}s"

    if handled.get == 0 && iters > 0
      record_error("Phase 3: Crystal signal handler never executed (handled=0)")
    end

    report_errors
    error_count
  end
end

# ---- Main ----
puts "Thread storm test"
puts "  iterations=#{iterations} workers=#{workers}"
puts ""

test = ThreadStormTest.new

errs = 0
errs += test.phase1_spawn_storm(iterations, workers)
puts ""

errs += test.phase2_rapid_create_destroy((iterations / 4).to_i)
puts ""

errs += test.phase3_signal_safety((iterations / 4).to_i)
puts ""

puts "=== Summary ==="
if errs == 0
  puts "RESULT: PASS — All phases completed with 0 errors"
else
  puts "RESULT: FAIL — #{errs} error(s)"
  test.report_errors
  exit 1
end
