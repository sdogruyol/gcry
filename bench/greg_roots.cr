# Does the collector scan a *suspended* thread's registers?
#
# `collect_scan.cr` asks `Platform.each_thread_greg` for them, because a
# reference can live only in a register: the compiler is free to keep an object
# pointer in a callee-saved register and never spill it, and a conservative scan
# of that thread's stack then sees nothing. On Darwin that call returned nothing
# at all — `each_thread_greg` was an empty stub next to a `thread_get_state`
# that already read SP and threw the rest away — so those objects were swept.
# Found 2026-08-11 on the fat app as a live String's tail overwritten in place;
# `bench/log/macos/2026-08-11-080733-acik-ec-isolation/FINDINGS.md`.
#
# Three arms, and only one of them is the gate:
#
#   mechanism   with a thread suspended, the register scan must yield candidates.
#               A platform that reports nothing and a platform whose registers
#               genuinely held nothing look identical from the outside; the
#               counter separates them. **This is the gate.** Measured against
#               the stub on Apple M2 Pro / Darwin 25.5.0 / Crystal 1.21.0:
#               28 candidates with the fix, 0 without, 5/5 either way.
#
#   end-to-end  the victim, whose only intended root is the worker's register,
#               must survive. Reads well and is worth keeping — but it does
#               **not** discriminate here, and saying so is the point: with
#               `each_thread_greg` stubbed out the victim still survived 5/5.
#               The reason is that "keep this pointer out of memory" is a codegen
#               outcome no source-level test can compel; LLVM leaves a copy of
#               `real` in the worker's own frame, and the conservative scan of
#               that stack finds it. Wiping the worker's dead frames first was
#               tried and changed nothing — the copy is in the live frame.
#               So a green here is not evidence the register path ran.
#
#   --control   the same setup with the worker holding nothing. The victim must
#               die. This is what stops the arm above from being vacuous in the
#               other direction: it confirms the harness itself is not retaining
#               the victim (`live?=false`, verified), so when the register *is*
#               the only root the survival is at least attributable to the
#               worker rather than to a leak in the test.
#
#   crystal build -Dgc_none bench/greg_roots.cr -o bin/greg_roots
#   bin/greg_roots
#   bin/greg_roots --control
#   bin/greg_roots --explain

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "greg_roots requires -Dgc_none (gcry as process GC)" %}
{% end %}

HEAP = Gcry.default_heap.not_nil!

VICTIM_SIZE =  96_u64
FILL        = 0xA5_u8
# Any odd constant works. The point is only that `addr ^ KEY` is not itself a
# heap pointer, so the copy that travels through memory into the worker cannot
# be found by a conservative scan.
KEY = 0x9E3779B97F4A7C15_u64

# Shared with the worker. A plain Int32 in memory would let LLVM hoist the load
# out of the spin loop; Atomic is what keeps the loop a loop.
class Gate
  def initialize
    @flag = Atomic(Int32).new(0)
  end

  def set : Nil
    @flag.set(1)
  end

  def get : Int32
    @flag.get
  end
end

# Allocate the victim and hand back only the obfuscated address. NoInline so the
# plaintext pointer dies with this frame rather than living on in the caller's.
@[NoInline]
def make_victim_hidden : UInt64
  ptr = GC.malloc(VICTIM_SIZE).as(UInt8*)
  i = 0_u64
  while i < VICTIM_SIZE
    ptr[i] = FILL
    i += 1
  end
  ptr.address ^ KEY
end

# Overwrite this thread's dead frames. `make_victim_hidden` returned, but the
# words it used are still on the stack, and the root scan is conservative: a
# stale copy of the victim pointer would keep it alive and turn this test green
# for the wrong reason.
@[NoInline]
def wipe_stack : Nil
  buf = uninitialized UInt8[65536]
  i = 0
  while i < 65536
    buf.to_unsafe[i] = 0_u8
    i += 1
  end
  # Keep the writes: without a use LLVM is entitled to drop the whole loop.
  Gcry::Trace.enabled? && puts(buf.to_unsafe[0])
end

# The worker's whole job. `real` is computed here, is live across the loop, and
# is used after it — which is what gives LLVM a reason to keep it in a
# callee-saved register for the duration. Nothing in the loop calls out, so
# there is no clobber to force a spill.
@[NoInline]
def spin_holding(hidden : UInt64, ready : Gate, go : Gate) : UInt64
  real = hidden ^ KEY
  ready.set
  while go.get == 0
  end
  real
end

# The negative control: same setup, except the worker never materialises the
# pointer. Nothing anywhere holds the victim, so it must be collected. If it
# survives this arm, some part of the harness is retaining it — a stale word in
# the main thread's frame, a register the collector itself never dropped — and
# the end-to-end arm above is passing for a reason that has nothing to do with
# the register scan.
@[NoInline]
def spin_idle(ready : Gate, go : Gate) : Nil
  ready.set
  while go.get == 0
  end
end

explain = ARGV.includes?("--explain")
control = ARGV.includes?("--control")

puts "=== suspended-thread register roots ==="
puts "victim #{VICTIM_SIZE} B, filled 0x#{FILL.to_s(16)}, reachable only as addr ^ KEY"
puts "mode: #{control ? "control (worker holds nothing; victim must die)" : "hold (worker's register is the only root)"}"

hidden = make_victim_hidden
wipe_stack

ready = Gate.new
go = Gate.new
worker_result = Atomic(UInt64).new(0_u64)

worker = if control
           Thread.new { spin_idle(ready, go) }
         else
           Thread.new { worker_result.set(spin_holding(hidden, ready, go)) }
         end

# Spin, not sleep: the worker must be *running* when the world stops, so that
# its registers are the ones the collector reads.
while ready.get == 0
end

GC.collect

candidates = HEAP.thread_greg_candidates
puts "register candidates from suspended threads: #{candidates}"

go.set
worker.join
# In control mode nothing ever held the plaintext, so recover it from `hidden`
# here — after the collection, where knowing it can no longer keep it alive.
real = control ? (hidden ^ KEY) : worker_result.get
victim = Pointer(Void).new(real)

alive = HEAP.live?(victim)
bytes = victim.as(UInt8*)
intact = true
i = 0_u64
while i < VICTIM_SIZE
  if bytes[i] != FILL
    intact = false
    break
  end
  i += 1
end

puts "victim 0x#{real.to_s(16)}: live?=#{alive} intact=#{intact}"

failures = [] of String

# ── Arm 1: the mechanism ─────────────────────────────────────────────────────
if candidates == 0
  failures << "the register scan yielded nothing while a thread was suspended — " \
              "each_thread_greg is not reporting on this platform"
end

# ── Arm 2: end to end (or its negative control) ──────────────────────────────
if control
  if alive
    failures << "the victim survived with nothing holding it — the harness is " \
                "retaining it, so the end-to-end arm proves nothing"
  end
else
  failures << "the victim was swept while a suspended thread's register held it" unless alive
  failures << "the victim's contents were overwritten after collection" unless intact
end

if explain
  puts
  puts "What a pass is worth:"
  puts "  The candidate count is the gate. A platform that never reports registers"
  puts "  cannot reach a non-zero count, whatever the workload or the compiler does."
  puts "  Stubbing each_thread_greg out drops it to 0 on every run."
  puts
  puts "  The survival check is NOT the gate, and it is worth being blunt about"
  puts "  why: with the fix reverted the victim still survived 5/5 on this host."
  puts "  LLVM keeps a copy of the pointer in the worker's own frame, so the"
  puts "  conservative scan of that stack finds it whether or not the registers"
  puts "  were ever read. Keeping a value out of memory is a codegen outcome, not"
  puts "  something this test can compel — which is the same reason the original"
  puts "  defect was compiler-dependent and Linux never saw it."
  puts
  puts "  --control is what keeps the survival check from being vacuous the other"
  puts "  way: with nothing holding the victim it dies, so the harness is not"
  puts "  quietly retaining it."
end

if failures.empty?
  puts
  if control
    puts "ok — #{candidates} register candidates, and the victim died with nothing " \
         "holding it (the harness does not retain it)"
  else
    puts "ok — #{candidates} register candidates from suspended threads. " \
         "The victim also survived, but see --explain: that half does not " \
         "discriminate, the count is the gate."
  end
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
