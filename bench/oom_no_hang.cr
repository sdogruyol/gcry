# Does running out of address space produce an error, or a hang?
#
# It produced a hang. `map_chunk` raised `OutOfMemoryError` when `mmap`
# refused — and every caller holds a non-reentrant `Crystal::SpinLock` across
# that call (`alloc_large` inside `with_alloc_lock`, `refill_size_class` inside
# the size-class freelist lock), while `raise` in Crystal *allocates*: it fills
# in `exception.callstack ||= Exception::CallStack.new`, a `CallStack` is an
# `Array`, and that `Array` goes straight back into `allocate` and asks for the
# lock the raising thread is already holding. Deterministic self-deadlock:
# **5 of 5** children spinning at 100% CPU with no output and no error, the
# collector's own `SpinLock#lock` under `CallStack#unwind` under `raise`.
#
# Two more layers sat behind it, each of which took over once the one in front
# was fixed:
#
#   - an emergency collection from inside `map_chunk` deadlocks the same way
#     (the after-world sweep takes the freelist lock, `flush_pending_large_release`
#     opens with `with_alloc_lock`);
#   - a collection *allocates* — `ensure_static_root_cache` parses
#     `/proc/self/maps` — so an unguarded retry recurses through
#     `run_collection` until the stack overflows;
#   - and the raise itself recurses: 174 frames of
#     `raise → CallStack → Array → allocate → raise` before the overflow.
#
# So the property this gate holds is small and worth stating plainly: **a
# process that runs out of address space must report it and stop, not spin.**
# The child caps its own `RLIMIT_AS` and retains everything it allocates, so no
# collection can help; the parent gives it a deadline. A killed child is the
# failure this exists to catch.
#
#   crystal build -Dgc_none bench/oom_no_hang.cr -o bin/oom_no_hang
#   bin/oom_no_hang

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "oom_no_hang requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% if flag?(:linux) %}
  # `LibC::Rlimit` and `setrlimit` come with the collector
  # (src/gcry/platform/linux_stack.cr, which re-reads RLIMIT_STACK).
  RLIMIT_AS = 9
{% end %}

# Enough for the runtime and a few hundred chunks, far less than the child
# wants. Too small and the cap bites during startup, which tests nothing.
CAP_BYTES = 512_u64 * 1024 * 1024
# The parallel arm's cap: room for three workers' runtimes and their arrays.
PARALLEL_CAP_BYTES = 1536_u64 * 1024 * 1024

if ARGV.includes?("--child")
  {% if flag?(:linux) %}
    lim = LibC::Rlimit.new
    cap = ARGV.includes?("--parallel") ? PARALLEL_CAP_BYTES : CAP_BYTES
    lim.rlim_cur = LibC::RlimT.new(cap)
    lim.rlim_max = LibC::RlimT.new(cap)
    if LibC.setrlimit(RLIMIT_AS, pointerof(lim)) != 0
      STDOUT.puts "child: setrlimit failed"
      exit 3
    end
  {% end %}

  if ARGV.includes?("--parallel")
    # Three fibers on a Parallel context run the space out together. The
    # parent sets `GCRY_OOM_TEST_EXHAUSTED=1`: once one allocation has failed,
    # every small allocation a report does not make fails too, so each report
    # has to be allocated from the reserve — on every run, not only when the
    # classes it uses happen to be dry. Nothing else may allocate from then
    # on, so the workers park instead of finishing (a finished fiber goes
    # back through the scheduler) and the main fiber prints without the heap.
    ctx = Fiber::ExecutionContext::Parallel.new("oom", 3)
    reports = Channel(Int32).new(3)
    messages = Array(String?).new(3, nil)
    3.times do |w|
      ctx.spawn do
        held = [] of Bytes
        begin
          loop { held << Bytes.new(4096) }
        rescue ex : Gcry::OutOfMemoryError
          held.clear
          messages[w] = ex.message
          reports.send w
          sleep
        end
      end
    end
    3.times { reports.receive }
    buf = uninitialized UInt8[Gcry::RawOut::LIMIT]
    n = Gcry::RawOut.append(buf.to_unsafe, 0, "child: reserve allocations ")
    n = Gcry::RawOut.append_u64(buf.to_unsafe, n, Gcry.default_heap.oom_reserve_allocations)
    n = Gcry::RawOut.append(buf.to_unsafe, n, "\n")
    messages.each do |m|
      n = Gcry::RawOut.append(buf.to_unsafe, n, "child: OutOfMemoryError: ")
      n = Gcry::RawOut.append(buf.to_unsafe, n, m || "(no message)")
      n = Gcry::RawOut.append(buf.to_unsafe, n, "\n")
    end
    Gcry::RawOut.flush(buf.to_unsafe, n)
    LibC._exit(0)
  end

  kind = ARGV.includes?("--small") ? "small" : "large"
  size = kind == "large" ? 40 * 1024 : 128

  # Retained on purpose: a collection can free nothing, so the allocator has to
  # reach its refusal rather than collect its way out.
  keep = [] of Bytes
  n = 0
  begin
    loop do
      keep << Bytes.new(size)
      n += 1
    end
  rescue ex : Gcry::OutOfMemoryError
    # Printing goes through the allocator too, and at this point there is no
    # memory to print with — so say the least that identifies the path.
    STDOUT.puts "child: OutOfMemoryError"
    STDOUT.flush
    exit 0
  end
  exit 4
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!

puts "=== out of address space: error, or hang? ==="
puts "child caps RLIMIT_AS at #{CAP_BYTES // (1024 * 1024)} MiB and retains everything"
puts ""

failures = [] of String

{"large" => ["--child"], "small" => ["--child", "--small"]}.each do |arm, args|
  hung = 0
  bad = 0
  note = nil
  3.times do
    result = BoundedChild.run(exe, args, {} of String => String, 60.seconds)
    if result.timed_out
      hung += 1
    elsif !result.output.includes?("OutOfMemoryError") &&
          !result.output.includes?("out of memory") &&
          !result.output.includes?("mmap failed")
      bad += 1
      note ||= result.output.lines.first?
    end
  end
  puts "  #{arm}: #{hung} of 3 hung, #{bad} of 3 ended without naming the failure" \
       "#{note ? "\n     #{note.strip}" : ""}"
  failures << "#{arm}: #{hung} of 3 children were killed on the deadline — running out of " \
              "address space must not wedge the allocator" if hung > 0
  failures << "#{arm}: #{bad} of 3 children ended without an out-of-memory report" if bad > 0
end

# Parallel, with every small class exhausted after the first failure
# (`GCRY_OOM_TEST_EXHAUSTED=1`): each worker must get its own error with its
# own message, allocated from the reserve. The prebuilt nested-raise error
# means a report ran out of reserve; a signal or the abort line means the
# report could not be made at all.
exhausted = {"GCRY_OOM_TEST_EXHAUSTED" => "1"}
clean_report = ->(r : BoundedChild::Result) {
  r.ok && r.output.scan("child: OutOfMemoryError: ").size == 3 &&
  !r.output.includes?("nested raise") && !r.output.includes?("(no message)") &&
  !r.output.includes?("child: reserve allocations 0\n")
}
p_bad = 0
p_note = nil
3.times do
  r = BoundedChild.run(exe, ["--child", "--parallel"], exhausted, 90.seconds)
  next if clean_report.call(r)
  p_bad += 1
  p_note ||= r.timed_out ? "killed on the deadline" : r.output.lines.first?
end
puts "  parallel, exhausted: #{p_bad} of 3 without three clean reports" \
     "#{p_note ? "\n     #{p_note.strip}" : ""}"
failures << "parallel, exhausted: #{p_bad} of 3 children did not report every error from the reserve" if p_bad > 0

# Red direction, every run, both defects this arm exists for. With the reserve
# off the report cannot be allocated and the prebuilt error's own raise cannot
# be either: the abort line, every time. With the message built by the caller,
# before `oom!` is entered — every call site before 2026-09-24 — building it
# fails, asks the allocator, fails and builds it again, until the stack
# overflows: a signal or the deadline, every time.
no_reserve = 0
3.times do
  r = BoundedChild.run(exe, ["--child", "--parallel"], exhausted.merge({"GCRY_OOM_RESERVE_KB" => "0"}), 90.seconds)
  no_reserve += 1 if r.output.includes?("out of memory while reporting out of memory")
end
puts "  parallel, exhausted, GCRY_OOM_RESERVE_KB=0: #{no_reserve} of 3 aborted unable to report"
failures << "red arm: #{3 - no_reserve} of 3 children reported without the reserve — " \
            "the reports no longer need it, so the arm above proves nothing" if no_reserve < 3
eager = 0
3.times do
  r = BoundedChild.run(exe, ["--child", "--parallel"], exhausted.merge({"GCRY_OOM_EAGER_MESSAGE" => "1"}), 90.seconds)
  eager += 1 if r.timed_out || (!r.ok && !clean_report.call(r) && !r.output.includes?("while reporting"))
end
puts "  parallel, exhausted, GCRY_OOM_EAGER_MESSAGE=1: #{eager} of 3 died on a signal or hung"
failures << "red arm: #{3 - eager} of 3 children survived the message built before oom! — " \
            "this workload no longer reaches that recursion" if eager < 3

puts ""
if failures.empty?
  puts "ok — the allocator refuses and says so, on both size paths"
  exit 0
else
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
