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
def run(control : Bool) : Int32
  {% unless Thread.instance_vars.any? { |v| v.name == "execution_context" } %}
    puts
    puts "SKIP — this compiler does not declare Thread.@execution_context, so there"
    puts "is no execution context to pin (pre-EC scheduler, e.g. -Dpreview_mt)."
    return 0
  {% else %}
    failures = [] of String

    # Baseline: a collection with no Parallel EC in existence. Whatever the
    # ambient Thread-level pins cost, they cost it here too, so the delta below
    # is the Parallel block's own contribution and nothing else.
    GC.collect
    before = HEAP.ec_root_pins
    puts "pins on a collection before any Parallel EC: #{before}"

    if control
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
      if control
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
puts "=== Parallel execution-context root pins ==="
puts "mode: #{control ? "control (no Parallel EC; the counter must not move)" : "hold (Parallel EC up; pins must be counted)"}"
exit run(control)
