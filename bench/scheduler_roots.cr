# Does the collector actually pin the Parallel execution context's structures?
#
# `collect_scan.cr#scan_thread_roots` pins them explicitly — every pointer-bearing
# ivar of the context and of each of its schedulers, derived from `instance_vars`
# rather than from a list of names — because relying on the conservative scan of
# the `Thread` body to reach them was measured insufficient once already
# (Kemal EC4 SEGV @ …0008).
#
# The whole block sits behind a macro gate on `Thread.@execution_context`. That
# gate is right for what it was written for — Crystal 1.21.0 release declares the
# ivar, `-Dpreview_mt` selects the pre-EC scheduler where there is nothing to pin
# — but a gate that compiles a root scan out is indistinguishable, from outside
# the collector, from one that runs and finds nothing. That is the same shape as
# Darwin's empty `each_thread_greg` stub (v0.19.0) and Linux aarch64's
# `UCONTEXT_NGREGS = 0`: a root the caller assumed was covered, and no counter
# that could say otherwise. `ec_root_pins` is that counter.
#
# Three arms, and the first two are the gate:
#
#   mechanism   with a Parallel EC up, a collection must pin at least one slot
#               per pointer-bearing ivar — of the context, and of each of its
#               schedulers. The expectation is computed below from
#               `instance_vars`, the same place the collector's `pin_ec_ivars`
#               derives the pins from, so upstream adding a queue moves both
#               sides together instead of leaving a hardcoded "4 per context +
#               3 per scheduler" behind. Measured as a *delta* across a
#               collection taken before the context exists, so the ambient
#               Thread-level pins (`@scheduler`, `@execution_context`) cannot
#               carry the arm on their own. **This is the gate.**
#
#   complete    `ec_root_unpinned_ivars` must be 0. The arm above proves the pins
#               ran and reached every ivar the block *can* cover; this one proves
#               there is none it cannot. Wide ivars are covered — a `Proc`, a
#               `Tuple`, `(Fiber::ExecutionContext | Nil)` get every word of the
#               slot marked rather than a guessed one — so what is left is the
#               shape with no sound answer: pointer-bearing and *narrower* than a
#               pointer. Zero on Crystal 1.21.0, and counted rather than skipped
#               so it cannot arrive quietly. This is the half that answers "is the
#               list complete", which `ec_root_pins` alone could not.
#
#   end-to-end  fibers parked in that context, whose addresses this harness holds
#               only obfuscated, must survive the collection. Worth having, but
#               it does **not** discriminate on its own: the conservative scan of
#               the Thread body and of the worker stacks can reach the same
#               fibers whether or not the pin block compiled in. A green here is
#               not evidence that the pins ran — the delta above is.
#
#   isolated    the same expectation for `Fiber::ExecutionContext::Isolated`,
#               which until 2026-08-15 got **no explicit pin at all** — the block
#               named `Parallel` and nothing else, so an Isolated context's
#               `@main_fiber`, `@thread`, `@wait_list` and the user's `@func`
#               closure were left to the conservative body scan the block exists
#               because it does not trust. The set of context types is derived
#               from `Fiber::ExecutionContext.includers` now, so this arm also
#               fails if a type is added upstream and the collector's dispatch
#               does not pick it up.
#
#   --resize    `Parallel#resize` replaces `@schedulers` outright, and a shrink
#               drops the overflow schedulers from it after telling them to
#               shut down — cooperatively, so "won't stop until their current
#               fiber tries to switch". During that window a Scheduler is still
#               being run by a live thread while the context no longer lists it,
#               and the pin block above walks `ec.@schedulers`, i.e. the *new*
#               array, so the removed schedulers lose every *named* pin they had:
#               measured 53 → 29 pins, exactly 3 × (1 object + 7 ivars). That
#               quantity, derived from `instance_vars` on both sides, is what
#               this arm gates on. Nothing is swept in that window — but the
#               measurement in FINDINGS shows survival does not depend on any
#               named pin either: delete `thread.@scheduler`'s and the removed
#               schedulers still live, because the conservative scan of the
#               `Thread` body and of the running worker's stack reaches them.
#               That is the coverage the pin block exists because it does not
#               trust (Kemal EC4 SEGV @ …0008), so what this arm records is a
#               window where EC coverage is conservative-only. Non-vacuity is
#               asserted: one non-yielding fiber per worker holds the
#               cooperative shutdown open, and the arm fails if no removed
#               scheduler still has a live reader. Nothing in this tree shrinks
#               a context today — this is a latent path put under a gate before
#               something reaches it.
#
#   --control   no execution context beyond the default is ever created, and the
#               delta across two collections must be 0. This is what stops the
#               gate from being vacuous in the other direction: if the counter
#               drifted on its own (ambient pins counted twice, a stale
#               accumulator not reset per collect) the mechanism arm would pass
#               without a context.
#
#   crystal build -Dgc_none bench/scheduler_roots.cr -o bin/scheduler_roots
#   bin/scheduler_roots
#   bin/scheduler_roots --control
#   bin/scheduler_roots --resize

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "scheduler_roots requires -Dgc_none (gcry as process GC)" %}
{% end %}

HEAP = Gcry.default_heap.not_nil!

WORKERS =  4
FIBERS  = 16
# Same trick as bench/greg_roots.cr: `addr ^ KEY` is not itself a heap pointer,
# so the table this harness keeps cannot root the fibers it is testing.
KEY = 0x9E3779B97F4A7C15_u64

# How many slots the collector's `pin_ec_ivars` visits for one object of this
# type: one per `Reference` ivar, and one per pointer-sized word of any other
# ivar that can hold a pointer. Deriving the expectation here rather than writing
# a number down is the point of the arm — both sides read the same
# `instance_vars`, so upstream cannot add a structure that only one of them knows
# about. (`@next : (Fiber::ExecutionContext | Nil)` is two words, not one, which
# is also why the collector marks the whole slot instead of picking a word.)
macro pin_slots(type)
  begin
    slots = 0
    {% for ivar in type.resolve.instance_vars %}
      {% ty = ivar.type %}
      {% if ty < Reference %}
        slots += 1
      {% elsif ty.has_inner_pointers? %}
        slots += sizeof({{ty}}) // sizeof(Pointer(Void))
      {% end %}
    {% end %}
    slots
  end
end

# The body lives in a method for a macro reason, not a style one:
# `TypeNode#instance_vars` cannot be called in the top-level scope, and the guard
# has to be a macro rather than a runtime `if` — on a compiler without execution
# contexts `Fiber::ExecutionContext::Parallel` does not exist, so a reference to
# it would fail to compile rather than be skipped.
# The ambient pin count is not constant at process start — it **settles**, and
# the reason is one thread: gcry's `gc-idle`, which the *first collection*
# starts with `Thread.new` (`IdleRelease.ensure_started`). A thread joins
# `Thread.unsafe_each` — and so the scan that pins its `@scheduler` and
# `@execution_context` — only when it first runs its own `Thread#start`. Until
# the OS schedules it the count reads 2 low: 23 → 25 on an idle x86_64 host in
# 1 run in 25 (2026-08-15), 25 → 27 on the macOS runner in 2 CI runs of the
# night of 2026-09-25, whose audit lines show the same `2 listed` → `3 listed`.
#
# Reading the baseline too early did two things, and both were wrong in the
# gate's favour or against it: `--control` went red at `delta: 2`, and the
# hold arm's `delta = after - before` came out **2 too high**, discounting the
# threshold it is supposed to clear. The first fix waited for two equal
# readings, which a loaded runner defeats: back-to-back collections take
# microseconds, the unscheduled thread takes as long as it takes, so 25 = 25
# "settled" and 27 came one collection later. So wait for the cause — every
# helper thread listed — and only then for the count to stop moving.
HELPER_THREADS = {"gc-idle", "SYSMON"}

def helper_listed?(name : String) : Bool
  Thread.unsafe_each { |thread| return true if thread.name == name }
  false
end

def settled_pins : UInt64
  GC.collect
  deadline = Time.instant + 10.seconds
  HELPER_THREADS.each do |name|
    # `gc-idle` exists only while idle release is armed; SYSMON only on a
    # runtime with execution contexts, which `run` has already required.
    next if name == "gc-idle" && !Gcry::IdleRelease.armed?
    until helper_listed?(name)
      abort "settled_pins: #{name} was not listed within 10 s" if Time.instant > deadline
      sleep 1.millisecond
    end
  end
  prev = HEAP.ec_root_pins
  8.times do
    GC.collect
    now = HEAP.ec_root_pins
    return now if now == prev
    prev = now
  end
  prev
end

def run(control : Bool, resize_arm : Bool = false) : Int32
  {% unless Thread.instance_vars.any? { |v| v.name == "execution_context" } %}
    puts
    puts "SKIP — this compiler does not declare Thread.@execution_context, so there"
    puts "is no execution context to pin (pre-EC scheduler, e.g. -Dpreview_mt)."
    return 0
  {% else %}
    failures = [] of String

    # Baseline: a settled collection with no Parallel EC in existence. Whatever
    # the ambient Thread-level pins cost, they cost it here too, so the delta
    # below is the Parallel block's own contribution and nothing else — provided
    # the ambient number has stopped moving, which is what `settled_pins` is for.
    before = settled_pins
    puts "pins on a collection before any Parallel EC: #{before}"

    if resize_arm
      ec = Fiber::ExecutionContext::Parallel.new("gcry-scheduler-roots-resize", WORKERS)
      # Busy fibers, not parked ones. A shrink tells the overflow schedulers to
      # shut down, but "the actual shutdown is cooperative, so running
      # schedulers won't stop until their current fiber tries to switch to
      # another fiber" — so a parked workload lets every removed worker stop
      # before a collection can look, which is exactly what the first version
      # of this arm measured (0 of 3 removed schedulers still had a reader).
      # One non-yielding fiber per worker holds the window open instead.
      running = Atomic(Int32).new(0)
      release = Atomic(Int32).new(0)
      WORKERS.times do
        ec.spawn do
          running.add(1)
          while release.get == 0
            # No yield, no allocation: the point is a fiber that never offers
            # its worker a switch point.
          end
        end
      end
      while running.get < WORKERS
        Fiber.yield
      end

      grown = ec.@schedulers.size
      GC.collect
      pins_grown = HEAP.ec_root_pins.to_i64 - before.to_i64
      puts "schedulers before the shrink: #{grown} (asked for #{WORKERS}), pins delta #{pins_grown}"

      if grown < 2
        failures << "the context came up with #{grown} scheduler(s), so there is no overflow " \
                    "for a shrink to remove and this arm would pass without testing anything"
      end

      # Identities of what the shrink is about to drop, held obfuscated so this
      # frame is not what keeps them alive — same device as `hidden` above.
      # `@runnables` is the one that matters: it is the queue a still-running
      # worker dequeues from, and the slot the 2026-08-10 SEGV died on.
      doomed = [] of Tuple(Int32, UInt64, UInt64, UInt64)
      ec.@schedulers.each_with_index do |sched, i|
        next if i == 0
        doomed << {i, sched.object_id ^ KEY, sched.@runnables.object_id ^ KEY,
                   sched.@main_fiber.object_id ^ KEY}
      end

      # Shrink. The removed schedulers leave `@schedulers`, are told to shut
      # down, and keep running until their current fiber switches.
      ec.resize(1)
      shrunk = ec.@schedulers.size

      GC.collect
      GC.collect
      pins_shrunk = HEAP.ec_root_pins.to_i64 - before.to_i64
      puts "schedulers after resize(1):   #{shrunk}, pins delta #{pins_shrunk}"

      unless shrunk == 1
        failures << "resize(1) left #{shrunk} schedulers on the context, so the shrink this arm " \
                    "measures did not happen"
      end

      # The discriminating assertion. Every removed scheduler costs one pin for
      # the object plus one per pointer-bearing ivar, derived from the same
      # `instance_vars` the collector pins from — so this is the *quantity* of
      # named coverage a shrink drops, and it moves with upstream rather than
      # being written down. Measured here: 53 -> 29, i.e. 24 = 3 x (1 + 7).
      removed = grown - shrunk
      expected_loss = removed * (1 + pin_slots(Fiber::ExecutionContext::Parallel::Scheduler))
      actual_loss = pins_grown - pins_shrunk
      puts "named pins the shrink dropped: #{actual_loss} (#{removed} schedulers x " \
           "(1 + #{pin_slots(Fiber::ExecutionContext::Parallel::Scheduler)}) = #{expected_loss})"
      unless actual_loss == expected_loss
        failures << "the shrink dropped #{actual_loss} named pins where #{expected_loss} are " \
                    "derivable from the removed schedulers' ivars — either the pin block no " \
                    "longer walks ec.@schedulers, or a shrink no longer removes them from it, " \
                    "and this arm's reading of what the window costs is stale either way"
      end

      # Which removed schedulers is a live thread still running? Those are the
      # ones with a reader, and the ones sweeping would be a defect for. A
      # removed scheduler whose thread has finished is genuinely garbage and
      # collecting it is correct — asserting on it would make this arm wrong in
      # the other direction.
      #
      # These survival checks do **not** discriminate, and the measurement that
      # says so is in FINDINGS: with `thread.@scheduler`'s pin deleted from
      # `scan_thread_roots`, all three removed schedulers and their queues
      # still survive. What covers them in this window is the conservative scan
      # of the `Thread` body and of the running worker's own stack — which is
      # the coverage the pin block exists because it does not trust. So a green
      # here says "nothing is lost today", not "something names them".
      still_run = [] of UInt64
      Thread.unsafe_each do |th|
        if s = th.@scheduler
          still_run << s.object_id
        end
      end

      checked = 0
      doomed.each do |(i, sched_x, runnables_x, main_x)|
        sched_addr = sched_x ^ KEY
        next unless still_run.includes?(sched_addr)
        checked += 1
        unless HEAP.live?(Pointer(Void).new(sched_addr))
          failures << "scheduler[#{i}] was swept while a live thread's @scheduler still pointed " \
                      "at it — the shrink removed it from ec.@schedulers and nothing else named it"
        end
        unless HEAP.live?(Pointer(Void).new(runnables_x ^ KEY))
          failures << "scheduler[#{i}].runnables was swept while a live thread still runs that " \
                      "scheduler — that is the queue a dequeue reads, and the shape of the " \
                      "2026-08-10 SEGV"
        end
        unless HEAP.live?(Pointer(Void).new(main_x ^ KEY))
          failures << "scheduler[#{i}].main_fiber was swept while a live thread still runs that " \
                      "scheduler"
        end
      end
      puts "removed schedulers a live thread still points at: #{checked}/#{doomed.size}"
      if checked == 0
        failures << "no removed scheduler still had a live thread pointing at it, so the shrink " \
                    "window this arm exists to measure was not open and a green result here " \
                    "would mean nothing — the busy fibers above are what hold it open"
      end

      release.set(1)
    elsif control
      GC.collect
      after = HEAP.ec_root_pins
      delta = after.to_i64 - before.to_i64
      puts "pins on a second such collection:            #{after}"
      puts "delta: #{delta}"

      unless delta == 0
        failures << "the pin count moved by #{delta} with no Parallel EC in the process — " \
                    "the counter is not measuring the Parallel block, so the gate arm proves nothing"
      end
    else
      ec = Fiber::ExecutionContext::Parallel.new("gcry-scheduler-roots", WORKERS)
      ready = Channel(Nil).new(FIBERS)
      park = Channel(Nil).new

      # Park FIBERS fibers inside the context. Once blocked on `park`, their only
      # roots are the ones the collector is supposed to find: the scheduler graph
      # and the event loop. The harness keeps their addresses obfuscated so it is
      # not itself what keeps them alive.
      hidden = [] of UInt64
      FIBERS.times do
        f = ec.spawn do
          ready.send(nil)
          park.receive
        end
        hidden << (f.object_id ^ KEY)
      end
      FIBERS.times { ready.receive }

      schedulers = ec.@schedulers.size
      # One slot per pointer-bearing ivar, plus the context object itself and
      # each scheduler object. Derived from the types, not written down: the
      # collector's `pin_ec_ivars` classifies the same way, so a queue added
      # upstream raises this number and the pin that satisfies it together.
      per_context = pin_slots(Fiber::ExecutionContext::Parallel)
      per_scheduler = pin_slots(Fiber::ExecutionContext::Parallel::Scheduler)
      expected = 1 + per_context + schedulers * (1 + per_scheduler)

      GC.collect
      after = HEAP.ec_root_pins
      delta = after.to_i64 - before.to_i64
      puts "schedulers: #{schedulers} (asked for #{WORKERS})"
      puts "pin slots per object: context #{per_context}, scheduler #{per_scheduler}"
      puts "pins with the context up: #{after} (delta #{delta}, at least #{expected} expected)"
      puts "ivars too wide to pin: #{HEAP.ec_root_unpinned_ivars}"

      # ── Arm 1: the mechanism ─────────────────────────────────────────────────
      if delta < expected
        failures << "the Parallel pin block contributed #{delta} pins where #{expected} pointer " \
                    "ivars are reachable from the context — the block did not run (macro gate " \
                    "compiled it out, or the context was not on " \
                    "Fiber::ExecutionContext.unsafe_each), or it no longer covers every ivar"
      end

      # ── Arm 2: is the list complete ──────────────────────────────────────────
      if HEAP.ec_root_unpinned_ivars > 0
        failures << "#{HEAP.ec_root_unpinned_ivars} pointer-bearing ivars of the Parallel EC " \
                    "structures are narrower than a pointer, so pin_ec_ivars counted them instead " \
                    "of marking them — whatever lives only behind one of those has no explicit root"
      end

      # ── Arm 3: Isolated ──────────────────────────────────────────────────────
      # A second context type, and the one the block used to skip entirely.
      iso_before = HEAP.ec_root_pins
      iso_ran = Channel(Nil).new
      iso_hold = Atomic(Int32).new(0)
      iso = Fiber::ExecutionContext::Isolated.new("gcry-isolated-roots") do
        iso_ran.send(nil)
        while iso_hold.get == 0
        end
      end
      iso_ran.receive

      GC.collect
      iso_delta = HEAP.ec_root_pins.to_i64 - iso_before.to_i64
      iso_expected = pin_slots(Fiber::ExecutionContext::Isolated)
      puts "Isolated: #{iso_delta} further pins with it up (at least #{iso_expected} expected " \
           "for its own ivars)"
      if iso_delta < iso_expected
        failures << "an Isolated context contributed #{iso_delta} pins where #{iso_expected} " \
                    "pointer-ivar slots are reachable from it — the collector's context dispatch " \
                    "does not cover Fiber::ExecutionContext::Isolated"
      end
      iso_hold.set(1)

      # ── Arm 4: end to end ────────────────────────────────────────────────────
      swept = 0
      hidden.each do |h|
        swept += 1 unless HEAP.live?(Pointer(Void).new(h ^ KEY))
      end
      puts "parked fibers still live: #{FIBERS - swept}/#{FIBERS}"
      if swept > 0
        failures << "#{swept} of #{FIBERS} fibers parked in the context were swept while the " \
                    "scheduler still reached them"
      end

      # The named structures themselves. Reached here through `ec`, which this
      # frame holds — so this checks that the sweep did not free them, not that
      # they were rooted independently. Cheap, and it fails loudly.
      named = [] of Tuple(String, UInt64)
      named << {"global_queue", ec.@global_queue.object_id}
      named << {"event_loop", ec.@event_loop.object_id}
      named << {"stack_pool", ec.@stack_pool.object_id}
      named << {"schedulers", ec.@schedulers.object_id}
      ec.@schedulers.each_with_index do |sched, i|
        named << {"scheduler[#{i}]", sched.object_id}
        named << {"scheduler[#{i}].runnables", sched.@runnables.object_id}
        named << {"scheduler[#{i}].main_fiber", sched.@main_fiber.object_id}
      end
      dead = named.reject { |(_, addr)| HEAP.live?(Pointer(Void).new(addr)) }
      puts "named structures live: #{named.size - dead.size}/#{named.size}"
      dead.each { |(label, _)| failures << "#{label} is not live after collection" }
    end

    if failures.empty?
      puts
      if resize_arm
        puts "ok — the shrink happened and nothing a live thread still runs was swept"
      elsif control
        puts "ok — the pin count is flat with no Parallel EC, so a non-zero delta in the " \
             "other arm is attributable to the context"
      else
        puts "ok — the Parallel block pinned its structures and nothing parked in the " \
             "context was swept. See the header: the delta is the gate, not the survival."
      end
      return 0
    else
      puts
      failures.each { |f| STDERR.puts "FAIL: #{f}" }
      return 1
    end
  {% end %}
end

control = ARGV.includes?("--control")
resize_arm = ARGV.includes?("--resize")
puts "=== Parallel execution-context root pins ==="
mode = if control
         "control (no Parallel EC; the counter must not move)"
       elsif resize_arm
         "resize (shrink 4 -> 1; a removed scheduler a thread still runs must survive)"
       else
         "hold (Parallel EC up; pins must be counted)"
       end
puts "mode: #{mode}"
exit run(control, resize_arm)
