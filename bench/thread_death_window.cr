# A dying thread's `Thread` object, across a collection it cannot be seen in.
#
# `Thread#start` ends with
#
#     Thread.threads.delete(self)   # off Crystal's list: not suspended, not scanned
#     Fiber.inactive(fiber)         # takes the fiber list's mutex
#     detach { system_close }       # reads @detached and @system_handle
#
# and from the first line on, the only holder of a `Thread` nobody kept is the
# dying thread's own stack, which gcry neither suspends nor scans. The middle
# line is where it waits: every stop holds the fiber list's mutex from before
# the first suspend to after the last resume (`lock_fiber_list_for_stop`), so a
# thread that left the list just before a stop sits in `Fiber.inactive` for
# the whole collection and then dereferences `self`. The mark cannot reach the
# object; only something gcry holds on the thread's behalf can.
#
# This harness builds that state on purpose instead of waiting for it: it
# holds the fiber list's mutex itself, lets fire-and-forget threads finish,
# waits until every one of them is off Crystal's list — parked in
# `Fiber.inactive` with `self` still to be read — and collects with the
# collector's own lock disabled (`fiber_list_unlocked`, so the collector does
# not relock a mutex this thread holds). Every `Thread` must come out of that
# allocated and intact. A collection also runs while the threads are alive and
# listed, because a policy that releases the root when the list is seen to
# cover the thread (the Windows policy until 2026-10-05) passes without one.
#
# Arms:
#
#   (default)    the main thread creates every thread.
#   --concurrent several creators at once, so births race on the root table.
#   --control    `GCRY_THREAD_BIRTH_ROOT=0`: nothing holds the objects, and at
#                least one must die, or the harness built no window and its
#                clean runs prove nothing.
#
#   crystal build -Dgc_none bench/thread_death_window.cr -o bin/thread_death_window
#   bin/thread_death_window [--concurrent] [--control]

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "thread_death_window requires -Dgc_none (gcry as process GC)" %}
{% end %}

# The `Thread` addresses never sit in a frame of this harness as themselves,
# so the harness cannot be what keeps them alive.
KEY = 0x5A5A_A5A5_5A5A_A5A5_u64

module DeathWindow
  @@go = Atomic(Int32).new(0)
  @@started = Atomic(Int32).new(0)

  def self.go? : Bool
    @@go.get != 0
  end

  def self.go! : Nil
    @@go.set(1)
  end

  def self.started : Int32
    @@started.get
  end

  def self.started! : Nil
    @@started.add(1)
  end
end

# Spawns and forgets. The pointer exists only in this frame; the caller gets
# the masked form.
@[NoInline]
def spawn_parked(handles : Pointer(UInt64), i : Int32) : UInt64
  thread = Thread.new do
    handles[i] = Thread.current.to_unsafe.unsafe_as(UInt64)
    DeathWindow.started!
    until DeathWindow.go?
      Thread.yield
    end
  end
  thread.object_id ^ KEY
end

# Overwrite the frames a `Thread` address passed through.
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

# Garbage the size of the victims, so a block the sweep freed is handed out
# again and written over before anything looks at it.
@[NoInline]
def churn_garbage : Nil
  512.times do
    block = GC.malloc(instance_sizeof(Thread)).as(UInt64*)
    (instance_sizeof(Thread) // 8).times { |j| block[j] = 0xEEEE_EEEE_EEEE_EEEE_u64 }
  end
end

# The masked ids of the threads on Crystal's list, copied out under the list's
# mutex; compared against the victims outside it. The wait below polls this
# with the fiber list held, and every victim needs the thread list's mutex once
# to leave it: a poll that held it for the whole threads × victims compare and
# took it again after a bare `Thread.yield` let the poller barge back in ahead
# of the woken victims. `--concurrent` hung there once on aarch64 (CI,
# 2026-10-06: "threads did not leave Crystal's list within 30 s").
LISTED_CAP = 4096

@[NoInline]
def listed_victims(hidden : Pointer(UInt64), n : Int32, scratch : Pointer(UInt64)) : Int32
  count = 0
  Thread.each do |thread|
    scratch[count] = thread.object_id ^ KEY if count < LISTED_CAP
    count += 1
  end
  listed = 0
  Math.min(count, LISTED_CAP).times do |j|
    i = 0
    while i < n
      listed += 1 if hidden[i] == scratch[j]
      i += 1
    end
  end
  listed
end

control = ARGV.includes?("--control")
concurrent = ARGV.includes?("--concurrent")
creators = concurrent ? 8 : 1
per = ENV["DEATH_WINDOW_PER"]?.try(&.to_i?) || (concurrent ? 24 : 160)
n = creators * per
# Under the birth table's size, so no birth takes the overflow path — which
# roots permanently and would hide a root the table lost.
abort "#{n} threads would overflow the #{Gcry::ThreadBirthRoot::SLOTS}-slot birth table" if n > Gcry::ThreadBirthRoot::SLOTS - 16

heap = Gcry.default_heap
hidden = Pointer(UInt64).malloc(n)
handles = Pointer(UInt64).malloc(n)
# Allocated now: nothing may allocate while this thread holds the fiber list,
# or a collection would wait on the mutex its own thread holds.
listed_scratch = Pointer(UInt64).malloc(LISTED_CAP)
deaths_before = Gcry::ThreadBirthRoot.released

puts "=== thread death window ==="
puts "mode: #{control ? "control (GCRY_THREAD_BIRTH_ROOT=0)" : "hold"}, #{creators} creator(s) x #{per} fire-and-forget threads"

if concurrent
  gate = Atomic(Int32).new(0)
  makers = Array(Thread).new(creators) do |c|
    Thread.new do
      until gate.get != 0
        Thread.yield
      end
      per.times { |k| hidden[c * per + k] = spawn_parked(handles, c * per + k) }
      wipe_stack
    end
  end
  gate.set(1)
  makers.each(&.join)
  makers.clear
else
  n.times { |i| hidden[i] = spawn_parked(handles, i) }
end
wipe_stack

until DeathWindow.started == n
  Thread.yield
end

# Alive and listed. Harmless for a root that lasts the whole life; a policy
# that drops it once the list covers the thread drops it here.
GC.collect

# Park every thread in its death window.
Fiber.gcry_lock_list
DeathWindow.go!
deadline = Time.instant + 30.seconds
until (left = listed_victims(hidden, n, listed_scratch)) == 0
  if Time.instant > deadline
    Fiber.gcry_unlock_list
    abort "threads did not leave Crystal's list within 30 s: #{left} of #{n} still listed, " \
          "#{heap.collections} collection(s) so far"
  end
  Thread.sleep(100.microseconds)
end

heap.fiber_list_unlocked = true
3.times do
  wipe_stack
  GC.collect
  churn_garbage
end
heap.fiber_list_unlocked = false

dead = 0
torn = 0
n.times do |i|
  object = Pointer(Void).new(hidden[i] ^ KEY)
  if !heap.live?(object)
    dead += 1
  elsif object.as(Thread).to_unsafe.unsafe_as(UInt64) != handles[i]
    torn += 1
  end
end
lost = dead + torn
puts "#{n} threads parked between `Thread.threads.delete` and `Fiber.inactive` across 3 collections: " \
     "#{dead} swept, #{torn} overwritten"
puts "birth roots armed=#{Gcry::ThreadBirthRoot.armed} outstanding=#{Gcry::ThreadBirthRoot.outstanding} " \
     "overflows=#{Gcry::ThreadBirthRoot.overflows} released=#{Gcry::ThreadBirthRoot.released - deaths_before}"

if control
  if lost == 0
    STDERR.puts "FAIL: nothing holds these objects and every one survived — the harness built no window"
    LibC._exit(1)
  end
  # The dying threads are about to read freed memory; do not let them.
  puts "ok — with the birth root off, #{lost} of #{n} dying threads lost their `Thread`"
  LibC._exit(0)
end

if lost > 0
  STDERR.puts "FAIL: #{lost} of #{n} dying threads lost their `Thread` while still using it"
  LibC._exit(1)
end

Fiber.gcry_unlock_list
# Let them finish, and the roots their deaths end.
until Gcry::ThreadBirthRoot.released - deaths_before >= n || Time.instant > deadline + 30.seconds
  GC.collect
  Thread.sleep(1.millisecond)
end
released = Gcry::ThreadBirthRoot.released - deaths_before
puts "released after the deaths: #{released} of #{n}"
if released < n
  STDERR.puts "FAIL: #{n - released} birth root(s) outlived their thread"
  exit 1
end
puts "ok — every dying thread kept its `Thread` until it was done with it"
