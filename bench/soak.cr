# 24-hour soak test for gcry.
#
# Sustains heavy allocation / collection load and verifies stability:
#   - Alloc storm: ~1000 objects/s
#   - Periodic collect: 1 Hz
#   - Fiber spawn: ~10 Hz
#   - Finalizer load: ~100 objects/s
#   - WeakRef / disappearing links: ~10 Hz
#
# Hourly telemetry: heap size, pause stats, live_objects, RSS.
# After soak: RSS within --rss-limit % of start (default 10), no crashes.
#
# Build:  crystal build -Dgc_none bench/soak.cr -o bin/soak
# Run:    ./bin/soak [--duration=3600] [--telemetry=/tmp/soak.log] [--rss-limit=10]

require "../src/gcry"

{% unless flag?(:gc_none) %}
  raise "soak test requires -Dgc_none (gcry as process GC)"
{% end %}

# ---- CLI args ----
duration = 24 * 3600
telemetry_path = "/tmp/gcry-soak.log"
rss_limit_pct = 10

ARGV.each do |arg|
  case arg
  when /--duration=(\d+)/
    duration = $1.to_i
  when /--telemetry=(.+)/
    telemetry_path = $1
  when /--rss-limit=(\d+)/
    rss_limit_pct = $1.to_i
  end
end

# ---- Process RSS helper (Linux /proc/self/status) ----
def read_rss_kb : UInt64
  File.open("/proc/self/status") do |f|
    f.each_line do |line|
      if line.starts_with?("VmRSS:")
        parts = line.split
        return parts[1].to_u64 if parts.size >= 2
      end
    end
  end
  0_u64
rescue
  0_u64
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

  def initialize(@telemetry_path : String, @rss_limit_pct : Int32 = 10)
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
    telemetry.puts "hour\telapsed\theap_kb\tfree_kb\tlive_objects\tcollections\tpause_p50\tpause_p99\trss_kb\tfinalized"
    telemetry.flush

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

    # Periodic collect (1 Hz)
    spawn do
      loop do
        sleep(1.seconds)
        begin
          GC.collect
          @total_collect += 1
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
        telemetry.puts "#{current_hour}\t#{elapsed}\t#{m.heap_size / 1024}\t#{m.free_bytes / 1024}\t#{m.live_objects}\t#{m.collections}\t#{m.pause_p50_ns}\t#{m.pause_p99_ns}\t#{rss}\t#{SoakFinalizable.seen}"
        telemetry.flush
        last_telemetry_hour = current_hour

        puts "[hour #{current_hour}] elapsed=#{elapsed}s remaining=#{remaining}s " +
             "heap=#{m.heap_size / 1024}kB live=#{m.live_objects} " +
             "rss=#{rss}kB finalized=#{SoakFinalizable.seen} errors=#{@errors.size}"
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
    if start_rss > 0 && @rss_limit_pct >= 0
      limit = start_rss + start_rss * @rss_limit_pct.to_u64 / 100
      if rss_end > limit
        msg = "RSS leak: start=#{start_rss}kB end=#{rss_end}kB (> #{@rss_limit_pct}%)"
        telemetry.puts "# result: FAIL: #{msg}"
        telemetry.close
        STDERR.puts "  SOAK FAIL: #{msg}"
        return false
      end
    end

    telemetry.puts "# result: PASS"
    telemetry.puts "end=#{Time.instant}"
    telemetry.puts "end_rss=#{rss_end}kB"
    telemetry.puts "allocs=#{@total_alloc} collects=#{@total_collect} fibers=#{@total_fibers} finalizable=#{@total_finalizable} weakref=#{@total_weakref}"
    telemetry.close

    puts "Soak test PASSED"
    puts "  duration=#{duration_sec}s"
    puts "  allocs=#{@total_alloc} collects=#{@total_collect} fibers=#{@total_fibers}"
    puts "  finalizable=#{@total_finalizable} weakref=#{@total_weakref}"
    puts "  finalized=#{SoakFinalizable.seen}"
    puts "  RSS: #{start_rss}kB → #{rss_end}kB (#{(rss_end * 100.0 / start_rss).round(1)}%)"
    puts "  Telemetry: #{@telemetry_path}"

    true
  end
end

# ---- Entry point ----
test = SoakTest.new(telemetry_path, rss_limit_pct)
success = test.run(duration)
exit(1) unless success
