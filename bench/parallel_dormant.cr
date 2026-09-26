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

# macOS: dormancy is `MADV_FREE_REUSABLE`, and `ps` keeps counting such pages
# as resident until the kernel takes them; the footprint the system charges
# the task (`TASK_VM_INFO.phys_footprint`, byte 144) does not. Printed beside
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
# built and dropped inside a frame of its own, then that stack region is
# overwritten, so no conservative word keeps it alive (a first version held
# 60 MB of it through `burst = nil`).
@[NoInline]
def burst_and_drop : UInt64
  keep = Array(Array(Int64)).new
  (64 * 1024 * 1024 // 96).times { keep << Array(Int64).new(4, 0_i64) }
  rss_kib
end

@[NoInline]
def scrub_stack(depth : Int32) : Int32
  pad = uninitialized UInt64[512]
  pad.to_unsafe.clear(512)
  depth > 0 ? scrub_stack(depth - 1) &+ pad[depth & 511].to_i32 : 0
end

peak = burst_and_drop
peak_fp = footprint_kib
scrub_stack(64)
GC.collect
GC.collect
after = rss_kib
after_fp = footprint_kib
dormant = HEAP.dormant_chunk_bytes
empty = HEAP.fully_free_chunk_bytes

puts "parallel_dormant: threads=#{threads} retain=#{HEAP.empty_chunk_retain // 1024}KiB"
puts "  RSS peak #{peak // 1024} MB, after collect #{after // 1024} MB; empty chunks #{empty >> 20} MB, dormant #{dormant >> 20} MB"
if (pf = peak_fp) && (af = after_fp)
  puts "  footprint peak #{pf // 1024} MB, after collect #{af // 1024} MB"
end
if expect_dormant && dormant == 0
  puts "FAIL: GCRY_PARALLEL_DORMANT=1 made no empty chunk dormant (#{empty >> 20} MB of them kept mapped) — the opt-in is inert"
  exit 1
end
if expect_inert && dormant != 0
  puts "FAIL: red arm: with a zero budget #{dormant >> 20} MB still went dormant, so this gate cannot tell the opt-in working from not"
  exit 1
end
puts "  PASS" if expect_dormant || expect_inert
