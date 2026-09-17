# The gate the record said existed: stack-bounds coverage past 64 threads

**Date:** 2026-09-16 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.4
Tree `f7df724` · Crystal 1.21.0 · `bench/stack_bounds_growth.cr`

Second of the conditions the orphan-knob matrix left without a harness
(`../2026-09-16-orphan-break-knobs/`). This one is different from the first: the
record says its gate already existed.

## The claim, and what was there

`ROADMAP.md` said of the stack-bounds table:

> Gated in `process_spec` above the initial capacity and broken on purpose with
> `GCRY_STACK_BOUNDS_NOGROW=1` (red at `visited=150 read=130`).

`GCRY_STACK_BOUNDS_NOGROW` appeared in no `spec/`, no `bench/`, no recipe and no
CI step. The break was real when it was measured; nothing re-checked it, and the
sentence went stale in place — the exact arrangement the gate-arm audit counted
19 times.

## What the table is for

The root scan cannot call `pthread_getattr_np` with the world stopped: that is
the 2026-08-10 hang, six hours of a runner in `sigsuspend`. Bounds are
snapshotted before the stop and looked up from a table inside it, and that table
was a fixed **64** slots (`STACK_BOUNDS_INITIAL_SLOTS`, still 64, doubling now).
Past 64 live threads the snapshot visited threads it had nowhere to record, and
their OS stacks were not scanned.

Three counters carry it, all on `/gc-stats`: `stack_bounds_visited`,
`stack_bounds_read`, `stack_bounds_capacity_misses`.

## `make stack-bounds-growth`

| arm | threads held | visited | read | misses | required |
|---|---|---|---|---|---|
| hold | 100 | 204 | **204** | 0 | `read == visited`, no misses |
| `--control` | 8 | 20 | 20 | 0 | same, inside the initial 64 |
| `--nogrow` | 100, table frozen | 204 | **128** | **76** | `read < visited` **and** `misses > 0` |

204 is two collections over ~102 live threads; 128 is two collections over the
frozen 64. The `--nogrow` arm requires **both** halves, and that is the design
rather than belt-and-braces: a frozen table that also stopped counting would
report full coverage of a smaller process, which is precisely what the pre-fix
counters did — `docs/HARDENING.md` records 82 threads reading `visited=64
read=64`, "full coverage, said the pair whose whole job is to report a gap". The
visit is counted before the read now, so the pair cannot agree by omission. The
doc row is updated to say which counting each of the two measurements belongs
to, since side by side they otherwise look like a contradiction.

`--control` is not decoration either: it holds fewer threads than the initial
capacity, where the fixed table was always sufficient, so the hold arm's
equality is attributable to *growth* and not to two counters that agree
trivially.

Every thread is held live across both collections on an atomic release flag. A
harness whose workers finish early is not visited, and would quietly be the
control arm under another name.

The arm refuses to run as `--nogrow` without `GCRY_STACK_BOUNDS_NOGROW=1`
(exit 64): with the knob absent it would be the shipped growing table being
asked to lose threads it cannot lose.

## What this does not claim

Whether a thread past the 64th ever held the only reference to something.
`ROADMAP.md` has said that is unmeasured since the fix landed and it still is —
the loss was a documented hole in those threads' coverage, not an observed
sweep. This gate asserts the coverage.

Census 85 → 86, 31 per run.

## It took the Darwin job down, and is not enabled there

`darwin_stack.cr` carries the same three counters and the same setter, so the
arms are not Linux-only in principle. In practice the first CI run says
otherwise: on the macOS runner this gate ran **18m37s** (17:55:14 → 18:13:51)
and was cancelled by the job's 20-minute cap, after the two root gates before it
finished in 3 and 4 seconds. Linux x86_64 and aarch64 Linux both passed it in
the same run.

That is the hazard recorded one day earlier about `GCRY_DISABLE_SP_CLAMP` — *"a
red arm that hangs costs a job timeout and reports nothing, which is the failure
mode CI job timeouts were added for"* — walked into by the gate written the next
day.

**The leading suspect is the harness, not the collector.** It held its 100
threads alive on `Thread.sleep(200.microseconds)`, i.e. 100 threads × 5 000
wakeups a second. That is unremarkable on a 20-thread host and plausibly
pathological on a 4-vCPU macOS runner. The poll is now 25 ms, which costs this
harness nothing — the threads only have to exist while two collections happen.

**It is not re-enabled on Darwin.** The fix is untested there, and a gate is not
turned back on against a hypothesis; that is the whole argument this file makes
about the claim it was written to replace. What would settle it is one Darwin
run of `make stack-bounds-growth` with the 25 ms poll, wrapped in `timeout` so a
hang fails the step in a minute instead of cancelling the job — the pattern the
aarch64 job already uses on every gate.

## The bound now lives in the harness, because the CI one did not exist

**2026-09-17.** The first attempt to bound this from CI was `timeout 180 make
stack-bounds-growth` in the Darwin step. macOS has no `timeout(1)`:

    /Users/runner/.../.sh: line 1: timeout: command not found
    ##[error]Process completed with exit code 127

The step ran in **0 seconds** and the API reported it `success`, because
`continue-on-error: true` was on it. So the measurement measured nothing and
said green — the fourth instance in two days of the failure class this whole
line of work is about, this time in the arm whose only job was to produce
evidence. Two rules fall out, and both are now written where they will be read:

- **A gate that can hang must bound itself**, in the harness, on every platform.
  `BoundedChild` already existed for this — it was written after a hung arm took
  an aarch64 job down for 13 minutes — and each arm is now a bounded child of
  the harness, driven by one invocation. `BENCH_CHILD_TIMEOUT_S` moves the
  budget; at 1 s the parent prints `hold (exceeded its budget)` and exits 1,
  which is the positive control for the bound itself.
- **A `continue-on-error` step's conclusion is not evidence.** Only its log is.

One more thing the restructure caught: the three arms used to be selected by
`--control` / `--nogrow` on the parent. After they became child arms, the stale
recipe passing the old flags re-ran the *parent* three times, once with
`GCRY_STACK_BOUNDS_NOGROW` inherited into the hold arm, and reported a failure
that was entirely the invocation's fault. Unknown arguments now exit 64.

## The Darwin reading, and a wrong claim of mine in this file

**2026-09-17.** The measurement ran, the bound held, and it answered two
questions — one of them against what this file said.

    arm hold:    bench: child exceeded 120s and was killed
    arm control: threads held: 8
                 stack_bounds_visited=0 read=0 capacity_misses=0
                 FAIL: the snapshot visited no threads at all …
    arm nogrow:  bench: child exceeded 120s and was killed

**The poll hypothesis is refuted.** 25 ms instead of 200 us, and the 100-thread
arms still exceed 120 s. So the harness's spin was not it.

**And the gate has nothing to assert on Darwin at all.** This file said "the
arms are not Linux-only" because all three platforms declare the same three
counters and the same setter. They declare them **returning zero**:
`darwin_stack.cr` and `windows_stack.cr` query the thread descriptor at lookup
time rather than snapshotting, so `snapshot_pthread_stack_bounds` is a no-op,
`stack_bounds_visited` / `read` / `capacity_misses` are zeros by design and
`stack_bounds_nogrow=` is a no-op setter — the source says so in a comment right
there. I read the signatures and inferred the behaviour, which is the Darwin
`each_thread_greg` stub shape that cost v0.19.0 two platforms' register roots,
made by the person auditing for it. The 8-thread arm reported it plainly and
this harness's own precondition failed on it, which is the one part of the
episode that worked as designed.

The gate is Linux-only by construction, the harness now says so with that
reason instead of failing, and the Darwin arm is removed for cause rather than
for the hang.

## The hang is a separate observation and keeps its own item

Two arms of 100 threads each failed to get all 100 threads *running* inside
120 s — `threads held: 100` never printed, so it is thread startup and not the
collection — while the 8-thread arm was instantaneous and Linux does 100 in
about two seconds. That is a ~60× discrepancy in thread creation on the macOS
runner, twice, and it is no longer this gate's business. Hypothesis worth
testing and not asserted here: `Thread.new` allocates, an allocation can
trigger a collection, and Darwin's stop-the-world suspends each thread with a
per-thread Mach `thread_suspend` / `thread_get_state` rather than one signal
broadcast — so a thread-creation storm would cost O(n²) there and not on Linux.
`ROADMAP.md` carries it.
