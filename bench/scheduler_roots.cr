# Does the collector actually pin the Parallel execution context's structures?
#
# `collect_scan.cr#scan_thread_roots` names them one by one — global queue,
# event loop, stack pool, the scheduler array, and per scheduler its runnables
# and main fiber — because relying on the conservative scan of the `Thread` body
# to reach them was measured insufficient once already (Kemal EC4 SEGV @ …0008).
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
# Two arms, and only one of them is the gate:
#
#   mechanism   with a Parallel EC up, a collection must pin at least the named
#               structures: 4 per context + 3 per scheduler. Measured as a
#               *delta* across a collection taken before the context exists, so
#               the ambient Thread-level pins (`@scheduler`, `@execution_context`)
#               cannot carry the arm on their own. **This is the gate.**
#
#   end-to-end  fibers parked in that context, whose addresses this harness holds
#               only obfuscated, must survive the collection. Worth having, but
#               it does **not** discriminate on its own: the conservative scan of
#               the Thread body and of the worker stacks can reach the same
#               fibers whether or not the pin block compiled in. A green here is
#               not evidence that the pins ran — the delta above is.
#
#   --control   no Parallel EC is ever created, and the delta across two
#               collections must be 0. This is what stops the gate from being
#               vacuous in the other direction: if the counter drifted on its own
#               (ambient pins counted twice, a stale accumulator not reset per
#               collect) the mechanism arm would pass without a context.
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
      expected = 4 + 3 * schedulers

      GC.collect
      after = HEAP.ec_root_pins
      delta = after.to_i64 - before.to_i64
      puts "schedulers: #{schedulers} (asked for #{WORKERS})"
      puts "pins with the context up: #{after} (delta #{delta}, at least #{expected} expected)"

      # ── Arm 1: the mechanism ─────────────────────────────────────────────────
      if delta < expected
        failures << "the Parallel pin block contributed #{delta} pins where #{expected} are named " \
                    "in scan_thread_roots — the block did not run (macro gate compiled it out, or " \
                    "the context was not on Fiber::ExecutionContext.unsafe_each)"
      end

      # ── Arm 2: end to end ────────────────────────────────────────────────────
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
