# Can a thread with no `Thread.current` acknowledge a suspend?
#
# `Thread#start` publishes before it sets its own TLS
# (`crystal/system/thread.cr`):
#
#     Thread.threads.push(self)   # on the list — `stop_world` signals it
#     Thread.current = self       # TLS only now
#
# So a thread can be on Crystal's list, and therefore signalled, with no
# `Thread.current`. Crystal's accessor **creates one** on a miss
# (`crystal/system/unix/pthread.cr`: `self.current_thread = ::Thread.new`),
# and that constructor allocates a `Fiber`, allocates a `Thread`, and pushes
# onto `Thread.threads` — taking the list mutex `stop_world` holds for the
# whole stop. From inside a signal handler: an allocation with the world
# stopping, and a deadlock against the collector waiting for the very
# acknowledgement this handler was about to give.
#
# The window is one store wide, so waiting for a real birth to land in it is
# not a test. This drives it directly instead: a **raw pthread** that gcry's
# handler will answer for and Crystal has never heard of has no TLS by
# construction, permanently. Signal it exactly as a stop does — list mutex
# held, epoch open, slot reserved — and see whether it can answer.
#
#   no-tls       the shipped path. The raw thread must acknowledge through
#                its reserved slot, and `no_tls` must count the delivery.
#   no-tls+old   RED. `GCRY_STW_ACK_VIA_THREAD=1` restores the pre-table
#                line, creating accessor and all. The handler allocates a
#                `Thread` and takes `Thread.lock` — which this harness holds,
#                as a stop does — and never returns.
#   churn        the realistic workload: thread births against a collecting
#                heap. Reports `no_tls` rather than asserting it; the window
#                is narrow and whether a quiet x86_64 box lands in it says
#                nothing about a loaded aarch64 runner.
#
#   crystal build -Dgc_none bench/stw_ack_window.cr -o bin/stw_ack_window
#   bin/stw_ack_window
#   bin/stw_ack_window --child=<arm>

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "stw_ack_window requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% unless flag?(:linux) %}
  {% raise "stw_ack_window drives the signal-based stop; Linux only" %}
{% end %}

lib LibRawThread
  fun pthread_create(thread : LibC::PthreadT*, attr : LibC::PthreadAttrT*,
                     start : Void* -> Void*, arg : Void*) : LibC::Int
  fun pthread_join(thread : LibC::PthreadT, retval : Void**) : LibC::Int
  fun pthread_kill(thread : LibC::PthreadT, sig : LibC::Int) : LibC::Int
end

CHURN_ROUNDS = (ENV["ACK_WINDOW_ROUNDS"]?.try(&.to_i?) || 300)
CHURN_BATCH  =  6
TIMEOUT_S    = 20

# The raw thread spins on this word and touches nothing else. It must not
# allocate, take a lock, or call anything Crystal owns: it is standing in for
# a thread whose runtime is not up yet, and a stand-in that uses the runtime
# proves nothing.
RAW_RUN = Pointer(Int32).malloc(1)

def start_raw_thread : LibC::PthreadT
  tid = uninitialized LibC::PthreadT
  RAW_RUN.value = 1
  body = ->(_arg : Void*) do
    while RAW_RUN.value == 1
      Intrinsics.pause
    end
    Pointer(Void).null
  end
  rc = LibRawThread.pthread_create(pointerof(tid), Pointer(LibC::PthreadAttrT).null, body, Pointer(Void).null)
  raise "pthread_create failed: #{rc}" unless rc == 0
  tid
end

def spin_until(deadline_s : Float64, &) : Bool
  started = Time.instant
  until yield
    return false if (Time.instant - started).total_seconds > deadline_s
    Intrinsics.pause
  end
  true
end

# ── Children ────────────────────────────────────────────────────────────────
arm = ARGV.find(&.starts_with?("--child="))
if arm
  case arm.lchop("--child=")
  when "no-tls"
    heap = Gcry.default_heap.not_nil!
    before = heap.stw_suspend_no_tls
    listed_before = 0
    Thread.unsafe_each { listed_before += 1 }
    tid = start_raw_thread
    # Let it reach its loop. Nothing here depends on the timing; the raw
    # thread has no TLS whether it has started spinning or not.
    sleep 100.milliseconds

    # Exactly what a stop does to a thread, in the same order: list mutex
    # held, slot reserved, epoch open, then the signal.
    Thread.lock
    slot = Gcry::Platform.reserve_suspend_slot(tid)
    Gcry::Platform.begin_stop_epoch
    LibRawThread.pthread_kill(tid, Gcry::Platform::STW_SIG_SUSPEND)
    acked = spin_until(5.0) { Gcry::Platform.suspend_acked?(slot) }
    Gcry::Platform.end_stop_epoch
    LibRawThread.pthread_kill(tid, Gcry::Platform::STW_SIG_RESUME)
    woke = spin_until(5.0) { !Gcry::Platform.suspend_acked?(slot) }
    Thread.unlock

    # A handler that was blocked on the list mutex gets to finish here, so
    # the count below sees whatever it did.
    sleep 300.milliseconds
    listed_after = 0
    Thread.unsafe_each { listed_after += 1 }

    # No join: on the pre-table path the raw thread ends up parked in
    # `sigsuspend` on a `Thread` object nobody is watching, and waiting for
    # it would turn a measurement into a hang.
    RAW_RUN.value = 0
    puts "slot=#{slot} acked=#{acked} woke=#{woke} " \
         "no_tls_delta=#{heap.stw_suspend_no_tls - before} " \
         "listed_delta=#{listed_after - listed_before} " \
         "ack_unavailable=#{heap.stw_suspend_ack_unavailable}"
    exit 0
  when "churn"
    stop = Atomic(Int32).new(0)
    2.times do
      Thread.new do
        sink = [] of String
        while stop.get == 0
          sink << "x" * 32
          sink.clear if sink.size > 256
        end
      end
    end
    CHURN_ROUNDS.times do
      born = [] of Thread
      CHURN_BATCH.times { born << Thread.new { } }
      GC.collect
      born.each(&.join)
    end
    stop.set(1)
    heap = Gcry.default_heap.not_nil!
    puts "collections=#{heap.collections} threads=#{CHURN_ROUNDS * CHURN_BATCH} " \
         "no_tls=#{heap.stw_suspend_no_tls} " \
         "ack_unavailable=#{heap.stw_suspend_ack_unavailable} " \
         "handler_calls=#{Gcry::Platform.stw_handler_calls}"
    exit 0
  else
    abort "unknown arm"
  end
end

# ── Parent ──────────────────────────────────────────────────────────────────
self_path = Process.executable_path || "bin/stw_ack_window"

def run(self_path : String, child : String, env : Hash(String, String),
        timeout_s : Int32 = TIMEOUT_S) : {Bool, String}
  sink = IO::Memory.new
  process = Process.new(self_path, ["--child=#{child}"], env: env,
    output: sink, error: Process::Redirect::Inherit)
  reaped = Channel(Process::Status).new(1)
  spawn { reaped.send(process.wait) }
  ok = true
  select
  when status = reaped.receive
    ok = status.success?
  when timeout timeout_s.seconds
    ok = false
    process.signal(:kill)
    reaped.receive
  end
  {ok, sink.to_s.strip}
end

puts "=== STW acknowledgement vs the thread birth window ==="
puts "a raw pthread has no `Thread.current` by construction; the churn arm"
puts "runs #{CHURN_ROUNDS} x #{CHURN_BATCH} real births against a collecting heap"
puts ""

fresh_ok, fresh_out = run(self_path, "no-tls", {} of String => String)
old_ok, old_out = run(self_path, "no-tls", {"GCRY_STW_ACK_VIA_THREAD" => "1"})
churn_ok, churn_out = run(self_path, "churn", {} of String => String, 120)

puts "  %-12s %s" % ["no-tls", fresh_ok ? fresh_out : "HUNG/FAILED (killed at #{TIMEOUT_S}s)"]
puts "  %-12s %s" % ["no-tls+old", old_ok ? old_out : "HUNG/FAILED (killed at #{TIMEOUT_S}s)"]
puts "  %-12s %s" % ["churn", churn_ok ? churn_out : "HUNG/FAILED"]
puts ""

def field(line : String, name : String) : String?
  line.match(/#{name}=(\S+)/).try(&.[1])
end

failures = [] of String

if !fresh_ok
  failures << "the shipped path could not suspend a thread with no `Thread.current` — " \
              "that is the birth window, and it is the whole point of the slot table"
else
  failures << "the raw thread never acknowledged: #{fresh_out}" unless field(fresh_out, "acked") == "true"
  failures << "the raw thread never woke: #{fresh_out}" unless field(fresh_out, "woke") == "true"
  if field(fresh_out, "slot") == "-1"
    failures << "no slot was reserved, so the arm exercised the fallback and not the table"
  end
  if (field(fresh_out, "no_tls_delta") || "0") == "0"
    failures << "the handler did not record a delivery without TLS, so it is not looking — " \
                "the counter CI depends on to answer this question is dead"
  end
  if (field(fresh_out, "ack_unavailable") || "0") != "0"
    failures << "a delivery could answer through neither route with one raw thread and an " \
                "empty table — the reservation is not happening"
  end
end

# The control, and it is not a hang: the pre-table handler answers into a
# `Thread` object it has just created, which is not the one the collector is
# watching. The acknowledgement lands where nobody is looking, and the stop
# spins for a thread that has in fact suspended itself.
if !old_ok
  failures << "the pre-table arm did not finish, so what it did cannot be read"
else
  if field(old_out, "acked") == "true"
    failures << "GCRY_STW_ACK_VIA_THREAD=1 acknowledged a thread with no TLS — the pre-table " \
                "path is not being exercised, so the shipped one is not attributable"
  end
  if (field(old_out, "listed_delta") || "0") == "0"
    failures << "the pre-table arm did not add a `Thread` to Crystal's list — " \
                "`::Thread.current` did not take its creating branch, so this arm is not " \
                "the path it claims to restore"
  end
end

if fresh_ok && (field(fresh_out, "listed_delta") || "0") != "0"
  failures << "the shipped path added #{field(fresh_out, "listed_delta")} thread(s) to " \
              "Crystal's list from a signal handler — it is still calling into the runtime"
end

unless churn_ok
  failures << "real thread births against a collecting heap did not survive"
end

if failures.empty?
  puts "PASS — a thread with no `Thread.current` acknowledges through its reserved slot,"
  puts "and the pre-table path cannot."
  puts ""
  puts "What the red arm does, measured rather than argued: `::Thread.current` misses,"
  puts "**allocates a `Fiber` and a `Thread` inside the signal handler**, and pushes it"
  puts "onto `Thread.threads` — `listed_delta=#{field(old_out, "listed_delta")}`. It then sets `@suspended` on"
  puts "that brand-new object. The collector is watching the one already on the list, so"
  puts "the acknowledgement never arrives (`acked=false`) and the stop spins forever for"
  puts "a thread that has in fact suspended itself. That is `phase=suspend`, one thread"
  puts "unacknowledged, handle live — the aarch64 shape."
  puts ""
  churn_no_tls = field(churn_out, "no_tls") || "?"
  puts "Real births landing in the window on this host: #{churn_no_tls}. Reported, not"
  puts "asserted — the window is one store wide (`Thread.threads.push` then"
  puts "`Thread.current =`), so a quiet x86_64 box missing it says nothing about a"
  puts "loaded aarch64 runner. The counter is on `/gc-stats` so CI can answer it."
else
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
