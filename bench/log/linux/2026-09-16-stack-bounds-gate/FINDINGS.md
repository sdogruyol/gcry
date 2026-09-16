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

Second possibility worth keeping in view if the poll turns out not to be it:
Darwin's stop-the-world suspends each thread with Mach `thread_suspend` /
`thread_get_state` rather than a signal broadcast, so 100 threads may cost
asymmetrically more there per collection. That would be a finding about the
collector rather than the harness, and it would be worth having.
