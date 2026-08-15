# 24-hour soak test for gcry.
#
# Sustains heavy allocation / collection load and verifies stability:
#   - Alloc storm: ~1000 objects/s
#   - Periodic collect: 1 Hz
#   - Fiber spawn: ~10 Hz
#   - Run-queue churn: opt-in, --fiber-churn=N fibers per 1 ms burst (default 0)
#   - Finalizer load: ~100 objects/s
#   - WeakRef / disappearing links: ~10 Hz
#
# Hourly telemetry: heap size, pause stats, live_objects, RSS.
# After soak: RSS within --rss-limit % of start (default 10), no crashes.
#
# Build:  crystal build -Dgc_none bench/soak.cr -o bin/soak
# Run:    ./bin/soak [--duration=3600] [--telemetry=/tmp/soak.log] [--rss-limit-kb=4096]
#         ./bin/soak --fiber-churn=512 --rss-limit-kb=131072   # queue-audit arm

require "../src/gcry"
require "./bench_rss"

{% unless flag?(:gc_none) %}
  raise "soak test requires -Dgc_none (gcry as process GC)"
{% end %}

# ---- CLI args ----
duration = 24 * 3600
telemetry_path = "/tmp/gcry-soak.log"
# Absolute, not a percentage of the starting RSS. Measured on this collector:
# RSS is a step function of gcry's 256 KiB chunk granularity plus a one-off
# warm-up, and the step total does not grow with duration — ~960 kB over a 4 h
# run (6400 → 7360 kB, two plateaus, heap *shrinking* 2244 → 2116 kB) against
# ~752 kB over a 10 s smoke. A percentage bound on a ~6 MB base turned that into
# a failure: three chunks were enough to cross 10%. A leak looks nothing like it
# — it ramps — so the ceiling is an absolute headroom over the warm-up plateau.
rss_limit_kb = 4096
# Fibers per 10 ms burst, on top of the ~10 Hz spawn above. Default 0 — the
# baseline every earlier soak ran on, and the one the open 2026-08-10 SEGV is
# measured against. It exists because `GCRY_EC_QUEUE_AUDIT` can only catch a slot
# that is corrupt *while* a collection sees it, and the default workload's run
# queues hold 0–1 slots per collection (~10 Hz spawn against ~1 Hz collect). This
# raises queue occupancy without touching anything else about the workload.
fiber_churn = 0

# The other multiplier on the same product. The audit can only catch a slot that
# is corrupt *while a collection sees it*, so the rate at which a run could catch
# a fault is (collections) x (occupancy). `--fiber-churn` raised occupancy from
# 1-in-24 to 23-in-24; the collect cadence was never touched and sat hardcoded at
# 1 Hz. `GCRY_THRESHOLD` does not move it — measured 118/119/119 collections over
# 120 s at the 32 MiB default, 8 MiB and 2 MiB — because these collections are
# the harness's own timer, not the allocator's. Default **1**, the cadence every
# earlier soak ran on and the one the open 2026-08-10 SEGV is measured against.
collect_hz = 1

ARGV.each do |arg|
  case arg
  when /--duration=(\d+)/
    duration = $1.to_i
  when /--telemetry=(.+)/
    telemetry_path = $1
  when /--rss-limit-kb=(\d+)/
    rss_limit_kb = $1.to_i64
  when /--fiber-churn=(\d+)/
    fiber_churn = $1.to_i
  when /--collect-hz=(\d+)/
    collect_hz = $1.to_i
  when /--rss-limit=(\d+)/
    # Deliberately fatal rather than reinterpreted: the old flag was a percent,
    # so silently reading "30" as 30 kB would turn a loose bound into an
    # impossible one and every soak would fail for the wrong reason.
    STDERR.puts "--rss-limit is gone (it was a percentage of a ~6 MB base, which " \
                "one 256 KiB chunk could move by 4%). Use --rss-limit-kb=<kB>."
    exit 64
  end
end

# Churn holds thousands of fiber stacks in the stack pool, so the RSS ceiling
# the baseline workload is gated on cannot hold: measured **+44.7 MB** over 25 s
# at `--fiber-churn=512` against a +4 MB default. Refuse rather than fail the run
# on a bound nobody chose — the same call the `--rss-limit` removal above makes,
# and for the same reason: a gate that trips for an unrelated reason teaches
# nothing.
if fiber_churn > 0 && rss_limit_kb <= 4096
  STDERR.puts "--fiber-churn=#{fiber_churn} needs a raised --rss-limit-kb: the churn keeps " \
              "thousands of fiber stacks in the pool (+44.7 MB measured over 25 s at 512), and " \
              "a #{rss_limit_kb} kB ceiling is for the baseline workload."
  exit 64
end

if collect_hz < 1
  STDERR.puts "--collect-hz=#{collect_hz} would divide by zero or stop collecting altogether. " \
              "Use 1 for the baseline cadence, or a higher integer to raise it."
  exit 64
end

# ---- Process RSS ----
# The RSS ceiling is one of two things this soak asserts, so a platform that
# cannot answer must stop the run rather than compare zeros. That is not
# hypothetical: the reader this replaced was `/proc/self/status` with a
# `rescue 0_u64`, which on Darwin passes the ceiling by measuring nothing.
unless BenchRss.available?
  STDERR.puts "cannot read this process's RSS on this platform, and the soak's " \
              "second assertion is an RSS ceiling — refusing to run a gate that " \
              "would compare zeros and pass."
  exit 64
end

def read_rss_kb : UInt64
  BenchRss.read_kb
end

# ---- Finalizer class ----
class SoakFinalizable
  @@count = Atomic(UInt64).new(0_u64)
  @@seen = Atomic(UInt64).new(0_u64)

  def initialize
    @@count.add(1)
  end

  def self.count : UInt64
    @@count.get
  end

  def self.seen : UInt64
    @@seen.get
  end

  def finalize
    @@seen.add(1)
  end
end

# ---- Soak test ----
class SoakTest
  @heap : Gcry::Heap
  @telemetry_path : String
  @errors : Array(String)
  @errors_mutex : Mutex
  @live_strings : Array(String)
  @live_mutex : Mutex
  @total_alloc : UInt64
  @total_collect : UInt64
  @total_fibers : UInt64
  @total_finalizable : UInt64
  @total_weakref : UInt64
  @total_churn : UInt64
  # Queue occupancy seen by the audit, accumulated at the soak's own 1 Hz
  # collections. Sampling the counter from the telemetry loop instead would read
  # whatever the *last* collection happened to see, which is 0 most of the time
  # even under churn — the thing being measured is bursty by construction.
  @queue_slots_total : UInt64
  @queue_slots_max : UInt64
  # Collections whose walk had something to walk. This is the number the audit's
  # usefulness actually turns on: a corrupt slot is only caught if a collection
  # lands while it is inside head..tail, so "how often is the queue non-empty
  # when the world stops" bounds what the instrument can ever see.
  @queue_slots_hits : UInt64

  @rss_max = 0_u64
  @rss_samples = 0

  def initialize(@telemetry_path : String, @rss_limit_kb : Int64 = 4096_i64, @fiber_churn : Int32 = 0,
                 @collect_hz : Int32 = 1)
    @heap = Gcry.default_heap.not_nil!
    @errors = [] of String
    @errors_mutex = Mutex.new(:reentrant)
    @live_strings = [] of String
    @live_mutex = Mutex.new(:reentrant)
    @total_alloc = 0_u64
    @total_collect = 0_u64
    @total_fibers = 0_u64
    @total_finalizable = 0_u64
    @total_weakref = 0_u64
    @total_churn = 0_u64
    @queue_slots_total = 0_u64
    @queue_slots_max = 0_u64
    @queue_slots_hits = 0_u64
  end

  def add_live(s : String)
    @live_mutex.synchronize do
      @live_strings << s
      @live_strings.shift if @live_strings.size > 1000
    end
  end

  def record_error(msg : String)
    @errors_mutex.synchronize { @errors << msg }
  end

  def collect_errors : Array(String)
    @errors_mutex.synchronize { @errors.dup }
  end

  def run(duration_sec : Int32) : Bool
    puts "Soak test duration=#{duration_sec}s"
    puts "Start RSS: #{read_rss_kb} kB"

    start_time = Time.instant
    start_rss = read_rss_kb

    telemetry = File.open(@telemetry_path, "w")
    telemetry.puts "gcry soak telemetry"
    telemetry.puts "start=#{start_time} duration=#{duration_sec}s start_rss=#{start_rss}kB"
    # Which configuration actually booted, read from the collector rather than
    # from the environment. A soak arm labelled "gate off" that quietly booted
    # with the gate on measures nothing, and a crash logged without this line
    # cannot be attributed to either arm afterwards.
    telemetry.puts "config: monitor_gate=#{Gcry::MonitorGate.enabled?} " \
                   "stw_test_stall_ms=#{@heap.stw_test_stall_ms} " \
                   "ec_queue_audit=#{@heap.ec_queue_audit} fiber_churn=#{@fiber_churn} " \
                   "collect_hz=#{@collect_hz}"
    # `queue_faults` is why the audit is worth a column: the 2026-08-10 run
    # SEGV'd in the dequeue an unknown time after the write that caused it, and a
    # cumulative fault count here says which hour the slot went bad.
    telemetry.puts "hour\telapsed\theap_kb\tfree_kb\tlive_objects\tcollections\tpause_p50\tpause_p99\trss_kb\tfinalized\tqueue_slots_total\tqueue_slots_max\tqueue_slots_hits\tqueue_faults"
    telemetry.flush
    puts "Config: monitor_gate=#{Gcry::MonitorGate.enabled?} " \
         "stw_test_stall_ms=#{@heap.stw_test_stall_ms} " \
         "ec_queue_audit=#{@heap.ec_queue_audit} fiber_churn=#{@fiber_churn} " \
         "collect_hz=#{@collect_hz}"

    # Thread spawn for alloc storm (~1000 objects/s)
    spawn do
      rng = Random.new(42)
      loop do
        10.times do
          s = "soak-#{rng.rand(0..1_000_000)}-#{"x" * (rng.rand(0..128))}"
          add_live(s)
          @total_alloc += 1
        end
        sleep(0.01.seconds)
      end
    end

    # Periodic collect (`--collect-hz`, 1 Hz baseline)
    collect_interval = (1.0 / @collect_hz).seconds
    spawn do
      loop do
        sleep(collect_interval)
        begin
          GC.collect
          @total_collect += 1
          slots = @heap.ec_queue_audit_ring_slots + @heap.ec_queue_audit_list_slots
          @queue_slots_total += slots
          @queue_slots_max = slots if slots > @queue_slots_max
          @queue_slots_hits += 1 if slots > 0
        rescue ex
          record_error("collect: #{ex}")
        end
      end
    end

    # Fiber spawn (~10 Hz)
    spawn do
      rng = Random.new(43)
      loop do
        sleep(0.1.seconds)
        spawn do
          s = "fiber-#{rng.rand(0..1_000_000)}"
          add_live(s)
        end
        @total_fibers += 1
      end
    end

    # Run-queue churn (opt-in, --fiber-churn=N). Each fiber does nothing but
    # yield once and exit, so they queue and drain rather than accumulate live
    # data: what this adds is *occupancy* of the scheduler's ring and the global
    # queue, which is what the queue audit needs in order to have anything to
    # look at.
    if @fiber_churn > 0
      spawn do
        loop do
          sleep(0.001.seconds)
          @fiber_churn.times do
            spawn do
              # Four yields, not one: a fiber that returns immediately is drained
              # by a worker in microseconds and the ring is empty again before
              # any collection can see it. Yielding puts it back on the queue, so
              # a burst keeps depth for as long as it takes to round-robin.
              4.times { Fiber.yield }
            end
            @total_churn += 1
          end
        end
      end
    end

    # Finalizer load (~100/s)
    spawn do
      loop do
        sleep(0.01.seconds)
        _ = SoakFinalizable.new
        @total_finalizable += 1
      end
    end

    # WeakRef load via disappearing links (~10 Hz)
    spawn do
      rng = Random.new(45)
      loop do
        sleep(0.1.seconds)
        ref = nil.as(Void*)
        boxed = Box(Int32).box(rng.rand(0..1_000_000))
        Gcry.register_disappearing_link(pointerof(ref), boxed)
        @total_weakref += 1
      end
    end

    # Coordinator loop
    deadline = start_time + duration_sec.seconds
    last_telemetry_hour = 0
    # The hourly line is too coarse to say how much of the window under test a
    # run reached before it died. `monitor_blocks` is the direct count of the
    # Monitor being held off at the edge of a stopped world, i.e. of the overlap
    # that used to run through it.
    last_gate_beat = 0

    loop do
      now = Time.instant
      elapsed = (now - start_time).total_seconds.to_i
      remaining = (deadline - now).total_seconds.to_i
      remaining = remaining < 0 ? 0 : remaining

      # Hourly telemetry
      current_hour = elapsed / 3600
      if current_hour > last_telemetry_hour
        m = Gcry.metrics(@heap)
        rss = read_rss_kb
        @rss_max = rss if rss > @rss_max
        @rss_samples += 1
        telemetry.puts "#{current_hour}\t#{elapsed}\t#{m.heap_size / 1024}\t#{m.free_bytes / 1024}\t#{m.live_objects}\t#{m.collections}\t#{m.pause_p50_ns}\t#{m.pause_p99_ns}\t#{rss}\t#{SoakFinalizable.seen}\t#{@queue_slots_total}\t#{@queue_slots_max}\t#{@queue_slots_hits}\t#{@heap.ec_queue_audit_faults}"
        telemetry.flush
        last_telemetry_hour = current_hour

        puts "[hour #{current_hour}] elapsed=#{elapsed}s remaining=#{remaining}s " +
             "heap=#{m.heap_size / 1024}kB live=#{m.live_objects} " +
             "rss=#{rss}kB finalized=#{SoakFinalizable.seen} errors=#{@errors.size}"
      end

      if elapsed - last_gate_beat >= 60
        last_gate_beat = elapsed
        m = Gcry.metrics(@heap)
        telemetry.puts "# gate elapsed=#{elapsed}s collections=#{m.collections} " \
                       "monitor_blocks=#{Gcry::MonitorGate.monitor_blocks} " \
                       "stw_waits=#{Gcry::MonitorGate.stw_waits} " \
                       "stw_wait_max_ns=#{Gcry::MonitorGate.stw_wait_max_ns}"
        telemetry.flush
      end

      # Check errors
      errs = collect_errors
      if errs.any?
        telemetry.puts "# result: FAIL"
        telemetry.puts "end=#{Time.instant}"
        telemetry.close
        puts "FAIL: #{errs.size} error(s)"
        errs.each { |e| STDERR.puts "  SOAK FAIL: #{e}" }
        return false
      end

      if now >= deadline
        puts "Duration reached (#{duration_sec}s). Draining..."
        break
      end

      sleep(5.seconds)
    end

    # ---- Post-soak verification ----
    puts "Post-soak verification..."

    @live_mutex.synchronize { @live_strings.clear }
    8.times { GC.collect }

    m = Gcry.metrics(@heap)
    rss_end = read_rss_kb

    puts "Final: heap=#{m.heap_size / 1024}kB live=#{m.live_objects} rss=#{rss_end}kB finalized=#{SoakFinalizable.seen}"

    # RSS growth ceil (default 10%). Short CI smokes use a looser --rss-limit:
    # DONTNEED re-fault / page-cache noise on shared GHA hosts often lands ~11%.
    if start_rss > 0 && @rss_limit_kb >= 0
      limit = start_rss + @rss_limit_kb.to_u64
      if rss_end > limit
        grew = rss_end - start_rss
        msg = "RSS grew #{grew}kB (start=#{start_rss}kB end=#{rss_end}kB " \
              "max=#{@rss_max}kB over #{@rss_samples} samples, ceiling +#{@rss_limit_kb}kB). " \
              "If end == max and the samples sit on a few plateaus this is chunk " \
              "granularity, not a leak; a leak ramps."
        telemetry.puts "# result: FAIL: #{msg}"
        telemetry.close
        STDERR.puts "  SOAK FAIL: #{msg}"
        return false
      end
    end

    telemetry.puts "# result: PASS"
    telemetry.puts "end=#{Time.instant}"
    telemetry.puts "end_rss=#{rss_end}kB"
    telemetry.puts "allocs=#{@total_alloc} collects=#{@total_collect} fibers=#{@total_fibers} churn=#{@total_churn} finalizable=#{@total_finalizable} weakref=#{@total_weakref}"
    telemetry.puts "monitor_gate=#{Gcry::MonitorGate.enabled?} " \
                   "monitor_blocks=#{Gcry::MonitorGate.monitor_blocks} " \
                   "stw_waits=#{Gcry::MonitorGate.stw_waits} " \
                   "stw_wait_max_ns=#{Gcry::MonitorGate.stw_wait_max_ns}"
    telemetry.close

    puts "Soak test PASSED"
    puts "  duration=#{duration_sec}s"
    puts "  allocs=#{@total_alloc} collects=#{@total_collect} fibers=#{@total_fibers} churn=#{@total_churn}"
    puts "  queue slots seen: total=#{@queue_slots_total} max_per_collect=#{@queue_slots_max} " \
         "non_empty=#{@queue_slots_hits}/#{@total_collect} faults=#{@heap.ec_queue_audit_faults}"
    puts "  finalizable=#{@total_finalizable} weakref=#{@total_weakref}"
    puts "  finalized=#{SoakFinalizable.seen}"
    puts "  RSS: #{start_rss}kB → #{rss_end}kB (+#{rss_end.to_i64 - start_rss.to_i64}kB, max #{@rss_max}kB, ceiling +#{@rss_limit_kb}kB)"
    puts "  Telemetry: #{@telemetry_path}"

    true
  end
end

# ---- Entry point ----
test = SoakTest.new(telemetry_path, rss_limit_kb.to_i64, fiber_churn, collect_hz)
success = test.run(duration)
exit(1) unless success
