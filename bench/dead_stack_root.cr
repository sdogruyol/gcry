# Is the stack of a *terminating* fiber a root?
#
# Crystal says why the window exists, in `crystal/system/thread.cr`: *"When a
# fiber terminates we can't release its stack until we swap context to another
# fiber."* So `Thread#dead_fiber_stack` parks the dying fiber's stack on the
# thread and hands the previous one back. While it sits there the thread may
# still be executing on it, and the `Fiber` that owned it is already gone from
# `Fiber.unsafe_each` — which is how gcry finds fiber stacks. The other-thread
# scan uses *pthread* stack bounds, which a thread running on a fiber stack is
# nowhere near. Nothing covered it.
#
# `src/gcry/unowned_stack_roots.cr` closed it in v0.20.0, and the fix is
# credited with taking the nested-spawn repro from **11/24 crashes to 0/24**
# (`log/linux/2026-08-17-dead-fiber-stack-roots/FINDINGS.md`).
#
# **That fix had no gate.** Its disable, `GCRY_DEAD_STACK_ROOTS=0`, appeared in
# no spec, no recipe and no CI step; `bench/nested_spawn_uaf.cr` prints
# `dead_stacks_walked` without asserting it, and its own target says "Not a
# gate: it fails most runs on purpose" and does not run in CI. So
# `scan_dead_fiber_stacks` could have regressed to a no-op and every gate in the
# tree would have stayed green — the same arrangement that let
# `make page-release-corruption` and `make live-graph-audit` test nothing for
# releases (`log/linux/2026-09-16-gate-arm-audit/FINDINGS.md`).
#
# Four arms:
#
#   walked      a collection taken while a thread holds a dying fiber's stack
#               must *walk* one. `dead_stacks_walked` is the counter, and it is
#               here because a harness that never got a stack parked and a
#               collector that stopped walking them are indistinguishable from
#               the outside. **This is the precondition**, asserted before
#               anything below is allowed to mean something.
#
#   rooted      a block whose only reference is a word on that parked stack must
#               survive. **This is the gate.**
#
#   noroot      `GCRY_DEAD_STACK_NOROOT=1` walks the same memory and offers
#               nothing. The block must die. This is what separates *walking*
#               from *rooting*: the counter alone cannot, and the twin arm is
#               how the original measurement told its own zero from a timing
#               artefact.
#
#   disabled    `GCRY_DEAD_STACK_ROOTS=0` turns the walk off outright. The block
#               must die, and the walk counter must read zero — which is how
#               this arm also checks that the knob still gates what it claims.
#
#   --control   the block is allocated and its address is never written to the
#               dying fiber's stack. It must die. Without it, a conservative hit
#               anywhere else in the process would pass the `rooted` arm for a
#               reason that has nothing to do with this window.
#
# What this does **not** claim: it is not the 2026-08-17 defect. That was a
# dying `Deque(Fiber::Stack)` buffer freed while a thread still used it, found
# by an address-space audit. This asserts the *coverage mechanism* that was
# shipped in response — that a word on a parked dying stack is a root — which is
# the part a regression would silently remove.
#
# Semantically the victim here is garbage: the fiber that referenced it has
# returned. Retaining it is precisely what rooting a dying stack does, and
# conservative retention of a stack the thread may still be running on is the
# trade the fix makes. So "survives" is the contract under test, not a leak.
#
#   crystal build -Dgc_none bench/dead_stack_root.cr -o bin/dead_stack_root
#   bin/dead_stack_root
#   GCRY_DEAD_STACK_NOROOT=1 bin/dead_stack_root --noroot
#   bin/dead_stack_root --control

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "dead_stack_root requires -Dgc_none (gcry as process GC)" %}
{% end %}

HEAP = Gcry.default_heap.not_nil!

VICTIM_SIZE =      96
FILL        = 0xA5_u8
# `addr ^ KEY` is not a heap pointer, so the copy this harness keeps in order to
# ask about the block afterwards cannot itself root it. Same device as
# `bench/greg_roots.cr` and `bench/tls_roots.cr`.
KEY = 0x9E3779B97F4A7C15_u64

# The obfuscated address, published by the dying fiber before it returns. A
# class variable is in the BSS, which *is* a root range — hence the obfuscation.
class Hidden
  @@value = 0_u64

  def self.set(v : UInt64) : Nil
    @@value = v
  end

  def self.get : UInt64
    @@value
  end
end

# Write the victim's plain address into words near the top of the *current*
# fiber's stack and return. Every hit the 2026-08-17 address-space audit
# reported was 968 to 1408 bytes below the stack top — `makecontext`'s frame —
# and `UNOWNED_STACK_WINDOW` is 64 KiB from the top, so a buffer of locals here
# lands inside the window the collector walks.
#
# The argument arrives **obfuscated** and the XOR happens here, under
# `plant_it`. That is not decoration: the first version of this harness
# allocated the victim inside the dying fiber and passed the plain address in,
# so the fiber's own frames held plaintext copies that `GC.malloc` and the
# argument left behind — and the dying-stack root then retained the victim in
# the control arm too, which the control arm duly reported. Nothing on this
# stack may know the plain address unless this arm means to plant it.
#
# NoInline so the frame belongs to this call and is left behind on the stack
# when it returns, rather than being folded into the fiber's entry frame.
@[NoInline]
def plant(hidden : UInt64, plant_it : Bool) : Nil
  slots = uninitialized UInt64[512]
  p = slots.to_unsafe
  # Both arms touch the same 4 KiB of stack and store the same number of words,
  # so a difference in survival cannot be a difference in frame size. Only the
  # *value* differs, and in the control arm the plain address is never computed.
  value = plant_it ? (hidden ^ KEY) : hidden
  i = 0
  while i < 512
    p[i] = value
    i += 1
  end
  # Keep the stores from being dead-code eliminated: the collector is the only
  # other reader, and LLVM cannot know that.
  Gcry::Roots.keep_alive(p.as(Void*))
end

# Allocated on the **main** fiber, never inside the dying one: the victim's
# address must not reach that stack by any route other than `plant`.
@[NoInline]
def make_victim_hidden : UInt64
  ptr = GC.malloc(VICTIM_SIZE).as(UInt8*)
  i = 0
  while i < VICTIM_SIZE
    ptr[i] = FILL
    i += 1
  end
  ptr.address ^ KEY
end

control = ARGV.includes?("--control")
noroot_arm = ARGV.includes?("--noroot")
disabled_arm = ARGV.includes?("--disabled")

puts "=== the dying fiber's stack as a root ==="
mode = if control
         "control (the address is never planted; the block must die)"
       elsif noroot_arm
         "noroot (GCRY_DEAD_STACK_NOROOT: walk the stack, offer nothing; must die)"
       elsif disabled_arm
         "disabled (GCRY_DEAD_STACK_ROOTS=0: the walk itself is off; must die)"
       else
         "hold (the only reference is a word on the parked dying stack)"
       end
puts "mode: #{mode}"
puts "dead_stack_roots=#{HEAP.dead_stack_roots} dead_stack_noroot=#{HEAP.dead_stack_noroot}"

# `scan_dead_fiber_stacks` reads `offer = @dead_stack_roots`, so
# `GCRY_DEAD_STACK_NOROOT=1` on its own walks the stack *and* offers its words —
# the fix is still on. The twin arm is `GCRY_DEAD_STACK_ROOTS=0
# GCRY_DEAD_STACK_NOROOT=1`, and requiring both here is what stops this arm from
# quietly measuring the shipped fix and calling it a control. Measured: with
# NOROOT alone the victim survives, which is the fix working, not the twin.
if noroot_arm && !(HEAP.dead_stack_noroot && !HEAP.dead_stack_roots)
  STDERR.puts "--noroot needs GCRY_DEAD_STACK_ROOTS=0 *and* GCRY_DEAD_STACK_NOROOT=1: the " \
              "walk offers words whenever dead_stack_roots is on, so NOROOT alone is the " \
              "shipped fix with an extra flag set, not a twin that roots nothing."
  exit 64
end
if disabled_arm && HEAP.dead_stack_roots
  STDERR.puts "--disabled needs GCRY_DEAD_STACK_ROOTS=0; with the fix on this arm would " \
              "require the block to die while the root that keeps it alive is running."
  exit 64
end

walked_before = HEAP.dead_stacks_walked
hidden = make_victim_hidden
Hidden.set(hidden)

# The default execution context runs at parallelism 1, so the fiber below and
# this one share a worker thread: the stack it parks on termination is parked on
# the very thread that then runs the collection. Asserted through the counter
# rather than assumed.
done = Channel(Nil).new
spawn do
  plant(Hidden.get, !control)
  done.send(nil)
end
done.receive

# Two, so that a single collection landing before the stack was parked cannot be
# the explanation. The slot is read from the ivar and not consumed, so it
# survives the first collection.
GC.collect
GC.collect

walked = HEAP.dead_stacks_walked - walked_before
victim = Pointer(Void).new(Hidden.get ^ KEY)
alive = HEAP.live?(victim)

puts "dead-fiber stacks walked across the two collections: #{walked}"
puts "words offered: #{HEAP.dead_stack_words}"
puts "victim 0x#{victim.address.to_s(16)}: live?=#{alive}"
puts ""

failures = [] of String

# Precondition, for every arm in which the walk is supposed to happen: "it died"
# means nothing if no dying stack was ever walked. The `--disabled` arm is the
# exception by construction — `scan_dead_fiber_stacks` is gated on the very flag
# that arm turns off — so there it is asserted the other way.
if disabled_arm
  unless walked == 0
    failures << "GCRY_DEAD_STACK_ROOTS=0 still walked #{walked} dying stack(s) — the knob no " \
                "longer gates the walk, so this arm is not the pre-fix behaviour it claims"
  end
elsif walked == 0
  failures << "no dying fiber's stack was walked across two collections, so this run never " \
              "built the window it is about — the arms below would pass or fail for reasons " \
              "with nothing to do with the dying-stack root. `scan_dead_fiber_stacks` is " \
              "macro-gated on `Thread#dead_fiber_stack`, so a compiler that does not declare " \
              "that ivar lands here too: this fails rather than skipping, because a gate for " \
              "a root that cannot be walked is a gate reporting on nothing"
end

if control
  if alive
    failures << "the control block survived with its address never planted on the dying " \
                "stack, so something else in this process retains it and neither arm can " \
                "discriminate"
  end
elsif noroot_arm
  if alive
    failures << "the block survived while the collector was walking the dying stack and " \
                "offering nothing — so it is being retained by something other than the " \
                "dying-stack root, and the hold arm's green says nothing about that root"
  end
elsif disabled_arm
  if alive
    failures << "the block survived with GCRY_DEAD_STACK_ROOTS=0 — something other than the " \
                "dying-stack root retains a word that only that stack holds"
  end
else
  unless alive
    failures << "a block whose only reference is a word on a parked dying fiber's stack was " \
                "collected — scan_dead_fiber_stacks is not rooting what it walks, and the " \
                "v0.20.0 fix credited with 11/24 -> 0/24 on the nested-spawn repro is gone"
  end
end

if failures.empty?
  if control
    puts "ok — with nothing planted the block dies, so the hold arm's survival is " \
         "attributable to the planted word and not to the harness."
  elsif noroot_arm
    puts "ok — walking the dying stack without offering its words lets the block die, so " \
         "the hold arm measures rooting rather than walking."
  elsif disabled_arm
    puts "ok — with the fix off the walk does not happen and the block dies."
  else
    puts "ok — a word on a parked dying fiber's stack kept its block alive, and #{walked} " \
         "such stack(s) were walked to do it."
  end
  exit 0
end

failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
