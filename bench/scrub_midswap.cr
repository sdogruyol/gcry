# Is the parked-fiber scrub's mid-swap guard load-bearing, and can it even fire?
#
# `bench/scrub_audit.cr` closed the foreign-thread half of the scrub question
# and `bench/scrub_margin.cr` measured the margin (zero: the wipe ends exactly
# where `swapcontext`'s saved registers begin). One question was left open in
# both, and in ROADMAP Phase 3: the **mid-swap suspend** — a thread whose SP is
# still on a stack whose fiber already reports parked. `scrub_skip_foreign_sp`
# exists for exactly that state, and nothing has ever observed it: with the
# guard deliberately off, 300 collections at EC4 (and 3000 across 128 fibers)
# produced zero sightings. A guard that has never been seen to do anything is
# indistinguishable from a guard that does nothing.
#
# The window cannot be hunted — reading Crystal's context switch says why. On
# every backend (`x86_64-sysv`, `x86_64-microsoft`, `aarch64-generic`,
# `aarch64-microsoft`, `arm`) the order is fixed:
#
#     stack_top = sp          # exact, all saved registers at addresses >= sp
#     (dmb ish on aarch64)    # register stores ordered before the flag
#     current.resumable = 1   # only now does `running?` go false
#     new.resumable = 0       # the resumed fiber is marked running...
#     sp = new.stack_top      # ...before any SP lands on its stack
#
# So the real window is a few instructions wide *and* harmless while it lasts:
# in it `stack_top == sp`, and the wipe covers `[stack_top - wipe, stack_top)`,
# strictly below the SP. The dangerous shape — a fiber reporting parked while a
# thread runs *deeper* than its recorded `stack_top`, so the wipe lands above
# the SP and over live frames — is ruled out on the resume side by the last two
# lines, and on the teardown side by `Fiber#run`, which delists the fiber before
# its stack is returned to the pool.
#
# That is an argument, not a measurement, and this repo has already been burned
# once by an audit whose green was reachable without observing anything. So:
# manufacture the dangerous state instead of waiting for it.
#
# A fiber spins on its own worker thread, deep below the `stack_top` it recorded
# at its last park. `HEAP.scrub_force_parked` then makes the scrub — and only the
# scrub, with the world already stopped — treat it as parked, which is exactly
# the state the ordering above forbids and the one the guard is written against.
#
# The obvious way to do that is from here: write 1 into the fiber's own
# `Context.resumable`. Don't. That state is also visible to Crystal's scheduler,
# which reads the same field to decide a fiber is safe to resume, so a worker can
# take over a stack another thread is running on. It hung 1 run in 26 inside STW.
# The knob keeps the lie inside the collector, where the world is stopped and
# nothing else can act on it. Then:
#
#   stale-off  guard off → the wipe must land on live frames: `overlaps > 0`
#              and the fiber's canaries corrupt. This is the positive control.
#              Without it, the clean result below means nothing.
#   stale-on   guard on  → `fiber_scrub_midswap_skips > 0` and no corruption.
#              This is the first observation of the guard doing its job.
#   real       no manufacturing → how often the *genuine* window occurs, now
#              countable with the guard left on. Reported, never asserted.
#
#   crystal build -Dgc_none -Dpreview_mt -Dexecution_context \
#     bench/scrub_midswap.cr -o bin/scrub_midswap
#   bin/scrub_midswap                  # all three scenarios, each a child
#   bin/scrub_midswap --mode=stale-on   # one scenario (used as the child)

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "scrub_midswap requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% unless flag?(:execution_context) %}
  # The guard is Parallel-only: `multi_mutator_threads?` gates it on more than
  # two OS threads and `scrub_skip_foreign_sp` is only consulted there, so a
  # plain build cannot reach the code under test at all.
  {% raise "scrub_midswap requires -Dpreview_mt -Dexecution_context" %}
{% end %}

HEAP = Gcry.default_heap.not_nil!

MODES = ["real", "stale-off", "stale-on"]

# 512 bytes: the Parallel wipe width (`FIBER_CLEAR_STACK_CAP`), so one frame's
# canary spans the whole band the scrub would zero.
CANARY_WORDS = 64
SPIN_DEPTH   =  6
PARALLELISM  =  4
SPIN_SECONDS = 20

# One collect once the state is manufactured. `stale-off` runs on with its own
# frames zeroed, and stopping the world *again* in a program whose stack is
# rubble is not a shape anything has to survive — it was measured to deadlock
# there (main in `sigsuspend`, the spinner's thread spinning at R). One collect
# is also all it takes: the state is static, so a single collect either wipes it
# or skips it.
STALE_COLLECTS = 1
# `real` corrupts nothing, so it can collect freely.
REAL_COLLECTS = 20
# Ceiling per child. The 20 s spin deadline bounds the harness's own loop; this
# bounds everything else, including a runtime that never finishes dying.
CHILD_TIMEOUT_SECONDS = 60
# Attempts per scenario when a child hangs before it reaches the scrub. That was
# a different, real bug — the collector calling pthread_getattr_np under STW,
# which this shape tripped on ~8% of starts — now fixed and gated by
# `bench/stw_startup_hang.cr`. Kept because the retry is what told us this tool's
# flakiness was not its own: it reports the count, so a hang coming back here is
# visible rather than absorbed.
HANG_RETRIES = 4

# Atomics are structs, so these must be touched through the ivars — a getter
# would hand out copies and every store would be lost.
class SpinState
  @ready = Atomic(Int32).new(0)
  @stop = Atomic(Int32).new(0)
  @done = Atomic(Int32).new(0)
  @bad = Atomic(Int32).new(0)
  @thread = Atomic(UInt64).new(0_u64)

  def ready? : Bool
    @ready.get != 0
  end

  def ready!(thread_id : UInt64) : Nil
    @thread.set(thread_id)
    @ready.set(1)
  end

  def thread_id : UInt64
    @thread.get
  end

  def stop? : Bool
    @stop.get != 0
  end

  def stop! : Nil
    @stop.set(1)
  end

  def done? : Bool
    @done.get != 0
  end

  def done! : Nil
    @done.set(1)
  end

  def bad : Int32
    @bad.get
  end

  def add_bad(n : Int32) : Nil
    @bad.add(n) if n > 0
  end
end

# Each frame stamps a canary that covers the wipe band and re-checks it after
# the innermost call returns. A wipe that reached these frames shows up as a
# mismatch even if it does not manage to segfault the process — the same reason
# `scrub_margin` checks values instead of trusting a crash.
@[NoInline]
def spin_deep(depth : Int32, state : SpinState, deadline : Time::Span) : UInt64
  canary = uninitialized UInt64[CANARY_WORDS]
  tag = 0xC0FFEE0000_u64 &+ depth.to_u64
  i = 0
  while i < CANARY_WORDS
    canary[i] = tag &+ i.to_u64
    i += 1
  end

  if depth > 0
    spin_deep(depth - 1, state, deadline)
  else
    # Deepest frame: publish that we are parked-deep and hold the thread here
    # without ever yielding, so STW has to suspend it by signal and
    # `Platform.thread_sp` records an SP far below the fiber's `stack_top`.
    # The deadline is a hang guard — the parent must always get a verdict.
    state.ready!(Thread.current.object_id.to_u64)
    while !state.stop? && Time.monotonic < deadline
    end
  end

  bad = 0
  i = 0
  while i < CANARY_WORDS
    bad += 1 if canary[i] != tag &+ i.to_u64
    i += 1
  end
  state.add_bad(bad)
  canary[0]
end

def run_child(mode : String) : Int32
  manufacture = mode.starts_with?("stale")

  # Set on the heap, not via env: a forgotten GCRY_* would turn this check into
  # a silent pass, which is the failure mode `scrub_audit` was rewritten to
  # avoid.
  HEAP.scrub_fibers_enabled = true
  HEAP.scrub_audit_foreign_sp = true
  HEAP.scrub_skip_foreign_sp = (mode != "stale-off")

  Fiber::ExecutionContext.default.resize(PARALLELISM)

  state = SpinState.new
  deadline = Time.monotonic + SPIN_SECONDS.seconds
  spinner = nil.as(Fiber?)

  spawn do
    spinner = Fiber.current
    # Park once first, so `stack_top` is a real swapcontext record near the top
    # of the stack rather than the initial `makecontext` value, and the frames
    # built below it are the ones the wipe band covers.
    Fiber.yield
    spin_deep(SPIN_DEPTH, state, deadline)
    state.done!
  end

  until state.ready?
    Fiber.yield
  end

  # Read *after* the wait, not before: the spinner is queued on this thread and
  # takes it over on the first yield, which hands this fiber to another worker.
  # Comparing against the thread we started on therefore always reports a
  # collision. What has to differ is the thread this fiber is on when it calls
  # `GC.collect` — `fiber_stack_foreign_sp` skips `Thread.current`, and a fiber
  # cannot migrate without a yield point, so there is none between here and the
  # collect below.
  own_thread = Thread.current.object_id.to_u64
  if state.thread_id == own_thread
    STDERR.puts "SKIP: the spinner was scheduled onto this fiber's own thread, " \
                "so no foreign SP can exist. Re-run; raise PARALLELISM if it persists."
    state.stop!
    return 3
  end

  threads = 0
  Thread.unsafe_each { threads += 1 }
  if threads <= 2
    STDERR.puts "FAIL: #{threads} thread(s) — `multi_mutator_threads?` is false, " \
                "so the guard under test is unreachable. Build with " \
                "-Dpreview_mt -Dexecution_context."
    state.stop!
    return 3
  end

  target = spinner
  unless target
    STDERR.puts "FAIL: spinner fiber never published itself."
    state.stop!
    return 3
  end

  # The stale record: where this fiber's SP was at its last park, which is well
  # above where its thread is spinning now. The wipe band hangs below it, over
  # frames that are live.
  stale_top = target.@context.stack_top.address
  HEAP.scrub_force_parked = target if manufacture

  collects = manufacture ? STALE_COLLECTS : REAL_COLLECTS
  if arg = ARGV.find(&.starts_with?("--collects="))
    collects = arg.split("=", 2)[1].to_i
  end
  collects.times do
    # Outside STW: the /proc tid table backs the audit's view of signal-exempt
    # threads and refreshing it allocates. EC workers spawn lazily, so this has
    # to happen every round, not once up front.
    {% if flag?(:linux) %}
      Gcry::Platform.audit_refresh_tids
    {% end %}
    GC.collect
  end

  scrubs = HEAP.fiber_scrub_foreign_sp_scrubs
  overlaps = HEAP.fiber_scrub_live_frame_overlaps
  skips = HEAP.fiber_scrub_midswap_skips
  running_sp = HEAP.fiber_scrub_running_foreign_sp

  # Print before releasing the spinner: under `stale-off` the wipe has already
  # zeroed a return address in those frames, so unwinding is expected to kill
  # this process and the parent still needs the counters.
  puts "counters mode=#{mode} threads=#{threads} runs=#{HEAP.fiber_scrub_runs} " \
       "scrubs=#{scrubs} overlaps=#{overlaps} midswap_skips=#{skips} " \
       "running_sp=#{running_sp} stale_top=0x#{stale_top.to_s(16)}"
  STDOUT.flush

  HEAP.scrub_force_parked = nil
  state.stop!

  until state.done?
    Fiber.yield
  end

  bad = state.bad
  puts "canaries mode=#{mode} mismatches=#{bad}"
  STDOUT.flush
  bad == 0 ? 0 : 2
end

# ── Child mode ───────────────────────────────────────────────────────────────
if arg = ARGV.find(&.starts_with?("--mode="))
  mode = arg.split("=", 2)[1]
  unless MODES.includes?(mode)
    STDERR.puts "unknown --mode=#{mode} (expected: #{MODES.join(", ")})"
    exit 64
  end
  exit run_child(mode)
end

# ── Parent mode ──────────────────────────────────────────────────────────────
self_path = Process.executable_path || "bin/scrub_midswap"

record = {} of String => Hash(String, String)
verdicts = {} of String => String

puts "=== Parked-fiber scrub: the mid-swap window ==="
puts "one spinning fiber held #{SPIN_DEPTH} frames below its recorded stack_top,"
puts "EC parallelism #{PARALLELISM}, #{STALE_COLLECTS} collection(s) once the state is manufactured"
puts "(#{REAL_COLLECTS} for the control), each scenario a child process"
puts ""

retries = {} of String => Int32

MODES.each do |mode|
  attempt = 0
  captured = IO::Memory.new
  status = nil.as(Process::Status?)
  fields = {} of String => String

  loop do
    attempt += 1
    captured = IO::Memory.new
    process = Process.new(self_path, ["--mode=#{mode}"],
      output: captured, error: Process::Redirect::Inherit)

    # A killed child is a verdict, not an outage: `stale-off` runs on with its
    # own frames zeroed, so it can hang instead of dying. Never let that stall
    # the harness.
    reaped = Channel(Process::Status).new(1)
    spawn { reaped.send(process.wait) }
    status = nil
    select
    when st = reaped.receive
      status = st
    when timeout CHILD_TIMEOUT_SECONDS.seconds
      process.signal(:kill)
      reaped.receive
    end

    fields = {} of String => String
    captured.to_s.each_line do |line|
      next unless line.starts_with?("counters ") || line.starts_with?("canaries ")
      line.split(' ').each do |tok|
        k, _, v = tok.partition('=')
        fields[k] = v unless v.empty?
      end
    end

    # A child that hung *before* printing its counters never reached the scrub,
    # so it says nothing about the guard. That was the STW libc-under-suspension
    # hang (`bench/stw_startup_hang.cr`): this harness parks a fiber on a worker
    # and collects immediately, which is exactly the shape that tripped it. Fixed,
    # and 0 retries in 15 runs since. Retry rather than fail — and say how often,
    # so a return of it is visible instead of absorbed.
    startup_hang = status.nil? && fields.empty?
    if startup_hang && attempt < HANG_RETRIES
      retries[mode] = attempt
      next
    end
    break
  end

  record[mode] = fields

  verdicts[mode] =
    if status.nil?
      "CORRUPT (hang, killed at #{CHILD_TIMEOUT_SECONDS}s)"
    elsif status.success?
      "clean"
    elsif status.normal_exit?
      case status.exit_code
      when 2 then "CORRUPT (canary)"
      when 3 then "UNMET (shape)"
      else        "CORRUPT (exit #{status.exit_code})"
      end
    else
      "CORRUPT (#{status.exit_signal})"
    end

  note = (r = retries[mode]?) ? "  [#{r} startup-hang retry(ies)]" : ""
  puts "  %-10s %-22s scrubs=%-4s overlaps=%-4s midswap_skips=%-4s running_sp=%-5s canary_bad=%s%s" % [
    mode, verdicts[mode],
    fields["scrubs"]? || "-", fields["overlaps"]? || "-",
    fields["midswap_skips"]? || "-", fields["running_sp"]? || "-",
    fields["mismatches"]? || "-", note,
  ]
end
puts ""

def num(record, mode, key) : Int64
  (record[mode]?.try &.[key]?).try(&.to_i64?) || -1_i64
end

failures = [] of String

MODES.each do |mode|
  failures << "#{mode}: the shape under test was not reached — see its stderr" if verdicts[mode] == "UNMET (shape)"
end

# 1. Positive control. The manufactured state *must* break with the guard off,
#    or this workload cannot detect the wipe landing on live frames and the
#    guarded run below proves nothing.
if verdicts["stale-off"] == "clean"
  failures << "stale-off (guard off) came back clean — no positive control, so " \
              "the guarded result says nothing about the guard"
end
if num(record, "stale-off", "overlaps") == 0
  failures << "stale-off (guard off) counted 0 live-frame overlaps — the probe " \
              "did not see the wipe cross the suspended SP it was aimed at"
end

# 2. The guard must be observed *doing* something, and the fiber must survive.
#    A zero here with a clean verdict is the unreadable green: it cannot be told
#    apart from a run where the state never occurred.
if num(record, "stale-on", "midswap_skips") <= 0
  failures << "stale-on (guard on) counted 0 mid-swap skips — the guard never " \
              "fired, so its clean result is not evidence about the guard"
end
if verdicts["stale-on"] != "clean"
  failures << "stale-on (guard on) corrupted (#{verdicts["stale-on"]}) — the " \
              "guard did not protect a stack a thread was still running on"
end

if failures.empty?
  real_skips = num(record, "real", "midswap_skips")
  real_running = num(record, "real", "running_sp")
  puts "The guard is load-bearing: with it off the manufactured stale `stack_top`"
  puts "put the wipe over live frames (#{record["stale-off"]?.try &.["overlaps"]? || "?"} overlaps, #{verdicts["stale-off"]}); with it on the same"
  puts "state was skipped #{record["stale-on"]?.try &.["midswap_skips"]? || "?"} time(s) and the fiber's canaries survived."
  puts ""
  puts "The `real` row is a control, not a rate: #{real_skips} skip(s) and #{real_running} foreign SP"
  puts "sighting(s) over #{record["real"]?.try &.["runs"]? || "?"} scrub runs only shows that the same binary leaves the"
  puts "counters at zero until the state is manufactured. This workload's spinner"
  puts "never yields, so it cannot produce the genuine window at all — bounding"
  puts "that rate is `bench/scrub_audit.cr`'s job (0 over 300, and 0 over 3000"
  puts "across 128 tightly-yielding fibers), and it remains the number to cite."
  puts ""
  puts "Why the genuine window is not the same risk: Crystal's context switch"
  puts "records `stack_top` before it clears the running flag, so while that"
  puts "window is open `stack_top == sp` and the wipe stays strictly below the SP."
  puts "The guard covers the case where that ordering does not hold — a different"
  puts "ABI, a mid-swap change, a spill added above the recorded SP — which is"
  puts "measured here to be the difference between clean and dead."
  puts "PASS"
else
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
