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

# The ladder has to be fine wherever the boundary is predicted to sit, and that
# prediction is per-ABI: the margin is the offset of the first word above
# `stack_top` whose value must survive the park, which is a property of what
# `swapcontext` spills and in what order.
#
# x86_64-sysv — spill block is [r15,r14,r13,r12,rbp,rbx,rdi] then the return
# address at +56, SP-at-return +64. The return address is the *last* word, so
# the boundary is 56. Measured: clean through 56, corrupt at 60.
#
# aarch64 — Crystal's `fiber/context/aarch64-generic.cr` spills 22 words, but
# they are not in the same order: [0..7] d15..d8, [8] x30/lr, [9] x29/fp,
# [10..19] x28..x19, [20..21] x0,x1, SP-at-return +176. The return address is
# the *ninth* word, not the last, so two different numbers are defensible and
# the ladder has to separate them:
#
#   64  — the offset of `lr`, if the boundary is "the first word that must
#         survive" (the mechanism that produced 56 on x86_64: the eight words
#         below it there are callee-saved GPRs, here they are callee-saved FP
#         registers, which this workload has no reason to hold a pointer in).
#   176 — `PARKED_AARCH64_SPILL_WORDS * 8`, if the boundary is instead the whole
#         spill block, i.e. every saved register matters.
#
# So: 8-byte steps through 96 to resolve the first, and through 160…192 to
# resolve the second. A result at neither is the interesting one.
#
# Measured (Apple M2 Pro, Darwin 25.5.0 arm64, Crystal 1.21.0, 2026-08-10):
# clean through **64**, first corruption at **72**, deterministic at 3/3 reps
# per rung on an idle machine. So it is the return address, not the spill
# block: 176 is falsified, and `PARKED_AARCH64_SPILL_WORDS = 22` is not wrong —
# it answers a different question (where the caller's SP is), and the step from
# it to a margin was the wrong inference. The crash confirms the mechanism
# rather than merely accompanying it: every failing rung dies at **address
# 0x0**, i.e. a return through a zeroed `lr`.
#
# The rule both ABIs obey: the wipe window ends immediately below the saved
# return address. 56 on x86_64 and 64 on aarch64 are two instances of it. On
# x86_64 the return address happens to be the *last* spilled word, which is why
# "end of block" and "first word that must survive" give the same number there
# and only aarch64 can tell them apart.
{% if flag?(:aarch64) %}
  OVERSHOOTS = [0, 8, 16, 32, 48, 56, 64, 72, 80, 88, 96,
                128, 144, 152, 160, 168, 176, 184, 192, 512, 4096]
{% else %}
  OVERSHOOTS = [0, 8, 16, 32, 40, 48, 56, 60, 64, 128, 512, 4096]
{% end %}

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
  #
  # Not every platform reports it that way. On Darwin the child does not die by
  # signal at all: Crystal's own SIGSEGV handler prints "Invalid memory access
  # (signal 11) at address 0x0" and exits **11**, so the ladder reads
  # `CORRUPT (exit 11)` where Linux reads `CORRUPT (SEGV)`. Both are deaths —
  # the child only ever returns 0 or 2 — which is why the fallthrough below
  # reports an unexpected exit code as corruption rather than trusting it.
  verdict =
    if status.success?
      "clean"
    elsif status.normal_exit?
      status.exit_code == 2 ? "CORRUPT (checksum)" : "CORRUPT (exit #{status.exit_code})"
    else
      "CORRUPT (#{status.exit_signal? || status.exit_reason})"
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
  puts "That margin is the whole finding: the wipe window ends `first` bytes"
  puts "below the first word above `stack_top` that a resumed fiber still needs,"
  puts "and everything below that boundary is spill slots the workload happened"
  puts "not to need — not slack the design reserved. The scrub is correct only"
  puts "while `@context.stack_top` is exact, every time, on every platform."
  puts ""
  {% if flag?(:aarch64) %}
    puts "aarch64: `lr` sits at stack_top+64 and the full spill block is 176"
    puts "bytes (22 words), so 64 and 176 mean different things — see the ladder"
    puts "comment in bench/scrub_margin.cr."
  {% else %}
    puts "x86_64-sysv: the return address is the last word of the spill block,"
    puts "at stack_top+56, with SP-at-return at +64."
  {% end %}
end

if failures.empty?
  puts "PASS"
else
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
