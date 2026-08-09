# Where does the parked-fiber wipe start destroying live data?
#
# `bench/scrub_audit.cr` closed one half of the scrub question: across EC1 and
# EC4 the window never reached a *foreign thread's* live frames, because every
# SP sighting was on a fiber still reporting `running?`. It could not close the
# other half — whether a pointer can live only inside the wiped region of a
# genuinely parked fiber — and the reason is structural: for a parked fiber,
# `@context.stack_top` is the only record of its SP. There is nothing
# independent to check the window against.
#
# So don't check it. Locate the boundary instead.
#
# `GCRY_SCRUB_OVERSHOOT=N` slides the wipe window up by N bytes, over
# `stack_top` and into frames that must be live. Sweeping N gives:
#
#   * a **positive control** — some N must corrupt, or the workload is not
#     sensitive enough to detect corruption and every "clean" result here is
#     worthless. This is the check `scrub_audit` was missing when it reported
#     zero foreign-SP scrubs with the guard deliberately off.
#   * the **margin** — the smallest N that breaks is how far the shipping
#     window sits from live data on this workload.
#
# Each trial runs in a child process: the expected outcome is a crash, and the
# parent has to survive to report it.
#
#   crystal build -Dgc_none bench/scrub_margin.cr -o bin/scrub_margin
#   bin/scrub_margin                       # sweep the default ladder
#   bin/scrub_margin --overshoot=0         # single value (used as the child)
#
# Exits non-zero when overshoot 0 corrupts (a real defect) or when *nothing*
# corrupts (the workload cannot detect corruption, so the run proves nothing).

require "../src/gcry"

# Fine around 56: that is where the boundary sits on x86_64-sysv, and it is not
# an arbitrary number — `swapcontext` saves 6 callee-saved registers plus the
# return address above the SP it records in `@context.stack_top`, i.e. 7 words.
# The wipe window ends exactly where those begin.
OVERSHOOTS = [0, 8, 16, 32, 40, 48, 56, 60, 64, 128, 512, 4096]

# ── Child mode: one overshoot value, one verdict ─────────────────────────────
#
# The fibers below each hold a checked value in a local and yield across a
# collection, so a wipe that reaches a live frame shows up as a wrong value
# rather than only as a segfault. Both count as corruption; the checksum path
# is what makes a *silent* wipe visible.
def run_trial(fibers : Int32, rounds : Int32) : Int32
  bad = 0
  done = Channel(Int32).new(fibers)

  fibers.times do |i|
    spawn do
      # Locals the compiler must keep on the stack across the yields below.
      guard_a = "fiber-#{i}-a"
      guard_b = Array(Int32).new(8) { |k| i * 100 + k }
      sum = guard_b.sum
      rounds.times do
        Fiber.yield
        # Reading after a park+collect: if the wipe crossed stack_top, one of
        # these is either garbage or a dangling reference.
        bad += 1 unless guard_a == "fiber-#{i}-a"
        bad += 1 unless guard_b.sum == sum
      end
      done.send(bad)
    end
  end

  collector = spawn do
    (rounds * 2).times do
      GC.collect
      Fiber.yield
    end
  end
  _ = collector

  total = 0
  fibers.times { total += done.receive }
  total
end

single = ARGV.find(&.starts_with?("--overshoot="))
if single
  n = single.split("=", 2)[1].to_i
  Gcry.default_heap.scrub_fibers_enabled = true
  Gcry.default_heap.scrub_overshoot_bytes = n.to_u64
  bad = run_trial(64, 40)
  puts "overshoot=#{n} mismatches=#{bad}"
  exit(bad == 0 ? 0 : 2)
end

# ── Parent mode: sweep, each value in its own process ────────────────────────
self_path = Process.executable_path || "bin/scrub_margin"
puts "=== Parked-fiber scrub margin ==="
puts "sweeping GCRY_SCRUB_OVERSHOOT; each trial is a child process"
puts "  64 fibers × 40 park/collect rounds, scrub forced on"
puts ""

results = {} of Int32 => String
OVERSHOOTS.each do |n|
  status = Process.run(self_path, ["--overshoot=#{n}"],
    output: Process::Redirect::Close, error: Process::Redirect::Close)
  # A signal death has no exit code — reading one raises. That is the *expected*
  # outcome for most of this ladder, so the parent has to branch on how the
  # child died before asking why.
  verdict =
    if status.success?
      "clean"
    elsif status.normal_exit?
      status.exit_code == 2 ? "CORRUPT (checksum)" : "CORRUPT (exit #{status.exit_code})"
    else
      "CORRUPT (#{status.exit_signal})"
    end
  results[n] = verdict
  puts "  overshoot=%5d  %s" % [n, verdict]
end
puts ""

failures = [] of String

# 1. The shipping window must be clean. This is the only assertion that is
#    about the collector rather than about the instrument.
if results[0] != "clean"
  failures << "overshoot=0 (the shipping window) corrupted — the wipe reaches live frames"
end

# 2. Something must corrupt, or this workload cannot see corruption and every
#    "clean" above is uninformative. A green that is reachable without
#    observing anything is what made the first scrub audit worthless.
broke = results.reject { |n, v| n == 0 || v == "clean" }
if broke.empty?
  failures << "no overshoot corrupted, up to #{OVERSHOOTS.max} bytes — no positive " \
              "control, so the clean result at 0 means nothing"
else
  first = broke.keys.min
  last_clean = results.select { |n, v| v == "clean" }.keys.max
  puts "margin: clean through #{last_clean} bytes, first corruption at #{first}"
  puts ""
  puts "That margin is the whole finding. On x86_64-sysv `swapcontext` saves six"
  puts "callee-saved registers plus the return address above the SP it records,"
  puts "so live data begins ~56 bytes above `stack_top` and the wipe window ends"
  puts "exactly there. There is no slack: the scrub is correct only while"
  puts "`@context.stack_top` is exact, every time, on every platform."
end

if failures.empty?
  puts "PASS"
else
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
