# Process-GC STW + concurrent mutation property test.
#
# Closes the gap left by `bench/mt_property_test.cr` (library heap,
# `stop_the_world=false`). Runs under `-Dgc_none` with
# `Fiber::ExecutionContext::Parallel` allocator threads while the default
# context owns root registration + GC.collect.
#
# Why this shape: `Heap#add_root` / the root linked list is not safe to mutate
# from Parallel workers concurrent with STW (list walk during mark). Workers
# only allocate and hand pointers to the main fiber via a Channel; main pins,
# ACKs (so the worker keeps `ptr` on-stack until rooted), collects, and verifies.
# That still STW-suspends mutators mid-`malloc`.
#
# TLAB defaults OFF for the CI STW gate; pass `--tlab` to also stress
# thread-local freelists (fixed under process STW — see CHANGELOG).
# Pass `--nursery` to enable young-gen + mix minor/major collects (Parallel
# worker STW scan: hardware SP + greg; TLAB forces full fiber-stack scan).
#
# Until 2026-09-20 CI built the TLAB/nursery arms headerless.
# `nursery_enabled=` is a no-op there, `tlab_enabled=` is refused (the
# bitmap allocator is forced, and TLAB is freelist-shaped), and
# `minor_collect` returns immediately — the same no-op `make
# nursery-tlab-smoke` used to certify. Green `--tlab` / `--nursery`
# requires `-Dgcry_block_headers` and `GCRY_BITMAP_ALLOC=0` at start.
# `--disabled` is the headerless binary: those flags must not enable.
#
#   crystal build -Dgc_none bench/stw_mt_property_test.cr -o bin/stw_mt_property_test
#   ./bin/stw_mt_property_test [--seed=1] [--iterations=200] [--workers=2]
#   ./bin/stw_mt_property_test --tlab --nursery --disabled
#   crystal build -Dgc_none -Dgcry_block_headers bench/stw_mt_property_test.cr -o bin/stw_mt_property_test_hdr
#   GCRY_BITMAP_ALLOC=0 ./bin/stw_mt_property_test_hdr --tlab [--nursery] ...
#
# Dropping `-Dgcry_block_headers` or `GCRY_BITMAP_ALLOC=0` on a green
# TLAB/nursery arm: exit 64. Dropping `--disabled` from the recipe
# leaves the headerless no-op untested. On failure the seed is printed
# for deterministic local replay.
# CI gates `--workers=2,4`, `--tlab --workers=2,4`, and `--tlab --nursery --workers=2,4`.

require "../src/gcry"
require "wait_group"

{% unless flag?(:gc_none) %}
  raise "stw_mt_property_test requires -Dgc_none (process GC with STW)"
{% end %}

# Let `bench/stall_capture.sh` attach if this run stalls. Under
# `kernel.yama.ptrace_scope=1` (Ubuntu's default) only a declared tracer may,
# and the capture is a sibling rather than a parent. A 900 s stall of this
# harness (2026-09-25) left nothing to read because nothing could attach.
{% if flag?(:linux) %}
  lib LibPtracer
    fun prctl(option : Int32, arg2 : UInt64, arg3 : UInt64, arg4 : UInt64, arg5 : UInt64) : Int32
  end

  LibPtracer.prctl(0x59616d61, UInt64::MAX, 0, 0, 0) # PR_SET_PTRACER, PR_SET_PTRACER_ANY
{% end %}

seed = 1_i64
iterations = 200
worker_counts = [2]
enable_tlab = false
enable_nursery = false
disabled = false

ARGV.each do |arg|
  case arg
  when /--seed=(\d+)/
    seed = $1.to_i64
  when /--iterations=(\d+)/
    iterations = $1.to_i
  when /--workers=(.+)/
    worker_counts = $1.split(',').map(&.to_i)
  when "--tlab"
    enable_tlab = true
  when "--no-tlab"
    enable_tlab = false
  when "--nursery"
    enable_nursery = true
  when "--no-nursery"
    enable_nursery = false
  when "--disabled"
    disabled = true
  end
end

MAGIC     = 0xC0FF_EE42_C0FF_EE01_u64
OBJ_BYTES =                        64

class StwMtPropertyTest
  @errors : Array(String)
  @errors_mutex : Mutex
  @roots : Array(Void*)
  @running : Atomic(Bool)
  @allocs : Atomic(UInt64)
  @collects : Atomic(UInt64)
  @serial : Atomic(UInt64)
  @pinned : Atomic(UInt64)

  def initialize
    @errors = [] of String
    @errors_mutex = Mutex.new(:reentrant)
    @roots = [] of Void*
    @running = Atomic(Bool).new(true)
    @allocs = Atomic(UInt64).new(0_u64)
    @collects = Atomic(UInt64).new(0_u64)
    @serial = Atomic(UInt64).new(1_u64)
    @pinned = Atomic(UInt64).new(0_u64)
  end

  def record_error(msg : String)
    @errors_mutex.synchronize { @errors << msg }
  end

  def error_count : Int32
    @errors_mutex.synchronize { @errors.size }
  end

  def report_errors
    @errors_mutex.synchronize do
      @errors.first(40).each { |e| STDERR.puts "  ERROR: #{e}" }
      STDERR.puts "  ... #{@errors.size - 40} more" if @errors.size > 40
    end
  end

  def write_cookie(ptr : Void*, serial : UInt64)
    words = ptr.as(UInt64*)
    words[0] = MAGIC
    words[1] = serial
  end

  # Main fiber only — never call from Parallel workers / during collect.
  def pin(ptr : Void*)
    @roots << ptr
    Gcry.default_heap.add_root(ptr)
    @pinned.add(1)
    while @roots.size > 16
      old = @roots.shift
      Gcry.default_heap.delete_root(old)
    end
  end

  def clear_roots
    @roots.each { |ptr| Gcry.default_heap.delete_root(ptr) }
    @roots.clear
  end

  def verify(label : String) : Bool
    ok = true
    @roots.each_with_index do |ptr, i|
      next if ptr.null?
      unless GC.is_heap_ptr(ptr) && Gcry.default_heap.live?(ptr)
        # Which of the two it was, and what the block says: a chunk gone from
        # the index and a block reclaimed inside a listed chunk are different
        # defects, and one sighting (2026-09-25, `--tlab`, 1 run in ~300)
        # arrived as 13 addresses and nothing else.
        record_error("#{label}: root #{i} DEAD (#{ptr}) heap_ptr=#{GC.is_heap_ptr(ptr)} " \
                     "block=#{Gcry.default_heap.debug_block_info(ptr)}")
        ok = false
        next
      end
      unless ptr.as(UInt64*).value == MAGIC
        record_error("#{label}: root #{i} cookie broken")
        ok = false
      end
    end
    ok
  end

  # Allocator only — keeps `ptr` live on-stack until ACK (after add_root).
  def worker_run(worker_id : Int32, rng_seed : Int64, out_ch : Channel(Void*), ack_ch : Channel(Nil))
    rng = Random.new(rng_seed + worker_id)
    while @running.get
      ptr = Pointer(Void).null
      # Retry OOM instead of dying — a dead worker leaves main blocked on receive.
      64.times do
        begin
          ptr = GC.malloc_atomic(OBJ_BYTES)
          break
        rescue Gcry::OutOfMemoryError
          Fiber.yield
        end
      end
      break if ptr.null? || !@running.get
      serial = @serial.add(1)
      write_cookie(ptr, serial)
      @allocs.add(1)
      begin
        out_ch.send(ptr)
        # `ptr` must remain a live local until ACK: otherwise the object can be
        # swept between send-complete and add_root under process STW.
        ack_ch.receive
      rescue Channel::ClosedError
        break
      end
      Fiber.yield if rng.rand(0..15) == 0
    end
  rescue Channel::ClosedError
    # shutdown
  rescue ex
    @running.set(false)
    record_error("worker #{worker_id}: #{ex.class}: #{ex.message || ex.inspect}")
  end

  def pin_receive(out_ch : Channel(Void*), ack_ch : Channel(Nil)) : Bool
    ptr = out_ch.receive
    pin(ptr)
    ack_ch.send(nil)
    true
  rescue Channel::ClosedError
    false
  end

  def run_one(worker_count : Int32, iters : Int32, run_seed : Int64) : Bool
    puts "  STW-MT workers=#{worker_count} iterations=#{iters} seed=#{run_seed}"

    unless Gcry.default_heap.stop_the_world
      record_error("expected process GC stop_the_world=true")
      return false
    end

    clear_roots
    @running.set(true)
    @allocs.set(0_u64)
    @collects.set(0_u64)
    @pinned.set(0_u64)

    # Unbuffered handoff: send completes when main receives.
    out_ch = Channel(Void*).new
    ack_ch = Channel(Nil).new
    workers = Fiber::ExecutionContext::Parallel.new("stw-mt-#{worker_count}", worker_count)
    wg = WaitGroup.new(worker_count)

    worker_count.times do |i|
      wid = i
      rs = run_seed
      workers.spawn do
        begin
          worker_run(wid, rs, out_ch, ack_ch)
        ensure
          wg.done
        end
      end
    end

    # Warm: pin before first collect (blocking receive — avoid select/timeout cast)
    warm_n = worker_count * 4
    warm_n.times do
      unless pin_receive(out_ch, ack_ch)
        record_error("channel closed during warm-up")
        @running.set(false)
        out_ch.close
        ack_ch.close
        wg.wait
        return false
      end
    end

    if @allocs.get == 0 || @roots.empty?
      record_error("no allocations/roots before collects (allocs=#{@allocs.get} roots=#{@roots.size})")
      @running.set(false)
      out_ch.close
      ack_ch.close
      wg.wait
      return false
    end

    iters.times do |i|
      # Pin a burst; workers blocked on ACK keep ptr on stack through subsequent STW.
      # Other workers may be mid-malloc / mid-send when collect runs.
      8.times do
        unless pin_receive(out_ch, ack_ch)
          record_error("channel closed during drain before collect ##{i + 1}")
          @running.set(false)
          out_ch.close
          ack_ch.close
          wg.wait
          return false
        end
      end

      # Mix minors with majors when nursery is on (Parallel worker STW stack scan).
      if Gcry.default_heap.nursery_enabled && (i % 3 != 0)
        Gcry.default_heap.minor_collect
      else
        GC.collect
      end
      @collects.add(1)
      unless verify("after collect ##{i + 1}")
        @running.set(false)
        out_ch.close
        ack_ch.close
        wg.wait
        return false
      end
    end

    @running.set(false)
    out_ch.close
    ack_ch.close
    wg.wait

    GC.collect
    @collects.add(1)
    ok = verify("final collect")

    puts "    allocs=#{@allocs.get} pinned=#{@pinned.get} collects=#{@collects.get} roots=#{@roots.size} ok=#{ok}"
    clear_roots
    ok
  end
end

puts "Process-GC STW + concurrent mutation property test"
puts "  seed=#{seed} iterations=#{iterations} workers=#{worker_counts}"
puts "  stop_the_world=#{Gcry.default_heap.stop_the_world}"
puts "  bitmap_alloc=#{Gcry.default_heap.bitmap_alloc?} headers=#{{{ flag?(:gcry_block_headers) }}}"
puts disabled ? "  mode: disabled (headerless / bitmap no-op must hold)" : "  mode: shipped"

if disabled && !enable_tlab && !enable_nursery
  STDERR.puts "--disabled needs --tlab and/or --nursery: without a flag the headerless default no-ops, this arm would have nothing to refuse."
  exit 64
end

Gcry.default_heap.tlab_enabled = enable_tlab
if enable_nursery
  Gcry.default_heap.nursery_enabled = true
  Gcry.default_heap.nursery_threshold = UInt64::MAX
end
tlab_on = Gcry.default_heap.tlab_enabled?
nursery_on = Gcry.default_heap.nursery_enabled
puts "  tlab_enabled=#{tlab_on} (requested=#{enable_tlab})"
puts "  nursery_enabled=#{nursery_on} (requested=#{enable_nursery})"
puts ""

if disabled
  failures = 0
  if enable_tlab && tlab_on
    STDERR.puts "FAIL: --disabled still enabled TLAB — this arm is the headerless/bitmap no-op"
    failures += 1
  end
  if enable_nursery && nursery_on
    STDERR.puts "FAIL: --disabled still enabled nursery — this arm is the headerless no-op"
    failures += 1
  end
  if failures > 0
    exit 1
  end
  puts "ok — requested flags did not enable (headerless compile default and/or bitmap allocator)"
  exit 0
end

if enable_tlab && !tlab_on
  STDERR.puts "--tlab did not enable. Need -Dgcry_block_headers and GCRY_BITMAP_ALLOC=0 (TLAB is refused under the bitmap allocator, which the headerless default forces)."
  exit 64
end
if enable_nursery && !nursery_on
  STDERR.puts "--nursery did not enable. Need -Dgcry_block_headers (headerless nursery_enabled= is a no-op)."
  exit 64
end

if !Gcry.default_heap.stop_the_world
  STDERR.puts "FAIL: process heap stop_the_world is false"
  exit 1
end

test = StwMtPropertyTest.new
all_ok = true

worker_counts.each_with_index do |wc, idx|
  ok = test.run_one(wc, iterations, seed + idx * 10_000)
  all_ok &&= ok
  puts ""
  break if test.error_count > 0
end

puts "=== Summary ==="
if enable_tlab && Gcry.default_heap.tlab_hits == 0 && Gcry.default_heap.tlab_refills == 0
  STDERR.puts "FAIL: --tlab set but TLAB allocated nothing (hits=0 refills=0)"
  exit 1
end
if all_ok && test.error_count == 0
  puts "RESULT: PASS tlab_hits=#{Gcry.default_heap.tlab_hits} tlab_refills=#{Gcry.default_heap.tlab_refills}"
  exit 0
else
  puts "RESULT: FAIL — seed=#{seed} (re-run with --seed=#{seed})"
  test.report_errors
  exit 1
end
