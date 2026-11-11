# Does `GCRY_PARALLEL_DORMANT=1` give memory back?
#
# It is the documented RSS opt-in for multi-mutator programs (docs/POLICY.md),
# where empty chunks are otherwise kept mapped. It releases empties *within*
# `empty_chunk_retain`, and from 2026-08-03 the Linux process default for that
# budget was 0, so the opt-in did nothing for two months and nothing noticed:
# Kemal EC4 post-GC RSS 83.4 MB with it against 83.7 without
# (`bench/log/linux/2026-09-26-parallel-dormant-inert/`). This is the gate that
# would have.
#
# Multi-mutator by construction (two plain threads parked on a pipe, past the
# > 2 thread boundary), then a 64 MiB burst of small objects, dropped, and two
# collections. Reports the empty chunks kept, the ones made dormant, and RSS.
#
#   --expect-dormant   the opt-in must have made empties dormant
#   --expect-inert     the red arm: run with GCRY_EMPTY_CHUNK_RETAIN=0, the
#                      pre-fix budget, and nothing may be dormant
#   --ordinary         collect with `Heap#collect` (an ordinary major) rather
#                      than `GC.collect`, which since 2026-09-28 makes the
#                      empties dormant by default (`GCRY_PARALLEL_RELEASE_ON_COLLECT`);
#                      the opt-in arms need it to show the opt-in's own effect
#   --expect-footprint-drop  macOS: the collection must take at least half of
#                      the dormant bytes out of `phys_footprint`
#                      (`MADV_FREE_REUSABLE`)
#   --expect-footprint-kept  macOS red arm, with GCRY_DARWIN_REUSABLE=0: it
#                      must not (`MADV_FREE`, measured 60 → 51 MB with 44 MB
#                      dormant), or the check above cannot tell them apart
#
#   crystal build -Dgc_none bench/parallel_dormant.cr -o bin/parallel_dormant
require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "parallel_dormant requires -Dgc_none (gcry as process GC)" %}
{% end %}

HEAP = Gcry.default_heap.not_nil!

def rss_kib : UInt64
  {% if flag?(:linux) %}
    File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_u64
  {% else %}
    `ps -o rss= -p #{Process.pid}`.strip.to_u64
  {% end %}
end

# macOS: `ps` RSS can keep counting released pages as resident until the
# kernel takes them; the footprint the system charges the task
# (`TASK_VM_INFO.phys_footprint`, byte 144) is what a reusable release lowers. Printed beside
# RSS so the two can be told apart. Through gcry's own `task_info` binding: a
# C function bound twice must be bound identically.
def footprint_kib : UInt64?
  {% if flag?(:darwin) %}
    buf = uninitialized UInt64[128]
    count = 256_u32
    kr = Gcry::Platform::LibMachVM.task_info(Gcry::Platform::LibMachVM.mach_task_self_, 22,
      buf.to_unsafe.as(UInt32*), pointerof(count))
    return nil unless kr == 0 && count * 4 >= 152
    (buf.to_unsafe.as(UInt8*) + 144).as(UInt64*).value // 1024
  {% else %}
    nil
  {% end %}
end

expect_dormant = ARGV.includes?("--expect-dormant")
expect_inert = ARGV.includes?("--expect-inert")
expect_fp_drop = ARGV.includes?("--expect-footprint-drop")
expect_fp_kept = ARGV.includes?("--expect-footprint-kept")
ordinary = ARGV.includes?("--ordinary")

fds = uninitialized Int32[2]
raise "pipe() failed" unless LibC.pipe(fds) == 0
read_fd = fds[0]
2.times do
  Thread.new do
    byte = uninitialized UInt8[1]
    loop do
      break if LibC.read(read_fd, byte.to_unsafe, 1) >= 0
      break unless Errno.value == Errno::EINTR
    end
  end
end
threads = 0
50.times do
  threads = 0
  Thread.unsafe_each { threads += 1 }
  break if threads > 2
  sleep 20.milliseconds
end
abort "only #{threads} threads — not multi-mutator, nothing to measure" if threads <= 2

# A burst of small objects — small-size-class chunks, all empty once dropped —
# built and dropped on a thread of its own, which is joined before anything
# collects. A first version held 60 MB of it through `burst = nil`; the next
# built it in a frame of main's and overwrote that stack region afterwards,
# which held until 2026-09-28, when a change to the marker's code (no change
# to what it marks) left macOS retaining the whole burst on every run: 60 MB
# after the collect, 4 MB of empty chunks. One conservative word naming the
# outer array keeps all of it, and main's frames and registers are where
# such a word lives. The burst thread's are gone once it is joined.
# A plain thread has no execution context, so no IO: the peak is read on main
# after the join, with the burst still resident because nothing has
# collected it.
# Where the burst lived, XOR'd so the record is not itself a root. On a
# retained burst the holders search looks for words naming either the outer
# array or its buffer: CI failed this gate once on Linux (run 36625152299,
# "seeded by … parked 5805 KiB", 1 in ~60 runs, never locally in 30), and a
# seed total says which root kind held it but not which stack or where.
module Burst
  KEY = 0x5A5A_A5A5_5A5A_A5A5_u64
  @@array = 0_u64
  @@buffer = 0_u64
  @@buffer_bytes = 0_u64

  def self.note(keep : Array(Array(Int64))) : Nil
    @@array = keep.object_id ^ KEY
    @@buffer = keep.to_unsafe.address ^ KEY
    @@buffer_bytes = keep.@capacity.to_u64 * sizeof(Array(Int64)).to_u64
  end

  def self.search_holders : Nil
    Gcry::PoisonHolders.search(HEAP, @@array ^ KEY, sizeof(Array(Array(Int64))).to_u64 + 16)
    Gcry::PoisonHolders.search(HEAP, @@buffer ^ KEY, @@buffer_bytes)
  end
end

GROW     = Pointer(UInt64).malloc(64)
GROW_CAP = Pointer(UInt64).malloc(64)
GROW_N   = Pointer(Int32).malloc(1)
@[NoInline]
def burst_and_drop : Int32
  keep = Array(Array(Int64)).new
  last = 0_u64
  (64 * 1024 * 1024 // 96).times do
    keep << Array(Int64).new(4, 0_i64)
    b = keep.to_unsafe.address
    if b != last
      last = b
      if GROW_N[0] < 64
        GROW[GROW_N[0]] = (b ^ Burst::KEY)
        GROW_CAP[GROW_N[0]] = keep.@capacity.to_u64
        GROW_N[0] += 1
      end
    end
  end
  Burst.note(keep)
  keep.size
end

@[NoInline]
def scrub_stack(depth : Int32) : Int32
  pad = uninitialized UInt64[512]
  pad.to_unsafe.clear(512)
  depth > 0 ? scrub_stack(depth - 1) &+ pad[depth & 511].to_i32 : 0
end

Thread.new { st = Fiber.current.@stack; LibC.dprintf(2, "DBG burst thread stack base=%#lx bottom=%#lx\n", st.pointer.address, st.bottom.address); burst_and_drop }.join
peak = rss_kib
peak_fp = footprint_kib
scrub_stack(64)
# Which root seeded what. A word naming the outer array's 5.6 MB buffer shows
# up in its source's bytes; one naming the 24-byte array object barely does.
HEAP.live_attr_roots = true
majors_before = HEAP.major_collections
minors_before = HEAP.minor_collections
# The warm budget, the threshold and the live bytes the sweep measured, before
# and after each collect: the dormant arms fail on macOS when every empty chunk
# goes warm, i.e. when the budget is at least the whole burst.
#
# Collect until the burst is dead, then once more. The warm budget follows the
# live set the *previous* major measured. When a stale word kept the burst
# alive through the first collect (live 42 MB), the budget rose to 48 MB, and
# the collect that finally found the burst dead kept all 47 MB of it warm, by
# design. That was 8 of 300 dormant-arm runs on macos-latest and all four CI
# failures (2026-09-30). The collect after the one that sees it dead decides
# with a budget that no longer counts it, which is what the arms ask about.
# A burst still live after six collects is the retention failure below.
budget = [] of String
budget << "#{HEAP.empty_chunk_warm_retain >> 20}/#{HEAP.gc_threshold >> 20}"
collect_once = -> do
  ordinary ? HEAP.collect : GC.collect
  budget << "#{HEAP.empty_chunk_warm_retain >> 20}/#{HEAP.gc_threshold >> 20} (live #{HEAP.size_class_live_bytes >> 20})"
end
6.times do
  collect_once.call
  break if HEAP.size_class_live_bytes < 16_u64 << 20
end
collect_once.call
after = rss_kib
after_fp = footprint_kib
dormant = HEAP.dormant_chunk_bytes
empty = HEAP.fully_free_chunk_bytes

puts "parallel_dormant: threads=#{threads} retain=#{HEAP.empty_chunk_retain // 1024}KiB #{ordinary ? "ordinary collect" : "GC.collect"}"
puts "  RSS peak #{peak // 1024} MB, after collect #{after // 1024} MB; empty chunks #{empty >> 20} MB, dormant #{dormant >> 20} MB"
if (pf = peak_fp) && (af = after_fp)
  puts "  footprint peak #{pf // 1024} MB, after collect #{af // 1024} MB"
end
puts "  seeded by stack #{HEAP.first_mark_stack_bytes >> 10} KiB, parked #{HEAP.first_mark_parked_bytes >> 10} KiB, " \
     "thread #{HEAP.first_mark_thread_bytes >> 10} KiB, static #{HEAP.first_mark_static_bytes >> 10} KiB"
# What the last sweep did with the empty chunks, and why. The dormant arms
# failed on macOS CI four times with empty chunks and none dormant; this line
# is the branch each one took.
puts "  the collects: #{HEAP.major_collections - majors_before} major, #{HEAP.minor_collections - minors_before} minor; " \
     "last major sweep: #{HEAP.last_sweep_after_world ? "after the world" : "in the stop"}, " \
     "#{HEAP.last_sweep_multi ? "multi" : "single"}-mutator, release #{HEAP.last_sweep_release ? "on" : "off"}; " \
     "empties warm #{HEAP.last_empty_warm_bytes >> 20} MB, grace #{HEAP.last_empty_grace_bytes >> 20} MB, " \
     "dormant #{dormant >> 20} MB, unmapped #{HEAP.last_empty_unmap_bytes >> 20} MB, kept #{HEAP.last_empty_kept_bytes >> 20} MB, " \
     "header-blocked #{HEAP.last_empty_header_blocked_bytes >> 20} MB"
puts "  warm budget / threshold, MB: #{budget.join(" -> ")}"
# The burst is 64 MiB of garbage. With less than a quarter of it in empty
# chunks, something held it, and whether those chunks go dormant is not what
# failed.
#
# That run is inconclusive, so the gate runs itself again, up to
# RETENTION_ATTEMPTS times, before calling it a failure. The holder was a
# stale word, not a reference. It held the 5.9 MB outer buffer
# at an odd offset (`block+1698845` locally, `+3418133` in CI run
# 36799165922), seeded as "parked". The rate was 1 in 100 for the inert arm
# locally and 3 jobs in ~120 on Linux CI (2026-10-01). At that rate, three
# retentions in a row is about 1 in 10^5–10^6.
RETENTION_ATTEMPTS = 3
Thread.unsafe_each { |t| if (n = t.name) == "gc-idle"
  st = t.@main_fiber.not_nil!.@stack; STDERR.puts "DBG gc-idle stack base=0x#{st.pointer.address.to_s(16)} bottom=0x#{st.bottom.address.to_s(16)}"
end }
GROW_N[0].times { |i| STDERR.puts "DBG grow #{i} buffer=0x#{(GROW[i] ^ Burst::KEY).to_s(16)} bytes=#{GROW_CAP[i] * 8}" if GROW_CAP[i] > 100_000 }
if empty < 16_u64 << 20
  attempt = ENV["PARALLEL_DORMANT_ATTEMPT"]?.try(&.to_i?) || 1
  puts "#{attempt < RETENTION_ATTEMPTS ? "INCONCLUSIVE" : "FAIL"}: the burst was retained: #{after // 1024} MB resident after the collect and only #{empty >> 20} MB of empty chunks. " \
       "A root held the dropped objects (see the seeds above); this says nothing about the release"
  Burst.search_holders
  if attempt < RETENTION_ATTEMPTS
    puts "  running again (attempt #{attempt + 1} of #{RETENTION_ATTEMPTS})"
    STDOUT.flush
    Process.exec(Process.executable_path.not_nil!, ARGV, env: {"PARALLEL_DORMANT_ATTEMPT" => (attempt + 1).to_s})
  end
  exit 1
end
if expect_dormant && dormant == 0
  puts "FAIL: no empty chunk went dormant (#{empty >> 20} MB of them kept mapped) — #{ordinary ? "the opt-in is inert" : "GC.collect gave nothing back"}"
  exit 1
end
if expect_inert && dormant != 0
  puts "FAIL: red arm: #{dormant >> 20} MB still went dormant, so this gate cannot tell the release working from not"
  exit 1
end
if expect_fp_drop || expect_fp_kept
  pf = peak_fp
  af = after_fp
  abort "FAIL: no phys_footprint on this platform, so the footprint arms cannot run" unless pf && af
  abort "FAIL: nothing went dormant, so the footprint arms measure nothing" if dormant == 0
  dropped = pf > af ? pf - af : 0_u64
  half = (dormant // 1024) // 2
  if expect_fp_drop && dropped < half
    puts "FAIL: #{dormant >> 20} MB went dormant but the footprint fell only #{dropped // 1024} MB — the release is not leaving phys_footprint (MADV_FREE, not MADV_FREE_REUSABLE?)"
    exit 1
  end
  if expect_fp_kept && dropped >= half
    puts "FAIL: red arm: with MADV_FREE the footprint still fell #{dropped // 1024} MB of #{dormant >> 20} MB dormant, so this gate cannot tell the two releases apart"
    exit 1
  end
end
puts "  PASS" if expect_dormant || expect_inert || expect_fp_drop || expect_fp_kept
