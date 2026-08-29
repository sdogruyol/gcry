# Can a post-STW flush walk step onto a chunk a mutator is unmapping?
#
# `flush_pending_dormant_chunks`, `flush_pending_page_release_chunks` and
# `flush_pending_mostly_empty_chunks` all run *after* `start_world`, with every
# mutator live, and all three walk `@chunks` holding nothing. The comment at
# the call site says they are "still under post-STW mutex" — but that mutex
# only serialises collectors against each other. No mutator ever takes it.
#
# A mutator does reach the chunk list from outside: `GC.free` of a large object
# calls `trim_large_cache`, which unlinks chunks and `munmap`s them. (Crystal's
# own GMP binding installs `GC.free` as libgmp's free hook, so any program that
# touches BigInt gets there without ever writing `GC.free` itself.)
#
# So the walk can dereference `chunk.value` on a chunk that is already gone.
# The segfault is the *mild* outcome. `madvise(MADV_DONTNEED)` computed from a
# stale header and issued after the kernel has handed that range to somebody
# else's `mmap` zeroes live memory belonging to another allocation, silently.
#
#   workers    allocate a large block, write it, verify it, GC.free it
#   collector  GC.collect in a loop, so the flush walks never stop
#   ballast    many small objects, so the walk is long and the window is wide
#
# `GCRY_MOSTLY_EMPTY=1` is what keeps the third walk from returning early; it
# is the one that visits every chunk regardless of flags, because the filters
# (`sparse?`, `large?`, `dormant?`) all read `chunk.value` *before* deciding to
# skip. Reading the header is the unsafe act, not the madvise.
#
# `GCRY_UNMAP_GUARD=1` turns the munmap into `mprotect(PROT_NONE)`, so a walk
# that steps onto a released chunk faults on the spot and the report names the
# chunk instead of the crash landing somewhere else later.
#
#   crystal build -Dgc_none bench/dormant_flush_race.cr -o bin/dormant_flush_race
#   bin/dormant_flush_race

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "dormant_flush_race requires -Dgc_none (gcry as process GC)" %}
{% end %}

# yama `ptrace_scope=1` lets only an ancestor attach, and the hang catcher
# (`bench/log/linux/2026-08-27-stw-write-protocols/hang_catch.sh`) runs `gdb -p`
# from a sibling shell. Every capture it took came back "ptrace: Operation not
# permitted", which is a hang that stays unnamed. `PR_SET_PTRACER_ANY` is the
# child's own consent to be inspected; armed by knob, so a normal gate run is
# not made debuggable by anyone on the box.
{% if flag?(:linux) %}
  lib LibC
    fun prctl(option : Int, arg2 : ULong, arg3 : ULong, arg4 : ULong, arg5 : ULong) : Int
  end

  PR_SET_PTRACER = 0x59616d61
{% end %}

PAYLOAD = 40_u64 * 1024
WORKERS =       4
ROUNDS  =  10_000
BALLAST =  40_000
FILL    = 0x5C_u8

class Verdict
  @@corrupt = Atomic(Int32).new(0)
  @@done = Atomic(Int32).new(0)

  def self.corrupt!
    @@corrupt.add(1)
  end

  def self.corrupt
    @@corrupt.get
  end

  def self.finish
    @@done.add(1)
  end

  def self.finished
    @@done.get
  end
end

# Held only in a class variable, and checked from the main thread while the
# workers churn. If gcry loses the executable's BSS from its static roots — and
# that is a parse of `/proc/self/maps`, a file that is not a snapshot — then
# nothing holds this and it is swept like garbage. Checking a pattern rather
# than the pointer is deliberate: the reference stays valid-looking, it is the
# bytes underneath that change once the block is handed out again.
class Stash
  PATTERN = 0xAB_u8
  SIZE    =    4096

  @@held : Bytes? = nil

  def self.fill : Nil
    b = Bytes.new(SIZE)
    i = 0
    while i < SIZE
      b[i] = PATTERN
      i += 1
    end
    @@held = b
  end

  def self.damaged? : Bool
    b = @@held
    return true if b.nil?
    i = 0
    while i < SIZE
      return true if b[i] != PATTERN
      i += 64
    end
    false
  end
end

if ARGV.includes?("--child")
  heap = Gcry.default_heap
  Stash.fill

  # Crystal installs its own handler during `GC.init`, so gcry's has to be armed
  # here, in the child, rather than anywhere inside the heap's own startup.
  # Without it a fault prints an address and nothing that locates it.
  Gcry::SegvReport.install if ENV["GCRY_SEGV_REPORT"]? == "1"

  {% if flag?(:linux) %}
    LibC.prctl(PR_SET_PTRACER, UInt64::MAX, 0_u64, 0_u64, 0_u64) if ENV["GCRY_ANY_PTRACER"]? == "1"
  {% end %}

  # A long chunk list: the flush walks visit every one of these, so the window
  # in which a peer can unmap something the walk has not reached yet is as wide
  # as the list is long. Keep them reachable so the sweep cannot shorten it.
  ballast = Array(Bytes).new(BALLAST)
  BALLAST.times { ballast << Bytes.new(256) }
  STDOUT.puts "child: ballast built #{ballast.size} at 0x#{ballast.object_id.to_s(16)}" if ENV["GCRY_BALLAST_TRACE"]? == "1"

  threads = [] of Thread
  WORKERS.times do
    threads << Thread.new do
      begin
        ROUNDS.times do
          p = GC.malloc_atomic(PAYLOAD)
          bytes = p.as(UInt8*)
          i = 0_u64
          while i < PAYLOAD
            bytes[i] = FILL
            i += 64
          end
          i = 0_u64
          while i < PAYLOAD
            Verdict.corrupt! if bytes[i] != FILL
            i += 64
          end
          GC.free(p)
        end
      ensure
        # **`ensure`, and that is the whole of this gate's silent-hang family.**
        #
        # A worker that dies of the corruption this arm exists to produce —
        # `Thread.new` stores the exception and re-raises it at `join`, it
        # prints nothing on its own — used to leave the count one short
        # forever. Both waiters spin on it: the collector's
        # `until Verdict.finished >= WORKERS` and the main thread's poll loop.
        # The child then collects forever with every mutator frozen, produces
        # no output, and dies on the deadline: no fault, no watchdog line
        # (every stop completes, so no phase is ever stalled), nothing to read.
        # Measured on three wedged children under `gdb`: zero worker threads
        # alive and `Verdict::done` reading 3, 3 and 1 of 4.
        #
        # Counting the death lets both waiters finish and `join` re-raise, so
        # the arm faults with a named exception instead of hanging.
        Verdict.finish
      end
    end
  end

  collector = Thread.new do
    until Verdict.finished >= WORKERS
      GC.collect
    end
  end

  # The class-variable canary, watched from the main thread. Diagnostics from a
  # bare `Thread.new` raise (`Thread#execution_context cannot be nil`), which is
  # how two results in this family were silently invalidated before; the main
  # thread has a context and can print.
  # `ballast` is read on every turn on purpose. Without a use inside this loop
  # the only reference to a 40,000-element array sat in a frame slot nothing
  # touched until the final `puts`, and it was collected: the run printed
  # `ballast 0` and the long chunk list this bench exists to build was not
  # there. A watcher that quietly disables the thing it watches is worse than
  # no watcher.
  stash_damaged = false
  ballast_seen = 0
  # A `pointerof(ballast)` probe used to sit here. It is gone on purpose: taking
  # the address forces the local into a stack slot for the whole function, the
  # collector then sees it, and the loss this bench exists to reproduce goes
  # away. The reading it produced is in
  # `bench/log/linux/2026-08-26-debug-build-own-stack-root/FINDINGS.md`.
  until Verdict.finished >= WORKERS
    ballast_seen = ballast.size
    if Stash.damaged?
      stash_damaged = true
      STDOUT.puts "child: STASH DAMAGED — an object held only in a class variable was collected"
      STDOUT.flush
      break
    end
  end

  STDOUT.puts "child: ballast before join #{ballast.size} at 0x#{ballast.object_id.to_s(16)}" if ENV["GCRY_BALLAST_TRACE"]? == "1"
  threads.each(&.join)
  collector.join
  stash_damaged ||= Stash.damaged?

  # `live_blocks` / `skipped_runs` are the **precursor**, and they are printed
  # because the crash is not measurable on this arm: the same binary gave 2 of
  # 40 and 11 of 60 across batches, which is wider than any fix being looked
  # for (`bench/log/linux/2026-08-26-page-release-unlink/FINDINGS.md`).
  #
  # A live block found inside a run the mask called free is the mask being
  # wrong, observed directly, whether or not this particular child goes on to
  # crash. It is a denser signal by orders of magnitude and it does not depend
  # on the kernel choosing to reclaim a `MADV_FREE`d page.
  # Type ids are per-binary, so the id `GCRY_DYING_TYPE_ID` needs has to come
  # from this binary. The crash this bench produces is `Thread.lock` reading a
  # null through the runtime's thread list, so those are the types to aim at.
  if ENV["GCRY_PRINT_TYPE_IDS"]? == "1"
    STDOUT.puts "type_id Thread::Mutex #{Thread::Mutex.new.crystal_type_id}"
    STDOUT.puts "type_id Thread::LinkedList #{Thread::LinkedList(Thread).new.crystal_type_id}"
    STDOUT.puts "type_id Thread #{Thread.current.crystal_type_id}"
    STDOUT.puts "type_id Array(Bytes) #{Array(Bytes).new(1).crystal_type_id}"
  end

  # `rel_remapped` is the double-release tripwire's engagement counter: if it
  # reads 0 while `rel_double` is high, the tripwire is counting reuse it
  # failed to observe, not a defect. (A comment placed *inside* the `\`
  # continuation below silently drops the literal that follows it.)
  puts "child: #{Verdict.corrupt} corrupt verifies, walks #{heap.live_walk_spans}, " \
       "queued #{heap.live_walk_queued}, direct #{heap.live_walk_direct}, " \
       "live_blocks #{heap.page_release_live_blocks}, skipped_runs #{heap.page_release_skipped_runs}, " \
       "ballast #{ballast.size} at 0x#{ballast.object_id.to_s(16)}, " \
       "rel_double #{heap.release_double}, rel_remapped #{heap.release_remapped}, " \
       "dying_walked #{heap.dying_type_walked}, dying_live #{heap.dying_type_live}, " \
       "dying_deaths #{heap.dying_type_deaths}, " \
       "tl_max #{heap.thread_list_seen_max}, tl_empty #{heap.thread_list_empty}, " \
       "tlw_hits #{Gcry::ThreadListWatch.hits}, " \
       "root_shrinks #{Gcry::Platform.static_root_shrinks}, bss_lost #{Gcry::Platform.static_root_bss_lost}, " \
       "stash_damaged #{stash_damaged}, ballast_seen #{ballast_seen}, " \
       "greg_candidates #{heap.thread_greg_candidates}, greg_total #{heap.thread_greg_words_total}, " \
       "handler_calls #{Gcry::Platform.stw_handler_calls}, sp_zero #{Gcry::Platform.stw_sp_zero}, " \
       "records #{Gcry::Platform.stw_records}, " \
       "staged_waits #{heap.stw_staged_waits}, staged_timeouts #{heap.stw_staged_wait_timeouts}, " \
       "static_min #{heap.static_scanned_min}, static_max #{heap.static_scanned_max}, " \
       "static_drops #{heap.static_scanned_drops}, " \
       "win_empty #{heap.mutator_window_empty}, win_max #{heap.mutator_window_max}, " \
       "fib_sp #{heap.fiber_scan_from_sp}, fib_guard #{heap.fiber_scan_from_guard}, " \
       "fib_stale #{heap.fiber_scan_running_stale}"
  exit(Verdict.corrupt > 0 ? 1 : 0)
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
attempts = (ENV["DORMANT_FLUSH_RACE_ATTEMPTS"]?.try(&.to_i?) || 6)

puts "=== post-STW flush walk vs. mutator unmap ==="
puts "#{WORKERS} workers × #{ROUNDS} rounds of #{PAYLOAD} B, one collector, #{BALLAST} ballast objects"
puts ""

# Bounded, and hangs counted apart from faults — see the same change in
# `page_release_corruption.cr`. A bare `Process.run` with no deadline turns a
# hung child into a hung gate, and a hung gate reads as a slow one; that is how
# the stop-the-world hang fixed in 0.21.1 stayed invisible for a day.
def run(exe : String, env, attempts : Int32) : {Int32, Int32, String?}
  bad = 0
  hung = 0
  first = nil
  attempts.times do
    result = BoundedChild.run(exe, ["--child"], env)
    unless result.ok
      bad += 1
      hung += 1 if result.timed_out
      # A worker that dies now re-raises at `join`, so the line worth quoting
      # is often Crystal's unhandled-exception header rather than a gcry
      # report or a SEGV.
      first ||= result.output.lines.find do |l|
        l.includes?("gcry:") || l.includes?("Invalid memory access") ||
          l.includes?("Unhandled exception")
      end
    end
  end
  {bad, hung, first}
end

base = {"GCRY_MOSTLY_EMPTY" => "1", "GCRY_UNMAP_GUARD" => "1", "GCRY_SEGV_REPORT" => "1"}
immediate = base.merge({"GCRY_TRIM_IMMEDIATE" => "1"})

failures = [] of String

queued_bad, queued_hung, queued_note = run(exe, base, attempts)
puts "  queued (default):    #{queued_bad} of #{attempts} failed" \
     "#{queued_hung > 0 ? " (#{queued_hung} timed out)" : ""}" \
     "#{queued_note ? "\n     #{queued_note.strip}" : ""}"

immediate_bad, immediate_hung, immediate_note = run(exe, immediate, attempts)
puts "  immediate (old):     #{immediate_bad} of #{attempts} failed" \
     "#{immediate_hung > 0 ? " (#{immediate_hung} timed out)" : ""}" \
     "#{immediate_note ? "\n     #{immediate_note.strip}" : ""}"

# A killed child says nothing, but the two arms need that nothing differently.
# A queued-arm hang is a defect on the arm being gated — fatal. A control-arm
# hang only weakens the control, and the check below already demands the
# control produce at least one *genuine* fault: with that satisfied, a hung
# control child cannot turn a clean queued arm into a red run. This is what
# took the gate out of CI on its first day back — a two-core runner hung 3 of
# 6 TRIM_IMMEDIATE children while the queued arm read 0 of 6 and the control
# still faulted for real.
if queued_hung > 0
  failures << "#{queued_hung} queued-arm child(ren) were killed on the deadline — a killed child " \
              "says nothing about whether a flush walk meets a released chunk. " \
              "Re-run with GCRY_STW_WATCHDOG_MS set"
end
if immediate_hung > 0
  puts "  note: #{immediate_hung} control child(ren) killed on the deadline — counted as " \
       "neither fault nor pass; the control stands on its faulting children alone"
end
failures << "the queued arm faulted #{queued_bad - queued_hung} of #{attempts} — a flush walk still meets a released chunk" if queued_bad - queued_hung > 0
if immediate_bad - immediate_hung == 0
  failures << "the immediate arm survived #{attempts} attempts, so this harness does not reach the race " \
              "and the queued arm's silence is not evidence"
end

puts ""
if failures.empty?
  puts "ok — queued, the walks never meet a released chunk; unqueued, they do"
  exit 0
else
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
