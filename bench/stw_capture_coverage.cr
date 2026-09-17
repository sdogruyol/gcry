# Does the STW capture table cover every thread it suspends?
#
# `slot_for` returns -1 when the table is full, and a thread with no slot is
# suspended and scanned with **no SP clamp and no registers captured**. The SP
# half of that is conservative — `scan_pthread_stack` with no SP walks the whole
# stack — but the registers are not, on the platform where they exist only in
# the table:
#
#   Linux    registers come from the signal `ucontext`, and the handler is
#            installed with `SA_SIGINFO` and **not** `SA_ONSTACK`, so that
#            ucontext sits on the interrupted thread's own stack. An unclamped
#            full-stack walk therefore still finds them. The table stays a fixed
#            64 there deliberately: the loss is precision, not soundness, and
#            the table is shared with a signal handler that claims from every
#            thread at once.
#   Darwin   registers come from `thread_get_state` into the table and nowhere
#            else. Past 64 threads they were **gone** — a reference held only in
#            the 65th thread's registers was not a root, which is the v0.19.0
#            `each_thread_greg` stub on a new axis.
#   Windows  the stop used to be *refused* at the 64th thread
#            (`raise_thread_suspension_error`: "or exceeded 64 threads"), so a
#            process with 65 threads could not collect at all — a bounded loss
#            traded for an unbounded heap.
#
# Both tables now grow at collection entry, before the first suspend, with
# `LibC.malloc` and never inside the stopped world (`malloc` there is the
# 2026-08-10 six-hour hang). The 64-bit claim mask is gone — it *was* the bound,
# since a `UInt64` cannot address a 65th slot — replaced by one byte per slot,
# with no CAS because on these two platforms `slot_for` runs only on the
# collector, one thread at a time.
#
# The contract is `stw_capture_no_slot == 0` with more threads than the initial
# capacity, and `stw_slot_capacity` is reported beside it so a zero cannot be
# read as coverage when it is really a table that was never asked to grow.
#
# Three arms, each a bounded child:
#
#   grow     `THREADS` threads, a collection, and **no** failed claims. This is
#            the gate.
#   fixed    the same with `GCRY_STW_FIXED_SLOTS=1`, which pins the table at its
#            initial 64. Failed claims must be **non-zero** — that is the
#            pre-fix bound, and without it the grow arm has no red direction.
#   control  `CONTROL_THREADS` threads with the same knob, inside the initial
#            capacity, where nothing is lost. Zero there too, which is what
#            makes the fixed arm's non-zero attributable to the bound rather
#            than to the knob.
#
#   crystal build -Dgc_none bench/stw_capture_coverage.cr -o bin/stw_capture_coverage
#   bin/stw_capture_coverage
#   bin/stw_capture_coverage --child=grow

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "stw_capture_coverage requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% unless flag?(:darwin) || flag?(:win32) %}
  puts "=== STW capture coverage ==="
  puts "SKIP — this platform keeps a fixed 64-slot table on purpose. Its registers come"
  puts "from a signal ucontext on the interrupted thread's own stack, which the unclamped"
  puts "full-stack scan still walks, so a missing slot costs precision and not a root"
  puts "(src/gcry/platform/linux_stw.cr, and the SA_ONSTACK-less handler there)."
  exit 0
{% end %}

HEAP = Gcry.default_heap.not_nil!

# Read through a macro branch, not directly: `stw_fixed_slots?` exists only on
# the two platforms that grow the table, and everything below this file's
# platform guard still type-checks on the others — the mistake that broke two
# Windows jobs when `tls_roots.cr` reached a Unix-only module.
def fixed_slots? : Bool
  {% if flag?(:darwin) || flag?(:win32) %}
    Gcry::Platform.stw_fixed_slots?
  {% else %}
    false
  {% end %}
end

# Comfortably past the initial 64 so the table has to double, and not so many
# that a small runner spends its time scheduling.
THREADS         = 80
CONTROL_THREADS =  8

ARM_BUDGET = 90.seconds

child_arm = ARGV.find(&.starts_with?("--child=")).try(&.split('=', 2)[1])

ARGV.each do |arg|
  next if arg.starts_with?("--child=")
  STDERR.puts "unknown argument #{arg.inspect}: this harness takes no arguments (it drives " \
              "its arms as bounded children) or exactly one --child=grow|fixed|control."
  exit 64
end

unless child_arm
  exe = Process.executable_path.not_nil!
  pinned = {"GCRY_STW_FIXED_SLOTS" => "1"}
  arms = [
    {"grow", {} of String => String},
    {"fixed", pinned},
    {"control", pinned},
  ]
  failures = [] of String
  puts "=== STW capture coverage ==="
  arms.each do |(arm, env)|
    result = BoundedChild.run(exe, ["--child=#{arm}"], env, ARM_BUDGET)
    result.output.each_line do |line|
      puts "  #{line.rstrip}" unless line.strip.empty?
    end
    next if result.ok

    failures << if result.timed_out
      "#{arm}: outlived its #{ARM_BUDGET.total_seconds.to_i}s budget"
    else
      "#{arm}: see the arm's own output above"
    end
  end
  puts ""
  if failures.empty?
    puts "ok — #{THREADS} threads are all covered by the capture table, the pre-fix 64-slot " \
         "bound demonstrably loses some of them, and the same bound inside its capacity loses " \
         "none: the grow arm's zero is about the growth and not about the knob."
    exit 0
  end
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end

unless child_arm.in?("grow", "fixed", "control")
  STDERR.puts "unknown arm #{child_arm.inspect}: expected grow, fixed or control."
  exit 64
end

control = child_arm == "control"
fixed = child_arm != "grow"
want = control ? CONTROL_THREADS : THREADS

if fixed && !fixed_slots?
  STDERR.puts "arm #{child_arm} needs GCRY_STW_FIXED_SLOTS=1 to pin the table at its initial " \
              "capacity; without it this arm would measure the shipped growing table."
  exit 64
end

puts "arm #{child_arm}: #{want} threads, #{fixed ? "table pinned at its initial size" : "growing table"}"

stop = Atomic(Int32).new(0)
started = Atomic(Int32).new(0)
threads = [] of Thread
want.times do
  threads << Thread.new do
    started.add(1)
    held = [] of String
    while stop.get == 0
      held << "x" * 32
      held.clear if held.size > 64
      Thread.sleep(5.milliseconds)
    end
  end
end
while started.get < want
  Thread.sleep(1.millisecond)
end

live = 0
Thread.unsafe_each { live += 1 }

before = HEAP.stw_capture_no_slot
words_before = HEAP.thread_greg_words_total
GC.collect
GC.collect
no_slot = HEAP.stw_capture_no_slot - before
greg_words = HEAP.thread_greg_words_total - words_before
capacity = HEAP.stw_slot_capacity

stop.set(1)
threads.each(&.join)

puts "threads_on_list=#{live} slot_capacity=#{capacity} " \
     "no_slot=#{no_slot} greg_words_offered=#{greg_words}"

failures = [] of String

# Precondition: a collection that captured nothing says nothing about coverage.
if greg_words == 0
  failures << "the register scan was offered no words at all across two collections, so " \
              "nothing below is about capture — either the stop took a single-threaded path " \
              "or the capture is not running"
end

if fixed && !control
  if no_slot == 0
    failures << "the table was pinned at #{capacity} slots with #{live} threads on the list " \
                "and still turned nobody away, so GCRY_STW_FIXED_SLOTS is not pinning it and " \
                "the grow arm has no red direction"
  end
  if capacity > THREADS
    failures << "the pinned table holds #{capacity} slots, which is more than the #{THREADS} " \
                "threads this arm starts — it grew anyway"
  end
else
  if no_slot > 0
    failures << "#{no_slot} claim(s) found the table full at #{capacity} slots with #{live} " \
                "threads on the list: those threads were suspended and scanned with no SP " \
                "clamp and no registers, which is a root the collector cannot see"
  end
  unless control || capacity > CONTROL_THREADS + 1
    failures << "capacity is #{capacity} with #{live} threads on the list, so the zero above " \
                "is a table that never had to cover anyone rather than one that did"
  end
end

if failures.empty?
  puts fixed && !control ? "ok — the pinned table turns threads away, as it must for the gate to mean anything" \
                            : "ok — every suspended thread got a capture slot"
  exit 0
end

failures.each { |f| STDERR.puts "  - #{f}" }
exit 1
