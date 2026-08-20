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
#   crystal build -Dgc_none bench/thread_birth_root.cr -o bin/thread_birth_root
#   bin/thread_birth_root
#   bin/thread_birth_root --control

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
mode = control ? "control (GCRY_THREAD_BIRTH_ROOT=0)" : (noroot ? "noroot (records births, roots nothing)" : "hold (root armed)")

puts "=== thread-birth root ==="
puts "mode: #{mode}"

hidden = make_victim_hidden
wipe_stack

handle = uninitialized LibC::PthreadT
rc = GC.pthread_create(
  thread: pointerof(handle),
  attr: Pointer(LibC::PthreadAttrT).null,
  start: ->raw_thread_body(Void*),
  arg: Pointer(Void).new(hidden ^ KEY),
)
raise "pthread_create failed: #{rc}" unless rc == 0

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

if control
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
  when control then "ok — with the knob off nothing is armed and the block dies, so the hold arm's survival is the root's doing"
  when noroot  then "ok — the same births recorded, nothing rooted, and the block dies"
  else              "ok — the object a thread is being born with survives a collection it could not have survived"
  end
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
