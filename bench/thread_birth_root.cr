# Does a `Thread` object survive a collection between `pthread_create` and the
# thread's own first push onto Crystal's list?
#
# That window is where the second use-after-free lives
# (`bench/log/linux/2026-08-20-dying-thread-holder/FINDINGS.md`): the object is
# off Crystal's list, so the static root that is `Thread.threads` does not cover
# it, and its only other holder is the new thread's stack, which gcry has no
# bounds for and never scans. `src/gcry/thread_birth_root.cr` roots it from the
# `arg` Crystal hands to `pthread_create` and releases it when the thread turns
# up on the list.
#
# The window cannot be held open with a real `Thread` — Crystal publishes one in
# microseconds. So this gate creates a **raw** pthread through the same hook,
# with a plain heap block as `arg`. That thread never joins Crystal's list, so
# the block stays in exactly the state the defect needs, for as long as the
# harness wants: reachable from the new thread's unscanned stack and from
# nowhere else.
#
#   hold      the root armed. The block must survive the collection.
#   noroot    `GCRY_THREAD_BIRTH_NOROOT=1` — the same births recorded, nothing
#             rooted. The block must **die**, or the arm above is passing for a
#             reason that is not the root.
#   --control the knob off entirely. Same requirement as `noroot`, and it also
#             requires the counters to stay at zero, so the other arms' numbers
#             are attributable to the knob.
#
# And what the table does when it runs out of slots, which is not the rare event
# the size suggests: a slot is freed by `release`, which runs inside
# `stop_world`, so the table holds one entry per birth **since the last
# collection** — 65 `Thread.new`s with no collection between them are enough.
#
#   --burst           fill the table with births that can never be released,
#                     then arm the victim's. Its birth overflows, and it must
#                     survive anyway: an overflow costs the record, not the root.
#   --burst-unrooted  `GCRY_THREAD_BIRTH_OVERFLOW_UNROOTED=1` — the old
#                     behaviour, where a full table meant no `add_root` at all.
#                     Same overflow, and the block must **die**. Without this
#                     arm the one above is a counter that proves nothing.
#
#   crystal build -Dgc_none bench/thread_birth_root.cr -o bin/thread_birth_root
#   bin/thread_birth_root
#   bin/thread_birth_root --control
#   bin/thread_birth_root --burst

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "thread_birth_root requires -Dgc_none (gcry as process GC)" %}
{% end %}

VICTIM_SIZE =  96_u64
FILL        = 0xC7_u8
# The victim's address never appears in a frame as itself, so the harness cannot
# be what keeps it alive. Same device as `bench/greg_roots.cr`.
KEY = 0x5A5A_A5A5_5A5A_A5A5_u64

# Set by the parent to let the raw thread finish. A class variable rather than a
# closure: the start routine must be a bare function pointer.
class Latch
  @@go = Atomic(Int32).new(0)

  def self.go : Int32
    @@go.get
  end

  def self.release : Nil
    @@go.set(1)
  end
end

def raw_thread_body(arg : Void*) : Void*
  # The argument is live on this thread's stack for the whole spin — which is
  # precisely the holder gcry cannot see, because this thread is not on
  # Crystal's list and has no snapshotted stack bounds.
  while Latch.go == 0
  end
  arg
end

# A birth that can never be released: the thread is raw, so it never reaches
# Crystal's list, and `release` is the only thing that frees a slot. It may exit
# immediately — the record outlives it. Deliberately **not** joined: glibc
# recycles a `pthread_t` once its thread is joined, and a recycled id colliding
# with a real Crystal thread's would let `stop_world` free one of these slots
# and quietly un-fill the table this arm is trying to fill.
def filler_body(arg : Void*) : Void*
  arg
end

# Fill every slot, so the next birth is the one under test.
def fill_birth_table(filler : Void*) : Int32
  filled = 0
  Gcry::ThreadBirthRoot::SLOTS.times do
    handle = uninitialized LibC::PthreadT
    rc = GC.pthread_create(
      thread: pointerof(handle),
      attr: Pointer(LibC::PthreadAttrT).null,
      start: ->filler_body(Void*),
      arg: filler,
    )
    raise "filler pthread_create failed: #{rc}" unless rc == 0
    filled += 1
  end
  filled
end

# The raw pointer exists only inside this frame: the caller passes and keeps the
# masked form, so no long-lived frame of the harness holds the victim's address.
@[NoInline]
def spawn_holder(hidden : UInt64) : LibC::PthreadT
  handle = uninitialized LibC::PthreadT
  rc = GC.pthread_create(
    thread: pointerof(handle),
    attr: Pointer(LibC::PthreadAttrT).null,
    start: ->raw_thread_body(Void*),
    arg: Pointer(Void).new(hidden ^ KEY),
  )
  raise "pthread_create failed: #{rc}" unless rc == 0
  handle
end

@[NoInline]
def make_victim_hidden : UInt64
  victim = GC.malloc(VICTIM_SIZE)
  bytes = victim.as(UInt8*)
  i = 0_u64
  while i < VICTIM_SIZE
    bytes[i] = FILL
    i += 1
  end
  victim.address ^ KEY
end

# Overwrite the frames the victim's address passed through.
@[NoInline]
def wipe_stack : Nil
  buf = uninitialized UInt8[16384]
  i = 0
  while i < 16384
    buf.to_unsafe[i] = 0x11_u8
    i += 1
  end
  Gcry::Trace.enabled? && puts(buf.to_unsafe[0])
end

heap = Gcry.default_heap
control = ARGV.includes?("--control")
noroot = ARGV.includes?("--noroot")
burst = ARGV.includes?("--burst")
burst_unrooted = ARGV.includes?("--burst-unrooted")
burst ||= burst_unrooted
mode = case
       when burst_unrooted then "burst-unrooted (GCRY_THREAD_BIRTH_OVERFLOW_UNROOTED=1, table full)"
       when burst          then "burst (table full, birth overflows)"
       when control        then "control (GCRY_THREAD_BIRTH_ROOT=0)"
       when noroot         then "noroot (records births, roots nothing)"
       else                     "hold (root armed)"
       end

puts "=== thread-birth root ==="
puts "mode: #{mode}"

# A non-null `arg` for the fillers that is not the victim, so filling the table
# cannot be what keeps the victim alive.
filled = burst ? fill_birth_table(Pointer(Void).new(0x1000_u64)) : 0
puts "filled #{filled} birth(s) into a #{Gcry::ThreadBirthRoot::SLOTS}-slot table" if burst

hidden = make_victim_hidden
wipe_stack

handle = spawn_holder(hidden)
# Again, because the pointer was materialised inside `spawn_holder` and its
# frame is where the collector's frames now go. Without this the arm that must
# see the block *die* can be kept alive by a dead slot in the harness's own
# stack — which is what a conservative collector is entitled to do, and is not
# a property of the fix under test.
wipe_stack

# Two, so a single collection's timing cannot be the explanation.
GC.collect
GC.collect

victim = Pointer(Void).new(hidden ^ KEY)
alive = heap.live?(victim)
intact = true
bytes = victim.as(UInt8*)
i = 0_u64
while i < VICTIM_SIZE
  if bytes[i] != FILL
    intact = false
    break
  end
  i += 1
end

armed = Gcry::ThreadBirthRoot.armed
released = Gcry::ThreadBirthRoot.released
outstanding = Gcry::ThreadBirthRoot.outstanding
overflows = Gcry::ThreadBirthRoot.overflows

Latch.release
GC.pthread_join(handle)

puts "victim 0x#{(hidden ^ KEY).to_s(16)}: live?=#{alive} intact=#{intact}"
puts "births armed=#{armed} released=#{released} outstanding=#{outstanding} overflows=#{overflows}"

failures = [] of String

if burst
  failures << "no birth overflowed, so the full table was never under test" if overflows == 0
  if burst_unrooted
    failures << "the table was full, nothing was rooted, and the block survived anyway — " \
                "the other arm's survival cannot be credited to the overflow root" if alive
  else
    unless alive
      failures << "the block a thread is being born with was collected because the birth table " \
                  "was full — an overflow is costing the root, not just the record"
    end
    failures << "the block survived but its contents were overwritten" if alive && !intact
  end
elsif control
  failures << "the knob is off and #{armed} birth(s) were still armed" if armed > 0
  failures << "the knob is off and the block survived, so the other arm proves nothing" if alive
elsif noroot
  failures << "the twin recorded no births at all, so its null result is not a measurement" if armed == 0
  failures << "the twin roots nothing and the block survived anyway — the other arm's survival " \
              "cannot be credited to the root" if alive
else
  failures << "no birth was armed, so nothing was under test" if armed == 0
  unless alive
    failures << "the block a thread is being born with was collected while the thread had not " \
                "published itself — the window is open"
  end
  failures << "the block survived but its contents were overwritten" if alive && !intact
  # The raw thread never joins Crystal's list, so its root is still held. That
  # is the intended behaviour and the counter has to show it, or `release`
  # is dropping roots it should not.
  failures << "the root was released for a thread that never published" if released > 0 && outstanding == 0
end

if failures.empty?
  puts
  puts case
  when burst_unrooted then "ok — with the table full and the overflow left unrooted, the block dies"
  when burst          then "ok — the birth overflowed a full table and was rooted anyway"
  when control        then "ok — with the knob off nothing is armed and the block dies, so the hold arm's survival is the root's doing"
  when noroot         then "ok — the same births recorded, nothing rooted, and the block dies"
  else                     "ok — the object a thread is being born with survives a collection it could not have survived"
  end
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
