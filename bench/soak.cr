# 24-hour soak test for gcry.
#
# Sustains heavy allocation / collection load and verifies stability:
#   - Alloc storm: ~1000 objects/s
#   - Periodic collect: 1 Hz
#   - Fiber spawn: ~10 Hz
#   - Finalizer load: ~100 objects/s
#   - WeakRef / disappearing links: ~10 Hz
#
# Hourly telemetry: heap size, pause stats, live_objects, RSS, finalizer table.
# After soak: stop workers, drain, then RSS within --rss-limit % of post-warmup
# baseline (default 10%), no crashes.
#
# Build:  crystal build -Dgc_none bench/soak.cr -o bin/soak
# Run:    ./bin/soak [--duration=3600] [--warmup=60] [--telemetry=/tmp/soak.log] [--rss-limit=10]

require "../src/gcry"

{% unless flag?(:gc_none) %}
  raise "soak test requires -Dgc_none (gcry as process GC)"
{% end %}

# ---- CLI args ----
duration = 24 * 3600
warmup_sec = 60
telemetry_path = "/tmp/gcry-soak.log"
rss_limit_pct = 10

ARGV.each do |arg|
  case arg
  when /--duration=(\d+)/
    duration = $1.to_i
  when /--warmup=(\d+)/
    warmup_sec = $1.to_i
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

# Heap-backed slot for disappearing links (stack locals are invalid once the
# fiber iteration ends — and writing through a stale link corrupts whatever
# reuses that stack word).
class SoakWeakSlot
  @link : Void* = Pointer(Void).null

  def link_ptr : Void**
    pointerof(@link)
  end
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
  @running : Atomic(Bool)
  @total_alloc : UInt64
  @total_collect : UInt64
  @total_fibers : UInt64
  @total_finalizable : UInt64
  @total_weakref : UInt64
  @weak_slots : Array(SoakWeakSlot)
  @weak_slot_i : Int32

  def initialize(@telemetry_path : String, @rss_limit_pct : Int32 = 10)
    @heap = Gcry.default_heap.not_nil!
    @errors = [] of String
    @errors_mutex = Mutex.new(:reentrant)
    @live_strings = [] of String
    @live_mutex = Mutex.new(:reentrant)
    @running = Atomic(Bool).new(true)
    @total_alloc = 0_u64
    @total_collect = 0_u64
    @total_fibers = 0_u64
    @total_finalizable = 0_u64
    @total_weakref = 0_u64
    @weak_slots = Array(SoakWeakSlot).new(64) { SoakWeakSlot.new }
    @weak_slot_i = 0
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

  def stop_workers : Nil
    @running.set(false)
  end

  def running? : Bool
    @running.get
  end

  private def snapshot_line(elapsed : Int32, hour : Int32) : String
    m = Gcry.metrics(@heap)
    rss = read_rss_kb
    "#{hour}\t#{elapsed}\t#{m.heap_size / 1024}\t#{m.free_bytes / 1024}\t#{m.live_objects}\t#{m.collections}\t#{m.pause_p50_ns}\t#{m.pause_p99_ns}\t#{rss}\t#{SoakFinalizable.seen}\t#{@heap.finalizer_entry_count}\t#{@heap.finalizer_link_count}"
  end

  private def fail_detail(rss_start : UInt64, rss_end : UInt64) : String
    m = Gcry.metrics(@heap)
    String.build do |io|
      io << "RSS leak: start=#{rss_start}kB end=#{rss_end}kB (> #{@rss_limit_pct}%)"
      io << " heap=#{m.heap_size / 1024}kB live=#{m.live_objects}"
      io << " fin_ent=#{@heap.finalizer_entry_count} links=#{@heap.finalizer_link_count}"
      io << " finalized=#{SoakFinalizable.seen}/#{SoakFinalizable.count}"
      io << " created=#{SoakFinalizable.count}"
    end
  end

  def run(duration_sec : Int32, warmup_sec : Int32 = 60) : Bool
    puts "Soak test duration=#{duration_sec}s warmup=#{warmup_sec}s"
    cold_rss = read_rss_kb
    puts "Cold RSS: #{cold_rss} kB"

    start_time = Time.instant

    telemetry = File.open(@telemetry_path, "w")
    telemetry.puts "gcry soak telemetry"
    telemetry.puts "start=#{start_time} duration=#{duration_sec}s warmup=#{warmup_sec}s cold_rss=#{cold_rss}kB"
    telemetry.puts "hour\telapsed\theap_kb\tfree_kb\tlive_objects\tcollections\tpause_p50\tpause_p99\trss_kb\tfinalized\tfin_ent\tlinks"
    telemetry.flush

    # Thread spawn for alloc storm (~1000 objects/s)
    spawn do
      rng = Random.new(42)
      while running?
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
      while running?
        sleep(1.seconds)
        break unless running?
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
      while running?
        sleep(0.1.seconds)
        break unless running?
        spawn do
          s = "fiber-#{rng.rand(0..1_000_000)}"
          add_live(s)
        end
        @total_fibers += 1
      end
    end

    # Finalizer load (~100/s)
    spawn do
      while running?
        sleep(0.01.seconds)
        break unless running?
        _ = SoakFinalizable.new
        @total_finalizable += 1
      end
    end

    # WeakRef load via disappearing links (~10 Hz)
    spawn do
      rng = Random.new(45)
      while running?
        sleep(0.1.seconds)
        break unless running?
        slot = @weak_slots[@weak_slot_i]
        @weak_slot_i = (@weak_slot_i + 1) % @weak_slots.size
        boxed = Box(Int32).box(rng.rand(0..1_000_000))
        Gcry.register_disappearing_link(slot.link_ptr, boxed.as(Void*))
        @total_weakref += 1
      end
    end

    # Warm-up: let heap / fiber pools reach steady shape before the RSS baseline.
    if warmup_sec > 0
      puts "Warming up #{warmup_sec}s..."
      sleep(warmup_sec.seconds)
    end

    start_rss = read_rss_kb
    puts "Baseline RSS (post-warmup): #{start_rss} kB"
    telemetry.puts "# baseline_rss=#{start_rss}kB after_warmup=#{warmup_sec}s"
    telemetry.flush

    # Coordinator loop — duration is measured after warmup.
    deadline = Time.instant + duration_sec.seconds
    last_telemetry_hour = 0
    soak_start = Time.instant

    loop do
      now = Time.instant
      elapsed = (now - soak_start).total_seconds.to_i
      remaining = (deadline - now).total_seconds.to_i
      remaining = remaining < 0 ? 0 : remaining

      # Hourly telemetry
      current_hour = elapsed // 3600
      if current_hour > last_telemetry_hour
        line = snapshot_line(elapsed, current_hour)
        telemetry.puts line
        telemetry.flush
        last_telemetry_hour = current_hour

        m = Gcry.metrics(@heap)
        rss = read_rss_kb
        puts "[hour #{current_hour}] elapsed=#{elapsed}s remaining=#{remaining}s " +
             "heap=#{m.heap_size / 1024}kB live=#{m.live_objects} " +
             "rss=#{rss}kB fin_ent=#{@heap.finalizer_entry_count} links=#{@heap.finalizer_link_count} " +
             "finalized=#{SoakFinalizable.seen} errors=#{@errors.size}"
      end

      # Check errors
      errs = collect_errors
      if errs.any?
        stop_workers
        telemetry.puts "# result: FAIL"
        telemetry.puts "end=#{Time.instant}"
        telemetry.close
        puts "FAIL: #{errs.size} error(s)"
        errs.each { |e| STDERR.puts "  SOAK FAIL: #{e}" }
        return false
      end

      if now >= deadline
        puts "Duration reached (#{duration_sec}s). Stopping workers + draining..."
        break
      end

      sleep(5.seconds)
    end

    # ---- Post-soak verification ----
    # Must stop mutator fibers first — otherwise end RSS is "under load", not drained.
    stop_workers
    sleep(0.5.seconds) # let in-flight sleeps notice the flag
    puts "Post-soak verification..."

    @live_mutex.synchronize { @live_strings.clear }
    8.times { GC.collect }
    sleep(0.2.seconds)
    2.times { GC.collect }

    m = Gcry.metrics(@heap)
    rss_end = read_rss_kb

    puts "Final: heap=#{m.heap_size / 1024}kB live=#{m.live_objects} rss=#{rss_end}kB " +
         "fin_ent=#{@heap.finalizer_entry_count} links=#{@heap.finalizer_link_count} " +
         "finalized=#{SoakFinalizable.seen}/#{SoakFinalizable.count}"

    telemetry.puts snapshot_line(duration_sec, (duration_sec // 3600) + 1)
    telemetry.flush

    # RSS growth ceil (default 10%). Short CI smokes use a looser --rss-limit:
    # DONTNEED re-fault / page-cache noise on shared GHA hosts often lands ~11%.
    # Baseline is post-warmup (not cold start) so empty-chunk / fiber-pool ramp
    # is not counted as a leak.
    if start_rss > 0 && @rss_limit_pct >= 0
      limit = start_rss + start_rss * @rss_limit_pct.to_u64 / 100
      if rss_end > limit
        msg = fail_detail(start_rss, rss_end)
        telemetry.puts "# result: FAIL: #{msg}"
        telemetry.close
        STDERR.puts "  SOAK FAIL: #{msg}"
        return false
      end
    end

    # Finalizer retention signal: created ≫ finalized after drain ⇒ registry leak.
    created = SoakFinalizable.count
    finalized = SoakFinalizable.seen
    if created > 1000 && finalized * 100 < created * 50
      msg = "finalizer retention: finalized=#{finalized} created=#{created} (<50%) fin_ent=#{@heap.finalizer_entry_count}"
      telemetry.puts "# result: FAIL: #{msg}"
      telemetry.close
      STDERR.puts "  SOAK FAIL: #{msg}"
      return false
    end

    telemetry.puts "# result: PASS"
    telemetry.puts "end=#{Time.instant}"
    telemetry.puts "end_rss=#{rss_end}kB baseline_rss=#{start_rss}kB cold_rss=#{cold_rss}kB"
    telemetry.puts "allocs=#{@total_alloc} collects=#{@total_collect} fibers=#{@total_fibers} finalizable=#{@total_finalizable} weakref=#{@total_weakref}"
    telemetry.puts "finalized=#{finalized} created=#{created} fin_ent=#{@heap.finalizer_entry_count} links=#{@heap.finalizer_link_count}"
    telemetry.close

    puts "Soak test PASSED"
    puts "  duration=#{duration_sec}s warmup=#{warmup_sec}s"
    puts "  allocs=#{@total_alloc} collects=#{@total_collect} fibers=#{@total_fibers}"
    puts "  finalizable=#{@total_finalizable} weakref=#{@total_weakref}"
    puts "  finalized=#{finalized}/#{created}"
    puts "  RSS: cold=#{cold_rss}kB baseline=#{start_rss}kB → end=#{rss_end}kB (#{(rss_end * 100.0 / start_rss).round(1)}% of baseline)"
    puts "  Telemetry: #{@telemetry_path}"

    true
  end
end

# ---- Entry point ----
test = SoakTest.new(telemetry_path, rss_limit_pct)
success = test.run(duration, warmup_sec)
exit(1) unless success
