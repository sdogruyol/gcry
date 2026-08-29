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
  lib LibC
    struct GcryRlimit
      rlim_cur : ULong
      rlim_max : ULong
    end

    fun setrlimit(resource : Int, rlim : GcryRlimit*) : Int
  end

  RLIMIT_AS = 9
{% end %}

# Enough for the runtime and a few hundred chunks, far less than the child
# wants. Too small and the cap bites during startup, which tests nothing.
CAP_BYTES = 512_u64 * 1024 * 1024

if ARGV.includes?("--child")
  {% if flag?(:linux) %}
    lim = LibC::GcryRlimit.new
    lim.rlim_cur = LibC::ULong.new(CAP_BYTES)
    lim.rlim_max = LibC::ULong.new(CAP_BYTES)
    if LibC.setrlimit(RLIMIT_AS, pointerof(lim)) != 0
      STDOUT.puts "child: setrlimit failed"
      exit 3
    end
  {% end %}

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

puts ""
if failures.empty?
  puts "ok — the allocator refuses and says so, on both size paths"
  exit 0
else
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
