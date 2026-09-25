# Does scanning a parked fiber's untouched lag window cost resident memory?
#
# The Darwin EC4 cut (bench/log/macos/2026-09-25-205449-root-phase/) found the
# low-water skip saves RSS as well as pause there — 126.5 → 92.9 MB, ~23 MB of
# it outside the heap — while the same A/B on Linux was flat. The explanation
# on offer: reading a never-written anonymous page maps Linux's shared zero page
# (no RSS), but on macOS it makes the page resident. The skip stops the
# collector reading those pages, so only Darwin saves memory by it.
#
# This measures that directly instead of inferring it from a server's RSS:
# park N fibers that dirty a little of their stack, read RSS, collect a few
# times, read RSS again. With the skip the collector never reads below the
# written part; with `GCRY_STACK_LOW_WATER=0` it reads the whole lag window
# (256 KiB) of every parked fiber.
#
#   crystal build -Dgc_none bench/lag_scan_rss.cr -o bin/lag_scan_rss
#   bin/lag_scan_rss                           # skip on
#   GCRY_STACK_LOW_WATER=0 bin/lag_scan_rss    # skip off
#
# Measured 2026-09-25 (run 36189547539, 256 fibers, 16 KiB dirty, 256 KiB lag):
#
#                  skip on          skip off
#   Linux          0.9–1.4 KiB      0.9–1.2 KiB   per parked fiber
#   Darwin M1      4.5 KiB          245.9 KiB
#
# Linux maps the shared zero page on a read of an untouched page; Darwin makes
# it resident, so without the skip every collection leaves the whole unwritten
# lag window of every parked fiber in RSS. The bounds make that a gate:
#
#   --max-per-fiber=K   fail if growth per fiber exceeds K KiB (the skip arm)
#   --min-per-fiber=K   fail if it is below K (the red arm under
#                       GCRY_STACK_LOW_WATER=0: proves the probe can see the
#                       fault-in at all — without it a ceiling passing says
#                       nothing). Meaningful on Darwin only; Linux never
#                       faults these pages in.
require "../src/gcry"

{% unless flag?(:gc_none) %}
  raise "lag_scan_rss requires -Dgc_none (gcry as process GC)"
{% end %}

{% if flag?(:darwin) %}
  lib LibLagRss
    struct MachTaskBasicInfo
      virtual_size : UInt64
      resident_size : UInt64
      resident_size_max : UInt64
      user_time : Int32[2]
      system_time : Int32[2]
      policy : Int32
      suspend_count : Int32
    end

    $mach_task_self_ : UInt32
    fun task_info(task : UInt32, flavor : Int32, info : MachTaskBasicInfo*, count : UInt32*) : Int32
  end

  MACH_TASK_BASIC_INFO = 20
{% end %}

HEAP = Gcry.default_heap.not_nil!

def rss_kib : UInt64
  {% if flag?(:darwin) %}
    info = LibLagRss::MachTaskBasicInfo.new
    count = (sizeof(LibLagRss::MachTaskBasicInfo) // 4).to_u32
    kr = LibLagRss.task_info(LibLagRss.mach_task_self_, MACH_TASK_BASIC_INFO, pointerof(info), pointerof(count))
    raise "task_info: #{kr}" unless kr == 0
    info.resident_size // 1024
  {% else %}
    resident_pages = File.read("/proc/self/statm").split[1].to_u64
    resident_pages * LibC.sysconf(LibC::SC_PAGESIZE).to_u64 // 1024
  {% end %}
end

fibers = 256
dirty_kb = 16
collections = 4
max_per_fiber = nil.as(Float64?)
min_per_fiber = nil.as(Float64?)
ARGV.each do |arg|
  case arg
  when /--fibers=(\d+)/           then fibers = $1.to_i
  when /--dirty-kb=(\d+)/         then dirty_kb = $1.to_i
  when /--collections=(\d+)/      then collections = $1.to_i
  when /--max-per-fiber=([\d.]+)/ then max_per_fiber = $1.to_f
  when /--min-per-fiber=([\d.]+)/ then min_per_fiber = $1.to_f
  end
end

@[NoInline]
def dirty_stack(remaining_kb : Int32) : Int32
  buf = uninitialized UInt8[4096]
  buf[0] = (remaining_kb & 0xff).to_u8
  buf[2048] = (remaining_kb & 0x7f).to_u8
  return buf[0].to_i if remaining_kb <= 4
  buf[0].to_i &+ dirty_stack(remaining_kb - 4)
end

# More than two threads, or the lag path does not run and there is nothing to
# measure: parked on a pipe read, retried on the STW signal's EINTR.
pipe_fds = uninitialized Int32[2]
raise "pipe() failed" unless LibC.pipe(pipe_fds) == 0
3.times do
  Thread.new do
    buf = uninitialized UInt8[1]
    loop do
      n = LibC.read(pipe_fds[0], buf.to_unsafe, 1_u64)
      break if n >= 0
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
abort "only #{threads} threads — the lag path is inert, nothing to measure" if threads <= 2

ready = Channel(Nil).new(fibers)
park = Channel(Nil).new
fibers.times do
  spawn do
    dirty_stack(dirty_kb)
    ready.send(nil)
    park.receive
  end
end
fibers.times { ready.receive }

# The baseline has to come before the first collection that scans these
# fibers: that is the one that would fault the lag window in, and every later
# one reads pages already resident. Collections before this point (allocation
# pressure while spawning) would have done it already, so they are reported.
early = HEAP.collections
before = rss_kib
collections.times { GC.collect }
after = rss_kib
# Per collection, reset by each one: this is the last collection's count.
skips = HEAP.low_water_skips

growth = after.to_i64 - before.to_i64
skip_on = HEAP.stack_low_water_scan
puts "lag_scan_rss: #{{% if flag?(:darwin) %}"darwin"{% else %}"linux"{% end %}} skip=#{skip_on ? "on" : "off"} " \
     "fibers=#{fibers} dirty=#{dirty_kb}KiB threads=#{threads} lag=#{HEAP.stw_multi_stack_lag // 1024}KiB"
puts "  rss before #{before} KiB, after #{collections} collections #{after} KiB: " \
     "growth #{growth} KiB = #{(growth / fibers).round(1)} KiB per parked fiber"
puts "  low_water_skips in the last collection: #{skips}; collections before the baseline: #{early}"
park.close

per_fiber = growth / fibers
if (cap = max_per_fiber) && per_fiber > cap
  puts "FAIL: #{per_fiber.round(1)} KiB per parked fiber > #{cap} — the collection made untouched stack pages resident"
  exit 1
end
if (floor = min_per_fiber) && per_fiber < floor
  puts "FAIL: #{per_fiber.round(1)} KiB per parked fiber < #{floor} — the full-window scan no longer faults pages in, so the ceiling on the other arm proves nothing"
  exit 1
end
puts "  PASS" if max_per_fiber || min_per_fiber
