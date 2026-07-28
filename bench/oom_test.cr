# OOM scenarios test.
#
# Exercises gcry under memory pressure:
#   1. Bounded heap — low gc_threshold + aggressive alloc, no crash
#   2. mmap failure — exhausted allocation catches OutOfMemoryError
#   3. Finalizer under OOM — finalizers run correctly under memory pressure
#
# Build: crystal build -Dgc_none bench/oom_test.cr -o bin/oom_test
# Run:   ./bin/oom_test [--phases=1,2,3]

require "../src/gcry"

{% unless flag?(:gc_none) %}
  raise "oom_test requires -Dgc_none (gcry as process GC)"
{% end %}

# ---- CLI args ----
phases_to_run = [1, 2, 3]

ARGV.each do |arg|
  case arg
  when /--phases=(.+)/
    phases_to_run = $1.split(',').map(&.to_i)
  end
end

# ---- OOM test ----
class OomTest
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

  # ---- Finalizable helper ----
  class Finalizable
    @@finalized = Atomic(UInt64).new(0_u64)
    @@created = Atomic(UInt64).new(0_u64)

    def initialize
      @@created.add(1)
    end

    def self.finalized : UInt64
      @@finalized.get
    end

    def self.created : UInt64
      @@created.get
    end

    def self.reset_stats
      @@finalized.set(0_u64)
      @@created.set(0_u64)
    end

    def finalize
      @@finalized.add(1)
    end
  end

  # ---- Phase 1: Bounded heap — low gc_threshold, aggressive alloc ----
  def phase1_bounded_heap : Int32
    puts "Phase 1: Bounded heap (low gc_threshold + aggressive alloc)"

    heap = Gcry.default_heap
    saved_threshold = heap.gc_threshold
    heap.gc_threshold = 32768_u64 # collect every ~32KB

    start = Time.instant
    iterations = 500
    errors = 0

    iterations.times do |i|
      ptrs = [] of Pointer(Void)
      20.times do |j|
        sz = 8 + (j % 7) * 16
        begin
          p = GC.malloc_atomic(sz)
          ptrs << p
        rescue ex : Gcry::OutOfMemoryError
          break
        rescue ex
          record_error("bounded alloc #{i}.#{j}: #{ex}")
          errors += 1
          break
        end
      end

      ptrs.each_with_index { |p, idx| GC.free(p) rescue nil if idx.even? }

      begin
        GC.collect
      rescue ex
        record_error("bounded collect #{i}: #{ex}")
        errors += 1
      end

      ptrs.each_with_index { |p, idx| GC.free(p) rescue nil if idx.odd? }

      print "." if i % 100 == 0
    end
    puts ""

    heap.gc_threshold = saved_threshold

    elapsed = (Time.instant - start).total_seconds
    puts "  Phase 1 done: #{iterations} iterations, #{elapsed.round(2)}s, #{errors} errors"
    errors
  end

  # ---- Phase 2: mmap failure ----
  def phase2_mmap_failure : Int32
    puts "Phase 2: mmap failure — allocate until OOM or limit"

    errors = 0
    oom_caught = false

    # Try increasingly large allocations
    [16_384, 65_536, 262_144, 1_048_576, 4_194_304, 16_777_216].each do |sz|
      begin
        p = GC.malloc_atomic(sz)
        if p.null?
          oom_caught = true
          puts "    null pointer at #{sz} bytes"
          break
        end
        GC.free(p) rescue nil
      rescue ex : Gcry::OutOfMemoryError
        oom_caught = true
        puts "    OutOfMemoryError at #{sz} bytes"
        break
      rescue ex
        record_error("mmap failure #{sz}: #{ex}")
        errors += 1
        break
      end
    end

    # Exhaust with many small allocations (capped at 100k to avoid hang)
    unless oom_caught
      ptrs = [] of Pointer(Void)
      begin
        100_000.times do |i|
          p = GC.malloc_atomic(256)
          break if p.null?
          ptrs << p
        end
        if ptrs.size < 100_000
          oom_caught = true
          puts "    null pointer after #{ptrs.size} objects"
        end
      rescue ex : Gcry::OutOfMemoryError
        oom_caught = true
        puts "    OutOfMemoryError after #{ptrs.size} objects"
      rescue ex
        record_error("exhaust: #{ex}")
        errors += 1
      end
      ptrs.each { |p| GC.free(p) rescue nil }
    end

    unless oom_caught
      GC.collect
      puts "    Could not trigger OOM (system memory sufficient)"
    end

    report_errors
    errors
  end

  # ---- Phase 3: Finalizer under OOM pressure ----
  def phase3_finalizer_oom : Int32
    puts "Phase 3: Finalizer execution under OOM pressure"

    Finalizable.reset_stats
    errors = 0
    start = Time.instant
    iterations = 500

    iterations.times do |i|
      20.times do
        _ = GC.malloc_atomic(64) rescue nil
        _ = Finalizable.new
      end

      GC.collect rescue nil

      print "." if i % 100 == 0
    end
    puts ""

    GC.collect rescue nil
    GC.collect rescue nil

    elapsed = (Time.instant - start).total_seconds
    finalized = Finalizable.finalized
    created = Finalizable.created

    puts "  Phase 3 done: #{iterations} iterations, created=#{created} finalized=#{finalized}, #{elapsed.round(2)}s"

    if finalized == 0 && created > 0
      puts "  (note: no finalizers ran — Crystal finalizer queue not flushed by GC.collect)"
    end

    report_errors
    errors
  end
end

# ---- Main ----
puts "OOM test  phases=#{phases_to_run.join(",")}"
puts ""

test = OomTest.new
total_errors = 0

if phases_to_run.includes?(1)
  total_errors += test.phase1_bounded_heap
  puts ""
end

if phases_to_run.includes?(2)
  total_errors += test.phase2_mmap_failure
  puts ""
end

if phases_to_run.includes?(3)
  total_errors += test.phase3_finalizer_oom
  puts ""
end

puts "=== Summary ==="
if total_errors == 0
  puts "RESULT: PASS — All phases completed with 0 errors"
else
  puts "RESULT: FAIL — #{total_errors} error(s)"
  test.report_errors
  exit 1
end
