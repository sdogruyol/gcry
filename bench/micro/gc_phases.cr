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
# --size is in 8-byte words. --fanout uses a fixed target graph plus the
# churn ring (2 * live objects). --trace-only collects that graph without
# allocating in the timed loop; --atomic requires --fanout=0.
# Output: JSON lines to stdout; each survival runs in a fresh process.

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
shuffle = false
fanout = 0
trace_only = false
atomic = false
child = false
# Scatter the ring so consecutive marked objects land in different chunks.
#
# This is not a cosmetic knob. In allocation order the ring's pointers are
# chunk-sequential, so `chunk_containing`'s one-slot cache answers nearly every
# lookup and the binary search it exists to avoid barely runs — a workload that
# looks GC-bound but exercises no chunk *lookup* pressure at all. Real mark
# graphs (Kemal's JSON, `exp.c`'s shuffled shapes) are scattered, and
# `simdgc-perf-notes.md` measured graph shape dominating everything else in the
# mark phase. Without this the benchmark silently answers a different question
# from the one a chunk-lookup change is asking.

ARGV.each do |arg|
  case arg
  when .starts_with?("--seconds=")  then seconds = arg.split("=", 2)[1].to_f
  when .starts_with?("--live=")     then live_slots = arg.split("=", 2)[1].to_i
  when .starts_with?("--size=")     then obj_words = arg.split("=", 2)[1].to_i
  when .starts_with?("--survival=") then survivals = arg.split("=", 2)[1].split(",").map(&.to_f)
  when "--child"                    then child = true
  when "--trace-only"               then trace_only = true
  when "--atomic"                   then atomic = true
  when "--shuffle"                  then shuffle = true
  when .starts_with?("--fanout=")   then fanout = arg.split("=", 2)[1].to_i
  end
end

abort "invalid workload arguments" unless seconds > 0 && live_slots > 0 && obj_words > 0 &&
                                          fanout >= 0 && fanout <= obj_words && survivals.all? { |v| v >= 0 && v <= 1 }
abort "atomic objects cannot carry graph edges" if atomic && fanout > 0
# Exec a new process per survival: no adaptive threshold or heap history leaks
# between rows. --child is internal to this driver.
unless child
  survivals.each do |survival|
    args = ARGV.reject { |arg| arg.starts_with?("--survival=") }
    args << "--survival=#{survival}" << "--child"
    status = Process.run(Process.executable_path.not_nil!, args,
      output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
    exit status.exit_code unless status.success?
  end
  exit
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
  "shuffle"     => shuffle.to_s,
  "fanout"      => fanout.to_s,
  "trace_only"  => trace_only.to_s,
  "atomic"      => atomic.to_s,
  "bitmap"      => heap.bitmap_marks?.to_s,
  "chunk_radix" => heap.chunk_radix?.to_s,
})

survivals.each do |survival|
  ring = Array(Void*).new(live_slots, Pointer(Void).null)
  cursor = 0
  # xorshift rather than `Random`: it must not allocate inside the timed loop.
  rng = 0x9E3779B97F4A7C15_u64
  bytes = (obj_words * 8).to_u64
  threshold = (survival * 4294967296.0).to_u64
  # A fixed target graph bounds reachability. Pointing each new object at
  # arbitrarily old churn survivors would retain an ever-growing history at
  # fanout > 1. Both target and churn layers keep their requested fanout.
  targets = Array(Void*).new(fanout > 0 ? live_slots : 0, Pointer(Void).null)
  targets.size.times { |i| targets[i] = GC.malloc(bytes) }
  frng = 0x2545F4914F6CDD1D_u64

  # Fill the ring first so the measured window is steady state, not warm-up.
  live_slots.times do |i|
    ring[i] = atomic ? GC.malloc_atomic(bytes) : GC.malloc(bytes)
  end
  if fanout > 0
    live_slots.times do |i|
      fanout.times do |k|
        frng ^= frng << 13; frng ^= frng >> 7; frng ^= frng << 17
        target = targets[(frng % live_slots.to_u64).to_i]
        (ring[i].as(Void**) + k).value = target
        (targets[i].as(Void**) + k).value = target
      end
    end
  end

  # Fisher-Yates with the same xorshift, so the scatter is reproducible and the
  # shuffle itself allocates nothing.
  if shuffle
    srng = 0xD1B54A32D192ED03_u64
    i = live_slots - 1
    while i > 0
      srng ^= srng << 13
      srng ^= srng >> 7
      srng ^= srng << 17
      j = (srng % (i + 1).to_u64).to_i
      ring[i], ring[j] = ring[j], ring[i]
      i -= 1
    end
  end
  GC.collect

  before_collections = heap.collections
  before_pause = Gcry.pause_stats.total_ns
  allocs = 0_u64

  t0 = now_ns
  elapsed = 0_u64
  while elapsed < (seconds * 1_000_000_000.0).to_u64
    if trace_only
      GC.collect
    else
      2048.times do
        rng ^= rng << 13
        rng ^= rng >> 7
        rng ^= rng << 17
        ptr = atomic ? GC.malloc_atomic(bytes) : GC.malloc(bytes)
        fanout.times do |k|
          frng ^= frng << 13; frng ^= frng >> 7; frng ^= frng << 17
          (ptr.as(Void**) + k).value = targets[(frng % live_slots.to_u64).to_i]
        end
        # Survivors displace an older slot; the rest are dropped on the floor.
        if (rng >> 32) < threshold
          ring[cursor] = ptr
          cursor += 1
          cursor = 0 if cursor >= live_slots
        end
        allocs &+= 1
      end
    end
    elapsed = now_ns &- t0
  end
  wall = elapsed

  collections = heap.collections - before_collections
  pause_total = Gcry.pause_stats.total_ns - before_pause

  # The headline. Everything a mark-side optimisation can win lives inside this
  # fraction of wall time; nothing outside it is addressable by making the
  # collector faster.
  duty = pause_total.to_f / wall.to_f

  # Outside the timed window, verify that the graph has not thinned. Every
  # declared edge is non-null and every target is still a live allocation.
  edges = 0_u64
  {ring, targets}.each do |layer|
    layer.each do |ptr|
      abort "lost graph object" unless heap.live?(ptr)
      fanout.times do |k|
        target = (ptr.as(Void**) + k).value
        abort "lost graph edge" if target.null? || !heap.live?(target)
        edges += 1
      end
    end
  end

  json_line({
    "graph_objects"  => (ring.size + targets.size).to_s,
    "graph_bytes"    => ((ring.size.to_u64 + targets.size.to_u64) * bytes).to_s,
    "graph_edges"    => edges.to_s,
    "survival"       => survival.to_s,
    "wall_ms"        => (wall / 1_000_000.0).round(1).to_s,
    "allocs"         => allocs.to_s,
    "ns_per_alloc"   => (allocs == 0 ? 0.0 : wall.to_f / allocs.to_f).round(2).to_s,
    "collections"    => collections.to_s,
    "pause_total_ms" => (pause_total / 1_000_000.0).round(2).to_s,
    "gc_duty_cycle"  => (duty * 100).round(3).to_s,
    # Mean pause across every collection in this window. `phase_mark_us` below
    # is `last_phase_mark_ns` — a **single last-collection sample**, so its
    # variance is roughly double this one's and it is the weaker instrument for
    # a mark-side change. Prefer this.
    "pause_per_gc_us" => (collections == 0 ? 0.0 : (pause_total.to_f / collections.to_f / 1000.0)).round(2).to_s,
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
    # Last collection's scan census: how many objects were conservatively /
    # precisely scanned and how many ambient candidates the type_id gate refused.
    "scans_conservative" => heap.layout_conservative_scans.to_s,
    # Occupancy census: allocated blocks by walking the occ bitmaps (plus one per
    # large chunk). Independent of the live_objects counter, which is a running
    # tally and can drift.
    "occ_live" => begin
      n = 0_u64
      heap.each_chunk do |c|
        if Gcry::ChunkHeader.large?(c)
          n += 1
        elsif heap.bitmap_alloc_chunk_public?(c)
          n += heap.chunk_occupied_count(c)
        end
      end
      n.to_s
    end,
    "scans_precise"   => heap.layout_precise_scans.to_s,
    "type_id_rejects" => heap.type_id_root_rejects.to_s,
  })

  # `Gcry.pause_stats` p50/p99 are deliberately NOT reported. They are
  # process-cumulative, so on the second and later survival rates they are
  # contaminated by the earlier ones — a reader comparing them across rows would
  # be comparing overlapping populations. `pause_total_ns` is delta'd above,
  # which is why the derived mean is safe and the percentiles are not.

  # Drop the ring before the next survival rate so heaps do not compound.
  ring.clear
  targets.clear
  GC.collect
end
