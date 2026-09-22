# Which thread is outside Crystal's list?
#
# `GCRY_THREAD_CENSUS=1` has been able to say **how many** since 2026-08-17 and
# never **which**. That is not a cosmetic gap. `test (aarch64 native)` reports
# a difference of exactly one on every collection of `scheduler_roots
# --control` — an arm that starts no execution context and no worker — in 40 of
# 40 green runs, while the same binary on an x86_64 box reports none. A count
# cannot tell that apart from the birth window the census was built for, so the
# line has been read as the open unscanned-mutator defect for a month with
# nothing to confirm or deny it.
#
# Worse, the count has a false positive of gcry's own making. Parallel mark
# helpers are raw `pthread_create` threads on purpose (`parallel_mark.cr`: a
# `Crystal::Thread` would freeze in `stop_world`), so they are outside Crystal's
# list **by construction** — and the census counted every one of them as a
# thread running unscanned through the stopped world. Measured before the fix:
# `GCRY_PARALLEL_MARK=4` with no other thread in the process reports `gap=3`.
#
# So the census now walks `/proc/self/task` on a gap and names each task by
# kernel thread id and `comm`, and gcry names its own helpers `gcry-mark` so
# they can be subtracted. `thread_census_unexplained` is the number that means
# what `thread_census_gaps` was being read to mean.
#
# The arms, and what each would catch:
#
#   control      No extra thread. The census must find no gap and print no
#                names — an instrument that reports on a quiet process is
#                reporting noise.
#   (default)    A **raw pthread**, named `census-probe`, that Crystal has never
#                heard of. The gap must appear, the report must contain
#                `census-probe`, and it must be left unexplained: this is a
#                thread gcry cannot account for and must not pretend to.
#   noname       RED twin. `GCRY_THREAD_CENSUS_NAMES=0` restores the count-only
#                census. Same planted thread, so the gap is identical — and no
#                name is printed and nothing is explained. Without this arm the
#                one above cannot tell "the walk named it" from "the gap
#                happened to be one".
#   mark         `GCRY_PARALLEL_MARK=4` and no planted thread. The helpers are
#                the whole gap, every one of them is named `gcry-mark`, and
#                **nothing** is left unexplained. This is the false positive.
#   mark-noname  RED twin for the arm above: with the naming off the same run
#                leaves the helpers unexplained, which is what the census did
#                before and what would be read as a soundness defect.
#   parked       The planted thread **sleeps** instead of spinning, so a task
#                parked in a syscall exists by construction. The two arms that
#                ask where a task is — the `parked in syscall N, returning to`
#                line and the `returns through:` walk above it — had no parked
#                task of their own and relied on catching Crystal's `SYSMON`
#                asleep. It is usually asleep; on 2026-09-22 (run
#                `35707265944`) it and the probe were both on-CPU at the sample
#                instant and the gate went red on a green tree. A gate whose
#                subject is a peer's phase is a flake, so this arm makes the
#                phase.
#
#   crystal build -Dgc_none bench/thread_census_names.cr -o bin/thread_census_names
#   GCRY_THREAD_CENSUS=1 bin/thread_census_names

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "thread_census_names requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% unless flag?(:linux) %}
  {% raise "the thread census reads /proc/self/task; Linux only" %}
{% end %}

lib LibRawThread
  fun pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*,
                     start : Void* -> Void*, arg : Void*) : LibC::Int
  fun nanosleep(req : LibC::Timespec*, rem : LibC::Timespec*) : LibC::Int
  fun pthread_join(thread : LibC::PthreadT, retval : Void**) : LibC::Int
  fun pthread_setname_np(thread : LibC::PthreadT, name : LibC::Char*) : LibC::Int
  fun pthread_self : LibC::PthreadT
end

# Deliberately **not** `gcry-`: that prefix is how the census recognises a
# thread gcry created, and a probe standing in for a mutator must not wear it.
PROBE_COMM = "census-probe"
COLLECTS   = 6

# The planted thread spins on this word and touches nothing else: it stands in
# for a thread whose runtime is not up yet, and a stand-in that uses the runtime
# proves nothing. `malloc` rather than a class variable so reaching it needs no
# lazy initializer on a thread that has not finished starting.
RAW_RUN = Pointer(Int32).malloc(1)

# A code address in this binary, and this harness's own answer for where it
# sits. `Platform.pc_mapping` must agree.
#
# Not decoration: the offset it reports is only useful if `addr2line` can
# resolve it, and that needs the distance from the file's **load base**. A PIE
# has several LOAD segments and the executable one is not the first, so an
# offset measured from the mapping the pc happens to be in names nothing —
# which is what the first version reported. Both sides compute the base
# independently here: the collector from its raw `/proc/self/maps` walk, this
# harness from Crystal's, and a mismatch is the bug.
def census_anchor : Int32
  42
end

ANCHOR = ->census_anchor

def expected_load_base : UInt64?
  exe = File.realpath("/proc/self/exe")
  lowest = nil.as(UInt64?)
  File.each_line("/proc/self/maps") do |line|
    fields = line.split
    next unless fields.size >= 6 && fields[5] == exe
    lo = fields[0].split('-').first.to_u64(16)
    lowest = lo if lowest.nil? || lo < lowest.not_nil!
  end
  lowest
end

# `--parked`: the same raw pthread, sleeping rather than spinning, so the
# process always has a task parked in a syscall with a return site to resolve.
# 20 ms at a time, so the join below still takes about that long — a thread
# parked in one long sleep would have to be signalled to leave it, and a signal
# is exactly what the census must not need.
PARKED = Pointer(Int32).malloc(1)

def start_probe_thread : LibC::PthreadT
  tid = uninitialized LibC::PthreadT
  RAW_RUN.value = 1
  body = ->(_arg : Void*) do
    LibRawThread.pthread_setname_np(LibRawThread.pthread_self,
      PROBE_COMM.to_unsafe.as(LibC::Char*))
    if PARKED.value == 1
      req = uninitialized LibC::Timespec
      rem = uninitialized LibC::Timespec
      req.tv_sec = typeof(req.tv_sec).new(0)
      req.tv_nsec = typeof(req.tv_nsec).new(20_000_000)
      while RAW_RUN.value == 1
        LibRawThread.nanosleep(pointerof(req), pointerof(rem))
      end
    else
      while RAW_RUN.value == 1
        Intrinsics.pause
      end
    end
    Pointer(Void).null
  end
  rc = LibRawThread.pthread_create(pointerof(tid), Pointer(LibC::PthreadAttrT).null,
    body, Pointer(Void).null)
  raise "pthread_create failed: #{rc}" unless rc == 0
  tid
end

control = ARGV.includes?("--control")
noname = ARGV.includes?("--noname")
mark_arm = ARGV.includes?("--mark")
PARKED.value = ARGV.includes?("--parked") ? 1 : 0

heap = Gcry.default_heap.not_nil!

unless heap.thread_census
  STDERR.puts "this harness needs GCRY_THREAD_CENSUS=1: with the census off it " \
              "would assert on counters nothing updates and pass for that reason."
  exit 64
end

# The twin arms must actually be the twin. `--noname` without the knob measures
# the shipped instrument and calls it a control, which is the failure the
# dying-fiber gate hit when `GCRY_DEAD_STACK_NOROOT` alone still offered words.
if noname && heap.thread_census_names
  STDERR.puts "--noname needs GCRY_THREAD_CENSUS_NAMES=0; with naming on this arm " \
              "would require the shipped walk to stay silent."
  exit 64
end
if !noname && !heap.thread_census_names
  STDERR.puts "this arm needs the naming on; GCRY_THREAD_CENSUS_NAMES=0 is set."
  exit 64
end
if mark_arm && heap.parallel_mark_workers <= 1
  STDERR.puts "--mark needs GCRY_PARALLEL_MARK>1: with one worker no helper pthread " \
              "is created and the arm would assert on a gap that cannot occur."
  exit 64
end
if !mark_arm && heap.parallel_mark_workers > 1
  STDERR.puts "GCRY_PARALLEL_MARK>1 outside --mark: the helpers would join the gap " \
              "this arm attributes to its own planted thread."
  exit 64
end

mode = if control
         "control (no thread outside Crystal's list; the census must stay quiet)"
       elsif mark_arm && noname
         "mark-noname (GCRY_THREAD_CENSUS_NAMES=0: gcry's own helpers read as unexplained)"
       elsif mark_arm
         "mark (gcry's own parallel-mark helpers are the whole gap)"
       elsif noname
         "noname (GCRY_THREAD_CENSUS_NAMES=0: the gap is counted and not named)"
       elsif PARKED.value == 1
         "parked (the planted #{PROBE_COMM} sleeps, so a task is parked in a syscall by construction)"
       else
         "plant (a raw pthread named #{PROBE_COMM}, which Crystal never lists)"
       end

puts "=== naming the threads outside Crystal's list ==="
puts "mode: #{mode}"
puts "census=#{heap.thread_census} names=#{heap.thread_census_names} " \
     "parallel_mark_workers=#{heap.parallel_mark_workers}"

# Two phases in one process. The first measures **this host's** baseline,
# because a host can already have a thread outside Crystal's list and the
# first version of this harness asserted it could not — `--control` came out
# red on `test (aarch64 native)` for a correct reason it had no way to say.
# The aarch64 runner has exactly one such task, carrying the process's own
# `comm`, present before anything is planted:
#
#   OS tasks: 7009:thread_census_n 7010:SYSMON 7011:thread_census_n
#             — 0 are gcry's own mark helpers, leaving 1 unexplained
#
# So nothing here asserts an absolute. What it asserts is a **delta** the
# planted thread caused, and a relationship between the raw gap and the
# unexplained one that holds whatever the host brought with it.
#
# The **last** sample, not the largest, on both sides. A maximum can be set
# by a thread that existed during the baseline and was gone by the planted
# phase, which leaves both maxima equal and reads as "the plant changed
# nothing" — seen once here, `did not widen the gap (1 -> 1)`, on a tree
# whose only change was in a reporting path. A transient cannot inflate a
# last sample.
COLLECTS.times { GC.collect }
base_gap = heap.thread_census_gap_now
base_unexplained = heap.thread_census_unexplained_now
# What the walk already credits to gcry before this arm plants anything. On a
# host with the STW watchdog armed that is 1 — the watchdog is a raw pthread
# and gcry's own — and `test (aarch64 native)` arms it for its whole step, so
# an arm that demanded zero here would be asserting an absolute about the
# host all over again.
base_attributed = base_gap - base_unexplained
expected_own = Gcry::StwWatchdog.armed? ? 1 : 0
puts "baseline (nothing planted): gap=#{base_gap} unexplained=#{base_unexplained} " \
     "attributed=#{base_attributed} watchdog_armed=#{Gcry::StwWatchdog.armed?} " \
     "(peaks #{heap.thread_census_gap_max}/#{heap.thread_census_unexplained_max})"

probe = control || mark_arm ? nil : start_probe_thread
# The planted thread has to be running before the next collection, or the arm
# measures a window it did not open.
sleep 100.milliseconds

COLLECTS.times { GC.collect }

if t = probe
  RAW_RUN.value = 0
  LibRawThread.pthread_join(t, Pointer(Void*).null)
end

checks = heap.thread_census_checks
gaps = heap.thread_census_gaps
own = heap.thread_census_own
unexplained = heap.thread_census_unexplained
unanswered = heap.thread_census_unanswered
unwalked = heap.thread_census_unwalked
gap_now = heap.thread_census_gap_now
unexplained_now = heap.thread_census_unexplained_now
# How many threads the walk subtracted at the last collection. With the naming
# on and mark helpers running this is the helper count; with the naming off,
# or with no helper, it is zero. Independent of what the host already had,
# because the baseline is in both terms.
attributed = gap_now - unexplained_now
helpers = mark_arm ? heap.parallel_mark_workers - 1 : 0

puts "checks=#{checks} gaps=#{gaps} gap=#{gap_now} " \
     "unexplained=#{unexplained_now} attributed=#{attributed} " \
     "own=#{own} gapped_collections=#{unexplained} unanswered=#{unanswered} unwalked=#{unwalked}"

failures = [] of String

# A census that never looked cannot report an absence. This is the check that
# stops every arm below from passing vacuously.
if checks == 0
  failures << "the census ran 0 checks, so every count below is an absence of " \
              "looking rather than an absence of threads"
end
if unanswered > 0
  failures << "/proc could not answer on #{unanswered} of #{checks} checks; the " \
              "counts are not a measurement"
end
# And one level down, for the same reason. Found by breaking the walk on
# purpose: with `each_os_thread` stubbed to `false` every naming arm still
# passed, because "attributed nothing" and "could not look" give the same
# `own` and `unexplained`. This is the line that tells them apart.
if unwalked > 0
  failures << "/proc/self/task could not be walked on #{unwalked} of #{gaps} gaps, " \
              "so an unattributed gap here is a dead walk and not a finding"
end

# Every arm checks this: the offsets the census prints are only actionable if
# they are measured from the file's load base, and nothing else here would
# notice if they were not.
anchor = ANCHOR.pointer.address.to_u64
if base = expected_load_base
  reported = nil.as(UInt64?)
  named = Gcry::Platform.pc_mapping(anchor) { |_n, _l, off| reported = off }
  if !named
    failures << "pc_mapping found no mapping for an address inside this binary"
  elsif reported != anchor - base
    failures << "pc_mapping put a known address of this binary at +0x#{reported.try(&.to_s(16))}, " \
                "and it is at +0x#{(anchor - base).to_s(16)} from the load base — an offset " \
                "measured from the containing segment is not one addr2line can resolve"
  end
else
  failures << "could not find this binary's own mappings in /proc/self/maps, " \
              "so the offset check below would pass by not looking"
end

if control
  # No assertion that the host is quiet — it may not be, and that is a
  # finding rather than a failure. What must hold is that the threads
  # credited to gcry are exactly the ones gcry has: with the watchdog armed
  # that is one, with it off it is none. This is the arm that gates the
  # watchdog's own name, and without it that thread reads as an unrecorded
  # mutator, which is what `test (aarch64 native)` reported on every
  # collection of every binary.
  if attributed != expected_own
    failures << "#{attributed} task(s) were attributed to gcry with no mark helper " \
                "running and the watchdog #{Gcry::StwWatchdog.armed? ? "armed" : "off"}, " \
                "where #{expected_own} is right — an unnamed gcry thread reads as an " \
                "unrecorded mutator, and a miscredited one hides a real gap"
  end
  puts "host baseline: #{gap_now} thread(s) outside Crystal's list, " \
       "#{attributed} of them gcry's own"
elsif mark_arm
  failures << "no gap with #{heap.parallel_mark_workers} mark workers — the helper " \
              "pthreads did not outlive a collection, so this arm measured nothing" if gaps == 0
  if noname
    # The twin: with the walk off nothing is subtracted, so every thread the
    # helpers add stays in the unexplained count.
    failures << "naming is off and #{own} task(s) were still counted as gcry's own" if own > 0
    failures << "naming is off yet #{attributed} task(s) were subtracted from the gap" if attributed != 0
  else
    failures << "the walk found no gcry thread, so the gap was not attributed" if own == 0
    # The helpers exist for the baseline phase too — this arm plants nothing
    # in the second one — so the expectation is absolute in gcry's own terms:
    # the watchdog, if this host arms one, plus every mark helper.
    if attributed != expected_own + helpers
      failures << "#{attributed} task(s) credited to gcry where #{expected_own + helpers} " \
                  "is right (#{helpers} mark helper(s) + #{expected_own} watchdog) — the " \
                  "rest are still counted as unscanned mutators"
    end
  end
else
  # The planted thread is **not** gcry's, so it must widen both the raw gap and
  # the unexplained one. Against this process's own baseline, so a host that
  # already has an unlisted thread neither hides the plant nor fakes it.
  failures << "the planted raw pthread did not widen the gap " \
              "(#{base_gap} -> #{gap_now})" if gap_now <= base_gap
  failures << "the planted raw pthread did not widen the unexplained gap " \
              "(#{base_unexplained} -> #{unexplained_now}); it is a thread gcry " \
              "cannot account for and must not subtract" if unexplained_now <= base_unexplained
  if attributed != base_attributed
    failures << "the plant moved what is credited to gcry (#{base_attributed} -> " \
                "#{attributed}); a probe named outside the `gcry-` prefix must not be"
  end
end

if failures.empty?
  puts
  puts "ok — #{mode.split(' ').first}"
  exit 0
end

puts
failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
