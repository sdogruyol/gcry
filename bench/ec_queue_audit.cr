# Would the collector notice a corrupt run-queue slot before the scheduler dies
# on it?
#
# The 2026-08-10 soak died in `Parallel::Scheduler#quick_dequeue?` on
# `0x7f1700000149` — a heap pointer with its low bytes overwritten — 1h24m in.
# The dequeue is where the damage *surfaces*. The write that did it happened an
# unknown time earlier, and at one crash per five hours the gap between the two
# cannot be bisected: a candidate fix and a quiet run look identical inside a
# release cycle.
#
# `GCRY_EC_QUEUE_AUDIT=1` walks the two structures that dequeue reads — each
# scheduler's `Runnables` ring between head and tail, and the context's
# `GlobalQueue` list — inside the stopped world, where they are quiescent, and
# names the first *collection* at which a slot stops being a live Fiber. That
# moves the report from "an hour after the write, in the consumer" to "the next
# collection after the write, with the slot index and the value in it".
#
# Four arms:
#
#   engagement  with real fiber traffic the audit must actually walk both
#               structures — `ec_queue_audit_ring_slots > 0` **and**
#               `ec_queue_audit_list_slots > 0`. A walk that covers nothing
#               reports no faults either, and would pass every other arm here.
#
#   detection   a slot corrupted on purpose must be reported, and the report must
#               name it. **This is the gate.** The corruption is manufactured
#               where it is safe to manufacture: the context has one worker, that
#               worker is held inside a fiber that never yields, so nothing
#               dequeues while the harness pokes the value, collects, and puts
#               the original back.
#
#   recovery    after the value is restored the queue drains normally and every
#               spawned fiber runs. What is being checked is that the arm above
#               tested the collector rather than breaking the process — a
#               "detection" that leaves the context dead proves nothing about a
#               live one.
#
#   --control   the same run with the audit off: the slot counters stay 0 and the
#               deliberate corruption goes unreported. This is what shows the
#               knob is the thing doing the work, not something else in the
#               collection path.
#
#   crystal build -Dgc_none bench/ec_queue_audit.cr -o bin/ec_queue_audit
#   GCRY_EC_QUEUE_AUDIT=1 bin/ec_queue_audit
#   bin/ec_queue_audit --control

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "ec_queue_audit requires -Dgc_none (gcry as process GC)" %}
{% end %}

HEAP = Gcry.default_heap.not_nil!

# The address the soak died on, reused as the poison so the harness and the
# crash report read the same.
POISON = 0x7f1700000149_u64

CHURN_FIBERS = 64
QUEUED       = 24

# A heap-allocated object that is not a Fiber. A String *literal* would not do:
# it lives in the program image, so `is_heap_ptr` rejects it and the poison would
# be caught for the wrong reason.
class Decoy
  def initialize
    @payload = Bytes.new(32, 0x7_u8)
  end
end

DECOY_ROOT = [] of Decoy

def run(control : Bool) : Int32
  {% unless Thread.instance_vars.any? { |v| v.name == "execution_context" } %}
    puts
    puts "SKIP — this compiler does not declare Thread.@execution_context, so there"
    puts "are no execution-context queues to audit (pre-EC scheduler, e.g. -Dpreview_mt)."
    return 0
  {% else %}
    failures = [] of String
    audit_on = HEAP.ec_queue_audit
    puts "audit: #{audit_on ? "on (GCRY_EC_QUEUE_AUDIT=1)" : "off"}"

    # ── Arm 1: engagement ────────────────────────────────────────────────────
    # Fibers spawned from *inside* the context land on the running scheduler's
    # ring; fibers spawned from outside it go to the global queue. Both, so both
    # walks have something to walk.
    churn = Fiber::ExecutionContext::Parallel.new("gcry-ec-queue-churn", 4)
    done = Channel(Nil).new(CHURN_FIBERS)
    CHURN_FIBERS.times do
      churn.spawn do
        churn.spawn { done.send(nil) }
        Fiber.yield
      end
    end
    ring_seen = 0_u64
    list_seen = 0_u64
    8.times do
      GC.collect
      ring_seen += HEAP.ec_queue_audit_ring_slots
      list_seen += HEAP.ec_queue_audit_list_slots
    end
    CHURN_FIBERS.times { done.receive }
    puts "slots walked over 8 collections: ring=#{ring_seen} list=#{list_seen}"

    if audit_on
      failures << "the ring walk never saw a slot, so nothing here tests it" if ring_seen == 0
    else
      failures << "the audit is off but it walked #{ring_seen + list_seen} slots" if ring_seen + list_seen > 0
    end

    # ── Arm 2: detection ─────────────────────────────────────────────────────
    # One worker, and it is held inside a fiber that never yields, so nothing
    # dequeues between the poke and the restore.
    ec = Fiber::ExecutionContext::Parallel.new("gcry-ec-queue-audit", 1)
    held = Channel(Nil).new
    release = Atomic(Int32).new(0)
    ec.spawn do
      held.send(nil)
      while release.get == 0
      end
    end
    held.receive

    # Queued behind the blocker: spawned from this thread, so they land on the
    # context's global queue.
    ran = Channel(Nil).new(QUEUED)
    QUEUED.times { ec.spawn { ran.send(nil) } }

    queued = ec.@global_queue.@list.size
    puts "fibers parked on the global queue behind the blocker: #{queued}"
    failures << "nothing queued, so the corruption has nowhere to go" if queued == 0

    # A clean collection over that populated list, before anything is poisoned:
    # it is both where the global-queue walk is reliably exercised (arm 1's churn
    # context drains too fast to count on) and a check that a healthy list of 24
    # fibers reports nothing.
    clean_faults = HEAP.ec_queue_audit_faults
    GC.collect
    list_seen += HEAP.ec_queue_audit_list_slots
    puts "slots walked over the parked list: #{HEAP.ec_queue_audit_list_slots}, " \
         "faults #{HEAP.ec_queue_audit_faults - clean_faults}"
    if HEAP.ec_queue_audit_faults != clean_faults
      failures << "a healthy global queue of #{queued} fibers reported " \
                  "#{HEAP.ec_queue_audit_faults - clean_faults} faults"
    end

    slot = pointerof(ec.@global_queue.@list.@head).as(UInt64*)
    saved = slot.value

    # Two poisons, because they fail different halves of the test. The first is
    # the address the soak died on: not in the heap at all, so `is_heap_ptr`
    # rejects it. The second is a *live heap object of the wrong type* — the
    # shape a partially overwritten pointer usually has, since the low bytes it
    # keeps often still land inside a real allocation — and only the type_id
    # check rejects that one.
    decoy = Decoy.new
    DECOY_ROOT << decoy
    poisons = [{"outside the heap", POISON}, {"a live non-Fiber object", decoy.object_id}]

    poisons.each do |(label, bits)|
      before = HEAP.ec_queue_audit_faults
      slot.value = bits
      GC.collect
      after = HEAP.ec_queue_audit_faults
      slot.value = saved
      puts "faults: #{before} → #{after} (poison 0x#{bits.to_s(16)}, #{label})"

      if audit_on
        if after == before
          failures << "a queue head holding 0x#{bits.to_s(16)} (#{label}) was collected over without " \
                      "a word — the audit did not look, or its test accepts a value that is not a " \
                      "live Fiber"
        elsif HEAP.ec_queue_audit_last_fault != bits
          # A fault was raised, but not for the value that was planted. That is
          # what a too-weak test looks like: the head is accepted, the walk
          # follows a `list_next` read out of whatever the head really points at,
          # and *that* garbage is what gets reported — one slot too late, and with
          # a value nobody can trace back to a write.
          failures << "the fault named 0x#{HEAP.ec_queue_audit_last_fault.to_s(16)}, not the planted " \
                      "0x#{bits.to_s(16)} (#{label}) — the planted value passed the test and the walk " \
                      "tripped on what came after it"
        end
      else
        unless after == before
          failures << "the audit is off but a fault was still counted (#{label})"
        end
      end
    end
    # The second poison only tests what it claims to if the decoy really was a
    # live heap object while the collection read the slot.
    unless HEAP.live?(Pointer(Void).new(decoy.object_id))
      failures << "the decoy was not a live heap object, so the second poison was rejected for " \
                  "being outside the heap rather than for not being a Fiber"
    end

    if audit_on
      failures << "the global-queue walk never saw a slot, so nothing here tests it" if list_seen == 0
    elsif list_seen > 0
      failures << "the audit is off but the global-queue walk ran"
    end

    # ── Arm 3: recovery ──────────────────────────────────────────────────────
    release.set(1)
    QUEUED.times { ran.receive }
    GC.collect
    puts "all #{QUEUED} queued fibers ran after the value was restored"

    if failures.empty?
      puts
      if control
        puts "ok — with the audit off nothing is walked and the corruption goes unreported, " \
             "so the other run's detection is attributable to the knob"
      else
        puts "ok — both walks engaged, a corrupt queue head was reported at the next collection, " \
             "and the context drained normally afterwards"
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
puts "=== execution-context queue audit ==="
puts "mode: #{control ? "control (audit off; nothing walked, nothing reported)" : "hold (audit on; the corrupt slot must be named)"}"
exit run(control)
