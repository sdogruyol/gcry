# Steady-state GC workload with a tunable survival rate, reporting per-phase
# timings and — the reason this exists — the **GC duty cycle**.
#
# ## Why
#
# `2026-09-03-simdgc-chunk-radix-ab` measured `phase_mark` down 10-18% from the
# O(1) chunk table and could not see it in Kemal throughput at all. The reason
# was not noise. Kemal spends **0.2-0.5% of wall time stopped for GC**, and
# `phase_mark` is 29% of that, so an *infinitely fast* mark is worth +0.15pp
# end to end. Every mark-side phase in the plan was being gated on an axis it
# cannot move by more than a rounding error.
#
# A benchmark cannot fix that, but it can stop the project guessing. This one
# reports duty cycle as a first-class number so a workload can be **chosen by
# measurement** rather than assumed to be GC-bound — and it sweeps survival rate,
# which is the parameter that actually controls it: garbage is cheap (a dead
# object costs a bit in a bitmap), survivors are expensive (each one is a mark,
# a trace, and a retained page).
#
# The plan (`simd_plan/gcry-simdgc-plan.md` §6) asked for this as a port of
# `bench4.c`. It should have been built before the phases it exists to judge.
#
# ## Shape
#
# A ring of `live` slots is overwritten in place, so the live set is bounded and
# steady while allocation continues indefinitely — the same steady state
# `bench4.c` uses. Survival rate is the fraction of allocations that land in the
# ring rather than being dropped immediately.
#
# Usage:
#   crystal build --release -Dgc_none bench/micro/gc_phases.cr -o bin/gc_phases
#   ./bin/gc_phases [--seconds=N] [--live=N] [--survival=0.1,0.5,0.9] [--size=N]
#
# Output: JSON lines to stdout.

require "../../src/gcry"

def now_ns : UInt64
  ts = uninitialized LibC::Timespec
  LibC.clock_gettime(LibC::CLOCK_MONOTONIC, pointerof(ts))
  ts.tv_sec.to_u64 &* 1_000_000_000_u64 &+ ts.tv_nsec.to_u64
end

def json_line(fields : Hash(String, String)) : Nil
  puts "{#{fields.map { |k, v| "\"#{k}\":#{v}" }.join(",")}}"
end

def rss_kb : Int64
  File.each_line("/proc/self/status") do |line|
    return line.split[1].to_i64 if line.starts_with?("VmRSS:")
  end
  0_i64
rescue
  0_i64
end

seconds = 3.0
live_slots = 200_000
obj_words = 8
survivals = [0.05, 0.25, 0.75]

ARGV.each do |arg|
  case arg
  when .starts_with?("--seconds=")  then seconds = arg.split("=", 2)[1].to_f
  when .starts_with?("--live=")     then live_slots = arg.split("=", 2)[1].to_i
  when .starts_with?("--size=")     then obj_words = arg.split("=", 2)[1].to_i
  when .starts_with?("--survival=") then survivals = arg.split("=", 2)[1].split(",").map(&.to_f)
  end
end

heap = Gcry.default_heap
unless heap
  STDERR.puts "no default heap — build with -Dgc_none"
  exit 2
end

json_line({
  "bench"       => "\"gc_phases\"",
  "live_slots"  => live_slots.to_s,
  "obj_words"   => obj_words.to_s,
  "seconds"     => seconds.to_s,
  "bitmap"      => heap.bitmap_marks?.to_s,
  "chunk_radix" => heap.chunk_radix?.to_s,
})

survivals.each do |survival|
  ring = Array(Void*).new(live_slots, Pointer(Void).null)
  cursor = 0
  # xorshift rather than `Random`: it must not allocate inside the timed loop.
  rng = 0x9E3779B97F4A7C15_u64
  bytes = (obj_words * 8).to_u64
  threshold = (survival * UInt32::MAX.to_f).to_u64

  # Fill the ring first so the measured window is steady state, not warm-up.
  live_slots.times do |i|
    ring[i] = GC.malloc(bytes)
  end
  GC.collect

  before_collections = heap.collections
  before_pause = Gcry.pause_stats.total_ns
  allocs = 0_u64

  t0 = now_ns
  elapsed = 0_u64
  while elapsed < (seconds * 1_000_000_000.0).to_u64
    2048.times do
      rng ^= rng << 13
      rng ^= rng >> 7
      rng ^= rng << 17
      ptr = GC.malloc(bytes)
      # Survivors displace an older slot; the rest are dropped on the floor.
      if (rng >> 32) < threshold
        ring[cursor] = ptr
        cursor += 1
        cursor = 0 if cursor >= live_slots
      end
      allocs &+= 1
    end
    elapsed = now_ns &- t0
  end
  wall = elapsed

  collections = heap.collections - before_collections
  pause_total = Gcry.pause_stats.total_ns - before_pause
  stats = Gcry.pause_stats

  # The headline. Everything a mark-side optimisation can win lives inside this
  # fraction of wall time; nothing outside it is addressable by making the
  # collector faster.
  duty = pause_total.to_f / wall.to_f

  json_line({
    "survival"        => survival.to_s,
    "wall_ms"         => (wall / 1_000_000.0).round(1).to_s,
    "allocs"          => allocs.to_s,
    "ns_per_alloc"    => (wall.to_f / allocs.to_f).round(2).to_s,
    "collections"     => collections.to_s,
    "pause_total_ms"  => (pause_total / 1_000_000.0).round(2).to_s,
    "gc_duty_cycle"   => (duty * 100).round(3).to_s,
    "pause_p50_us"    => (stats.p50_ns / 1000.0).round(1).to_s,
    "pause_p99_us"    => (stats.p99_ns / 1000.0).round(1).to_s,
    "phase_mark_us"   => (heap.last_phase_mark_ns / 1000.0).round(1).to_s,
    "phase_sweep_us"  => (heap.last_phase_sweep_ns / 1000.0).round(1).to_s,
    "phase_roots_us"  => (heap.last_phase_roots_ns / 1000.0).round(1).to_s,
    "phase_stacks_us" => (heap.last_phase_stacks_ns / 1000.0).round(1).to_s,
    "phase_clear_us"  => (heap.last_phase_clear_ns / 1000.0).round(1).to_s,
    "live_objects"    => heap.live_objects.to_s,
    "heap_mib"        => (heap.heap_size / 1048576.0).round(1).to_s,
    "rss_kb"          => rss_kb.to_s,
    "radix_fast"      => heap.radix_fast_hits.to_s,
    "radix_slow"      => heap.radix_slow_lookups.to_s,
  })

  # Drop the ring before the next survival rate so heaps do not compound.
  ring.clear
  GC.collect
end
