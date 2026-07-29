# Microbenchmark suite for gcry.
#
# Measures alloc/free/collect latency, TLAB refill cost, STW suspend/resume
# latency, and GC lock overhead (safepoint proxy).
#
# Usage:
#   crystal build -Dgc_none bench/micro/run_all.cr -o bin/microbench
#   ./bin/microbench [--phases=1,2,3,4,5,6]
#
# Output: JSON lines to stdout.

require "../../src/gcry"

HEAP = Gcry.default_heap.not_nil!

SIZE_CLASSES    = [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096]
SAMPLES         = 10_000
WARMUP          =  1_000
COLLECT_SAMPLES =    100

# ---------- helpers ----------

def p50(arr : Array(UInt64)) : UInt64
  sorted = arr.sort!
  sorted[arr.size // 2]
end

def p99(arr : Array(UInt64)) : UInt64
  sorted = arr.sort!
  sorted[(arr.size * 99) // 100]
end

def max(arr : Array(UInt64)) : UInt64
  m = 0_u64
  arr.each { |v| m = v if v > m }
  m
end

def h_malloc(size) : Void*
  HEAP.malloc(size)
end

def h_free(ptr : Void*) : Nil
  HEAP.free(ptr)
end

# ---------- 1. Alloc latency ----------

def phase_alloc_latency : Array(NamedTuple(size: Int32, p50: UInt64, p99: UInt64, max: UInt64))
  results = [] of NamedTuple(size: Int32, p50: UInt64, p99: UInt64, max: UInt64)

  SIZE_CLASSES.each do |size|
    timings = Array(UInt64).new(SAMPLES)
    ptrs = [] of Void*

    # Warmup
    SAMPLES.times { ptrs << h_malloc(size.to_u64) }
    ptrs.each { |p| h_free(p) }
    ptrs.clear

    # Measure
    SAMPLES.times do
      t0 = Time.monotonic.total_nanoseconds
      p = h_malloc(size.to_u64)
      t1 = Time.monotonic.total_nanoseconds
      timings << (t1 - t0).to_u64
      ptrs << p
    end
    ptrs.each { |p| h_free(p) }

    results << {size: size, p50: p50(timings), p99: p99(timings), max: max(timings)}
  end

  results
end

# ---------- 2. Free latency ----------

def phase_free_latency : NamedTuple(p50: UInt64, p99: UInt64, max: UInt64)
  timings = Array(UInt64).new(SAMPLES)
  ptrs = [] of Void*

  SAMPLES.times { ptrs << h_malloc(64_u64) }

  SAMPLES.times do
    p = h_malloc(64_u64)
    t0 = Time.monotonic.total_nanoseconds
    h_free(p)
    t1 = Time.monotonic.total_nanoseconds
    timings << (t1 - t0).to_u64
  end
  ptrs.each { |p| h_free(p) }

  {p50: p50(timings), p99: p99(timings), max: max(timings)}
end

# ---------- 3. Collect latency ----------

def phase_collect_latency : NamedTuple(p50: UInt64, p99: UInt64, max: UInt64)
  timings = Array(UInt64).new(COLLECT_SAMPLES)
  old_threshold = HEAP.gc_threshold
  HEAP.gc_threshold = 1_u64 << 20

  COLLECT_SAMPLES.times do
    ptrs = [] of Void*
    5000.times { ptrs << h_malloc(128_u64) }

    GC.collect
    GC.collect

    t0 = Time.monotonic.total_nanoseconds
    GC.collect
    t1 = Time.monotonic.total_nanoseconds

    timings << (t1 - t0).to_u64

    ptrs.each { |p| h_free(p) }
  end

  HEAP.gc_threshold = old_threshold
  {p50: p50(timings), p99: p99(timings), max: max(timings)}
end

# ---------- 4. TLAB refill cost ----------

def phase_tlab_cost : NamedTuple(p50: UInt64, p99: UInt64, max: UInt64)
  was_enabled = HEAP.tlab_enabled?
  HEAP.tlab_enabled = true

  timings = Array(UInt64).new(SAMPLES)

  SAMPLES.times do
    _exhaust = h_malloc(65536_u64)
    t0 = Time.monotonic.total_nanoseconds
    p = h_malloc(64_u64)
    t1 = Time.monotonic.total_nanoseconds
    timings << (t1 - t0).to_u64
    h_free(p)
    h_free(_exhaust)
  end

  HEAP.tlab_enabled = was_enabled
  {p50: p50(timings), p99: p99(timings), max: max(timings)}
end

# ---------- 5. STW suspend/resume latency ----------

def phase_stw_latency : NamedTuple(p50: UInt64, p99: UInt64, max: UInt64)
  timings = Array(UInt64).new(COLLECT_SAMPLES)

  COLLECT_SAMPLES.times do
    t0 = Time.monotonic.total_nanoseconds
    HEAP.stop_world
    _x = 0
    t1 = Time.monotonic.total_nanoseconds
    HEAP.start_world
    t2 = Time.monotonic.total_nanoseconds

    timings << (t2 - t0).to_u64
  end

  {p50: p50(timings), p99: p99(timings), max: max(timings)}
end

# ---------- 6. Lock overhead (safepoint proxy) ----------

def phase_lock_cost : NamedTuple(empty_ns: UInt64, lock_ns: UInt64)
  iters = 1_000_000

  t0 = Time.monotonic.total_nanoseconds
  iters.times { }
  t1 = Time.monotonic.total_nanoseconds

  t2 = Time.monotonic.total_nanoseconds
  iters.times {
    HEAP.lock_read
    HEAP.unlock_read
  }
  t3 = Time.monotonic.total_nanoseconds

  empty_per = ((t1 - t0) // iters).to_u64
  lock_per = ((t3 - t2) // iters).to_u64

  {empty_ns: empty_per, lock_ns: lock_per}
end

# ---------- main ----------

phases_to_run = [] of Int32
all_phases = true

ARGV.each do |arg|
  if arg.starts_with?("--phases=")
    all_phases = false
    arg.lchop("--phases=").split(',').each { |s| phases_to_run << s.to_i }
  end
end

puts %({"benchmark": "micro", "samples": #{SAMPLES}, "timestamp": "#{Time.utc}"})

if all_phases || phases_to_run.includes?(1)
  alloc_res = phase_alloc_latency
  alloc_res.each do |r|
    puts %({"phase": 1, "metric": "alloc_latency", "size": #{r[:size]}, "p50_ns": #{r[:p50]}, "p99_ns": #{r[:p99]}, "max_ns": #{r[:max]}})
  end
end

if all_phases || phases_to_run.includes?(2)
  free_res = phase_free_latency
  puts %({"phase": 2, "metric": "free_latency", "p50_ns": #{free_res[:p50]}, "p99_ns": #{free_res[:p99]}, "max_ns": #{free_res[:max]}})
end

if all_phases || phases_to_run.includes?(3)
  collect_res = phase_collect_latency
  puts %({"phase": 3, "metric": "collect_latency", "p50_ns": #{collect_res[:p50]}, "p99_ns": #{collect_res[:p99]}, "max_ns": #{collect_res[:max]}})
end

if all_phases || phases_to_run.includes?(4)
  tlab_res = phase_tlab_cost
  puts %({"phase": 4, "metric": "tlab_refill_cost", "p50_ns": #{tlab_res[:p50]}, "p99_ns": #{tlab_res[:p99]}, "max_ns": #{tlab_res[:max]}})
end

if all_phases || phases_to_run.includes?(5)
  stw_res = phase_stw_latency
  puts %({"phase": 5, "metric": "stw_latency", "p50_ns": #{stw_res[:p50]}, "p99_ns": #{stw_res[:p99]}, "max_ns": #{stw_res[:max]}})
end

if all_phases || phases_to_run.includes?(6)
  lock_res = phase_lock_cost
  puts %({"phase": 6, "metric": "lock_overhead", "empty_ns": #{lock_res[:empty_ns]}, "lock_ns": #{lock_res[:lock_ns]}})
end
