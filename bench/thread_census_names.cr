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
#   (default)    A **raw pthread**, named `gcry-probe`, that Crystal has never
#                heard of. The gap must appear, the report must contain
#                `gcry-probe`, and it must be left unexplained: this is a
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
  fun pthread_join(thread : LibC::PthreadT, retval : Void**) : LibC::Int
  fun pthread_setname_np(thread : LibC::PthreadT, name : LibC::Char*) : LibC::Int
  fun pthread_self : LibC::PthreadT
end

PROBE_COMM = "gcry-probe"
COLLECTS   = 6

# The planted thread spins on this word and touches nothing else: it stands in
# for a thread whose runtime is not up yet, and a stand-in that uses the runtime
# proves nothing. `malloc` rather than a class variable so reaching it needs no
# lazy initializer on a thread that has not finished starting.
RAW_RUN = Pointer(Int32).malloc(1)

def start_probe_thread : LibC::PthreadT
  tid = uninitialized LibC::PthreadT
  RAW_RUN.value = 1
  body = ->(_arg : Void*) do
    LibRawThread.pthread_setname_np(LibRawThread.pthread_self,
      PROBE_COMM.to_unsafe.as(LibC::Char*))
    while RAW_RUN.value == 1
      Intrinsics.pause
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
       else
         "plant (a raw pthread named #{PROBE_COMM}, which Crystal never lists)"
       end

puts "=== naming the threads outside Crystal's list ==="
puts "mode: #{mode}"
puts "census=#{heap.thread_census} names=#{heap.thread_census_names} " \
     "parallel_mark_workers=#{heap.parallel_mark_workers}"

probe = control || mark_arm ? nil : start_probe_thread
# The planted thread has to be running before the first collection, or the arm
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

puts "checks=#{checks} gaps=#{gaps} gap_max=#{heap.thread_census_gap_max} " \
     "own=#{own} unexplained=#{unexplained} unanswered=#{unanswered} unwalked=#{unwalked}"

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

if control
  failures << "control saw #{gaps} gap(s): something in this process is outside " \
              "Crystal's list and the other arms cannot attribute their gap" if gaps > 0
  failures << "control explained nothing but counted #{unexplained} unexplained" if unexplained > 0
elsif mark_arm
  failures << "no gap with #{heap.parallel_mark_workers} mark workers — the helper " \
              "pthreads did not outlive a collection, so this arm measured nothing" if gaps == 0
  if noname
    # The twin: with the walk off nothing is subtracted, so every gap stands.
    failures << "naming is off and #{own} task(s) were still counted as gcry's own" if own > 0
    failures << "naming is off yet #{unexplained} of #{gaps} gaps were explained" if unexplained != gaps
  else
    failures << "the walk found no gcry-mark helper, so the gap was not attributed" if own == 0
    failures << "#{unexplained} gap(s) left unexplained with only gcry's own helpers " \
                "running — the helpers are still being counted as unscanned mutators" if unexplained > 0
  end
else
  failures << "the planted raw pthread produced no census gap" if gaps == 0
  if noname
    failures << "naming is off yet #{own} task(s) were counted as gcry's own" if own > 0
    failures << "naming is off yet #{unexplained} of #{gaps} gaps were explained" if unexplained != gaps
  else
    failures << "the planted thread was explained away; it is a thread gcry cannot " \
                "account for and must not subtract" if unexplained != gaps
    failures << "the walk counted #{own} gcry-mark helper(s) with parallel mark off" if own > 0
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
