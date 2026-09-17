# Is a pointer held only in thread-local storage a root?
#
# `GCRY_POISON_HOLDERS=1` ends its search with the same sentence every time a
# use-after-free is reported on this heap:
#
#   > holders — none. Nothing in the root set, in a live block or on a fiber
#   > stack points into it, so the pointer is in a register, in thread-local
#   > storage, or in memory gcry never mapped — and those are three different
#   > defects
#
# Registers are covered: every thread the stop suspends has its GP registers
# spilled from the `ucontext` and scanned, and the Monitor — which is never
# suspended — spills its own in `MonitorGate.enter`. The third branch had
# never been tested at all, and what prompted testing it was the open
# live-large-object release: *no* coverage knob moves that rate (`GCRY_SOUND=1`
# 25 of 36 against a baseline of 25 of 36) and the released chunk's own
# bookkeeping is self-consistent — `Blocks still allocated at release: 0`, so
# the block really was free and the reference really was somewhere unscanned.
#
# The answer here is **not** that defect — measured, `GCRY_TLS_ROOTS` does not
# move its rate either (`bench/log/linux/2026-09-12-tls-not-a-root/`). It is a
# second, unrelated one that the question turned up on the way.
#
# Where TLS lives is not uniform, which is the point:
#
#   main thread    the loader's TLS block, in its own mapping — **nowhere
#                  near** the stack. Measured: tls 0x7f9db13e0770 against a
#                  stack of [0x7ffc1e8e9000, 0x7ffc1f0e6000).
#   spawned thread glibc puts the descriptor and static TLS at the top of the
#                  thread's stack mapping, inside the bounds
#                  `pthread_getattr_np` reports and above the suspend SP, so
#                  the ordinary stack scan covers it. Measured: tls
#                  0x7f9daf5fe6b0 inside [0x7f9daedff000, 0x7f9daf5ff000).
#
# So the question is really about the **main thread**, and this asks it the
# way `make greg-roots` asks its own: hide a block so that no scanned copy of
# its address exists, keep the only copy in a thread-local, collect, and see
# whether it survived.
#
#   crystal build -Dgc_none bench/tls_roots.cr -o bin/tls_roots
#   bin/tls_roots
#   bin/tls_roots --control    # keep it nowhere; it must die

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "tls_roots requires -Dgc_none (gcry as process GC)" %}
{% end %}

VICTIM_SIZE =      96
FILL        = 0xa5_u8
# The address is kept XOR'd everywhere except the thread-local, so a stray
# copy on the harness's own stack cannot be what keeps it alive. Same device
# as `bench/thread_birth_root.cr`.
KEY = 0x5A5A_A5A5_5A5A_A5A5_u64

class TlsHolder
  # The only copy of the pointer, for the arm under test.
  @[ThreadLocal]
  @@slot : Pointer(Void) = Pointer(Void).null

  def self.hold(ptr : Pointer(Void)) : Nil
    @@slot = ptr
  end

  def self.release : Nil
    @@slot = Pointer(Void).null
  end

  def self.addr : UInt64
    pointerof(@@slot).address
  end
end

# Materialise the block, fill it, and return its address obscured. Not inlined,
# so the frame that held the plain pointer is gone by the time the caller
# returns.
@[NoInline]
def make_victim(hold : Bool) : UInt64
  ptr = GC.malloc(VICTIM_SIZE).as(UInt8*)
  VICTIM_SIZE.times { |i| ptr[i] = FILL }
  TlsHolder.hold(ptr.as(Void*)) if hold
  ptr.address ^ KEY
end

# Overwrite the frames the materialisation used. A conservative collector is
# entitled to find a stale slot and keep the block alive, and that would make
# both arms pass for a reason that has nothing to do with TLS.
@[NoInline]
def wipe_stack : Nil
  buf = uninitialized UInt8[16384]
  p = buf.to_unsafe
  i = 0
  while i < 16384
    p[i] = 0_u8
    i += 1
  end
  Gcry::Roots.keep_alive(p.as(Void*))
end

control = ARGV.includes?("--control")
heap = Gcry.default_heap.not_nil!

bounds = Gcry::Platform.current_pthread_stack_bounds
tls = TlsHolder.addr

puts "=== is thread-local storage a root? ==="
puts "mode: #{control ? "control (held nowhere; the block must die)" : "held only in a @[ThreadLocal]"}"
if bounds
  lo = bounds[0].address
  hi = bounds[1].address
  puts "main thread: tls slot 0x#{tls.to_s(16)}, stack [0x#{lo.to_s(16)}, 0x#{hi.to_s(16)})"
  puts "  the slot is #{tls >= lo && tls < hi ? "INSIDE" : "OUTSIDE"} the stack the scan walks"
else
  puts "main thread: no stack bounds available"
end
puts ""

hidden = make_victim(!control)
wipe_stack
# Two, so a single collection's timing cannot be the explanation.
GC.collect
GC.collect

victim = Pointer(Void).new(hidden ^ KEY)
alive = heap.live?(victim)
# A collected block may no longer be mapped. Linux typically leaves the
# page readable (`intact=true` after a free); Windows `VirtualFree`s it
# and a payload walk is C0000005 — which is how `make tls-roots` died on
# the Windows default variant, 2026-09-15, on both the red arm and the
# control. `live?` is a metadata check; the fill is only meaningful on a
# block the heap still owns.
intact = false
if alive
  bytes = victim.as(UInt8*)
  intact = true
  i = 0
  while i < VICTIM_SIZE
    if bytes[i] != FILL
      intact = false
      break
    end
    i += 1
  end
end

puts "victim 0x#{victim.address.to_s(16)}: live?=#{alive}#{alive ? " intact=#{intact}" : " (payload not read — the block is free)"}"
puts ""

if control
  unless alive
    puts "ok — with the pointer held nowhere the block dies, so the other arm's"
    puts "survival is attributable to the thread-local and not to the harness."
    exit 0
  end

  puts "INCONCLUSIVE — the control block survived with nothing holding it, so this"
  puts "host's conservative scan is finding a stale copy somewhere."
  puts ""
  # Which is not a thing to guess at. The holders search walks the explicit
  # roots, every live block and every fiber stack, and returns how many words
  # point into the block — so this arm's verdict rests on where the copy is
  # rather than on the survival alone.
  #
  # The search's own wording says "the range gcry released". Here the block is
  # still live; the search is being borrowed to ask who is keeping it.
  puts "asking the holders search where that copy is:"
  holders = Gcry::PoisonHolders.search(heap, victim.address, VICTIM_SIZE.to_u64)
  puts ""

  if holders > 0
    # Measured on Windows x86_64, run 35243383054: **8 words across 5 stacks**,
    # explicit roots 0 and heap 0, several of them above the running fiber's
    # `stack_top` — that is, in *live* frames. `wipe_stack` overwrites the dead
    # frames the materialisation used and cannot touch a live one, and keeping a
    # pointer out of memory is a codegen outcome no source-level test can
    # compel. `bench/greg_roots.cr` records the same fact about its end-to-end
    # arm and gates on a counter instead.
    #
    # So this is a harness that cannot discriminate *on this host*, not a
    # defect, and it is reported rather than failed: the gate's other two arms —
    # the pointer held only in TLS surviving, and `GCRY_TLS_ROOTS=0` losing it —
    # are unaffected and still fail the job.
    puts "#{holders} stale word(s) point into the block, so the conservative scan is right to"
    puts "keep it and this arm cannot discriminate on this host. Reported, not failed: the"
    puts "held arm and the GCRY_TLS_ROOTS=0 arm are what gate this behaviour."
    exit 0
  end

  puts "FAIL nothing the search can see holds this block and it survived anyway. That"
  puts "leaves a register, thread-local storage, or memory gcry never mapped — and on"
  puts "this arm the TLS slot is null, so the survival is unexplained."
  exit 1
end

if alive
  puts "ok — a pointer held only in a main-thread thread-local keeps its block alive,"
  puts "so TLS is covered and the holders message's third branch is not the gap."
  exit 0
end

puts "FAIL a block whose only reference is a main-thread `@[ThreadLocal]` was"
puts "collected. Thread-local storage is not a root."
puts ""
puts "That is the third branch of what `GCRY_POISON_HOLDERS=1` reports on every"
puts "use-after-free this heap has produced, and the only one that had not been"
puts "tested. The main thread's TLS is not in its stack mapping — the loader puts"
puts "it with the shared libraries — so the pthread-bounds scan cannot reach it,"
puts "and no coverage knob widens a range that does not contain it — which is"
puts "why none of them can find this class of missing reference."
exit 1
