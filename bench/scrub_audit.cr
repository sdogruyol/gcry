# Does the parked-fiber scrub ever wipe memory a thread is still using?
#
# `scrub_parked_fiber_stacks` zeroes `[stack_top - wipe, stack_top)` of every
# fiber that is not `running?`. Under Parallel it first skips any fiber that a
# suspended OS thread's SP still sits on — the mid-swap window, where
# `current_fiber` has already advanced but the frames have not been left. At
# EC1 that skip is deliberately not applied, and the comment justifying it is a
# throughput argument:
#
#     EC1: SYSMON is suspended on its fiber during our STW — foreign-SP skip
#     would never scrub it. Only skip under Parallel.
#
# So at EC1 the collector knowingly scrubs a stack a thread is parked on, on the
# theory that the wipe window sits below that thread's live frames. This checks
# the theory. `GCRY_SCRUB_AUDIT=1` records, per collection:
#
#   fiber_scrub_foreign_sp_scrubs    fibers scrubbed with a foreign SP on them
#   fiber_scrub_live_frame_overlaps  ...where the wipe reached at or above it
#
# The first is expected to be non-zero at EC1 — that is the exemption doing what
# it says. **The second is the one that matters**: live frames occupy
# `[sp, bottom)`, so a wipe of `[low, top)` is only harmless while `top <= sp`.
# Non-zero means the collector zeroed live frames, and a pointer living only
# there is dropped — the root-completeness charge against `scrub_fibers`, moved
# out of argument and into a number.
#
# EC1 is the shape under test, so this needs -Dexecution_context (SYSMON is the
# second thread; a plain build has no foreign thread and measures nothing).
#
# Build: crystal build -Dgc_none -Dpreview_mt -Dexecution_context \
#          bench/scrub_audit.cr -o bin/scrub_audit
# Run:   GCRY_SCRUB_AUDIT=1 ./bin/scrub_audit [--fibers=64] [--collects=200]
#                                             [--parallelism=1]

require "../src/gcry"

{% unless flag?(:gc_none) %}
  raise "scrub_audit requires -Dgc_none (gcry as process GC)"
{% end %}

HEAP = Gcry.default_heap.not_nil!

fibers = 64
collects = 200
parallelism = 1
depth_kb = 64
no_skip = false

ARGV.each do |arg|
  case arg
  when /--fibers=(\d+)/      then fibers = $1.to_i
  when /--collects=(\d+)/    then collects = $1.to_i
  when /--parallelism=(\d+)/ then parallelism = $1.to_i
  when /--depth-kb=(\d+)/    then depth_kb = $1.to_i
  when "--no-skip"           then no_skip = true
  end
end

{% if flag?(:execution_context) %}
  Fiber::ExecutionContext.default.resize(parallelism) if parallelism >= 1
{% end %}

# The audit is a property of this run, not of the environment — set it directly
# so a forgotten GCRY_SCRUB_AUDIT=1 cannot turn the check into a silent pass.
HEAP.scrub_fibers_enabled = true
HEAP.scrub_audit_foreign_sp = true
# Positive control: with the mid-swap guard off, the counters are *expected* to
# move under Parallel. A zero from the guarded run only means something if the
# unguarded run on the same build shows the probe can see the window at all.
HEAP.scrub_skip_foreign_sp = false if no_skip

# Fibers must park at *varying* depths. A fiber that always parks at the same
# stack_top gives the wipe window one fixed position, and whether it overlaps
# then depends on one arbitrary layout rather than on the mechanism.
@[NoInline]
def churn(depth : Int32) : Int32
  buf = uninitialized UInt8[1024]
  buf[0] = (depth & 0xff).to_u8
  buf[512] = 1_u8
  return buf[0].to_i if depth <= 1
  s = 0
  8.times { s &+= ("d" * (depth % 23 + 1)).bytesize }
  buf[0].to_i &+ s &+ churn(depth - 1)
end

running = true
fibers.times do |i|
  spawn do
    d = (i % (depth_kb // 2)) + 1
    n = 0_u64
    while running
      # The window is "swapped out far enough that running? is false, but the
      # thread has not left the frames yet", so it is a fraction of the time
      # spent inside swapcontext. Yield as tightly as possible to make that
      # fraction as large as this workload can; sleep only rarely, to keep the
      # collecting fiber schedulable.
      churn(d)
      Fiber.yield
      n &+= 1
      sleep 50.microseconds if n % 512 == 0
    end
  end
end

# Let the population reach steady state before the first collect.
sleep 50.milliseconds

collects.times do
  GC.collect
  sleep 1.millisecond
end
running = false

threads = 0
Thread.unsafe_each { threads += 1 }

scrubs = HEAP.fiber_scrub_foreign_sp_scrubs
overlaps = HEAP.fiber_scrub_live_frame_overlaps

puts "=== parked-fiber scrub audit ==="
puts "parallelism=#{parallelism} threads=#{threads} fibers=#{fibers} collects=#{collects}"
puts "  scrub runs                 = #{HEAP.fiber_scrub_runs}"
puts "  bytes wiped                = #{HEAP.fiber_scrub_bytes_total}"
puts "  scrubbed with a foreign SP = #{scrubs}"
puts "  ...wipe reached live frames= #{overlaps}"
# Separates "no SP was ever recorded" (probe blind) from "SPs were recorded but
# none landed on a fiber stack" (probe works, window did not occur). Without
# this, a zero above has two very different readings.
puts "  suspended-thread SPs seen  = #{HEAP.sp_clamp_hits} on a mapping, " \
     "#{HEAP.sp_clamp_fallbacks} elsewhere"
puts ""

if threads < 2
  STDERR.puts "FAIL: only #{threads} thread — no foreign SP can exist, nothing was audited. " \
              "Build with -Dpreview_mt -Dexecution_context."
  exit 1
end

pct = scrubs > 0 ? (overlaps * 100.0 / scrubs).round(1) : 0.0

if no_skip
  # Positive control: report, never fail. Running with the guard off is the
  # unsafe configuration by construction — the point is to see the counters
  # move, which is what licenses reading a zero from the guarded run.
  puts "positive control (guard off): #{scrubs} foreign-SP scrub(s), " \
       "#{overlaps} reaching live frames (#{pct}%)"
  if scrubs == 0
    STDERR.puts "INCONCLUSIVE: even with the guard off the probe saw no foreign SP. " \
                "It cannot observe this window on this build/shape, so a zero from " \
                "the guarded run says nothing. Raise --parallelism or --fibers."
    exit 1
  end
  exit 0
end

if overlaps > 0
  STDERR.puts "FAIL: the parked-fiber scrub zeroed live frames #{overlaps} time(s) " \
              "(#{pct}% of #{scrubs} foreign-SP scrubs). A pointer held only there is dropped."
  exit 1
end

# `overlaps == 0` because nothing was observed is not the same result as
# `overlaps == 0` out of N observations, and only the second is evidence. Refuse
# to print a pass for the first — an audit whose green is reachable without
# observing anything is worse than no audit.
if scrubs == 0
  STDERR.puts "INCONCLUSIVE: 0 foreign-SP scrubs — the wipe was never seen landing on a " \
              "stack a thread was on, so there was nothing to overlap. This is not a pass. " \
              "Run --no-skip first: until that shows the probe can see the window, a zero " \
              "here says only that the probe is blind to it."
  exit 1
end

puts "ok — #{overlaps} of #{scrubs} foreign-SP scrub(s) reached live frames"
