# `make poison-freed` on macOS: a paced cycle, not a reclaim defect (2026-10-18)

CI run [39073579395](https://github.com/sdogruyol/gcry/actions/runs/39073579395)
(release-0.37.0 at `5802d7b5`, PR #53), job `test (darwin x86_64, gates)`
117516049279, failed `make poison-freed` in its `--control` arm:

    heap MB per round: 9.4 -> 10.1 -> 16.4 -> 16.4 (1600 kept, 0 poisoned)
    FAIL: the heap grew 7.0 MB over four churn rounds (9.4 -> 10.1 -> 16.4 -> 16.4) — reclaimed blocks are not being handed out again

The job passed on the run's second attempt (job 117525277965), as it had on
39030049833 and 39044768448 (control `9.4 -> 9.6 -> 9.6 -> 9.6`), all three
on trees that carry the 0.37 Darwin changes.

**Verdict: (b), a fragile criterion meeting a 0.37 schedule change.** The
step is chunks that hold survivors, added in the one round where pacing made
a cycle up to three times as long; later rounds reuse them. 0.37.0's 8 MiB
Darwin floor (`75e7628e`) is what lets the control arm pace at all. Nothing
is leaked: after the churn `occ` holds the 1 600 kept strings plus 5 to 20
blocks more than before it. The arm's single test is replaced by two that
read the defect's signatures, each red on a scratch build that restores the
defect, and both green on the macOS gates job and in 400 gate runs there.

## Method

Probe branch `probe/poison-freed-step`, deleted afterwards. Its workflow ran
`probe.sh` / `verify.sh` (here) on `macos-15-intel` and `macos-latest`:

| run | id | probe commit | what |
|---|---|---|---|
| 1 | [39077630525](https://github.com/sdogruyol/gcry/actions/runs/39077630525) | `2af92082` on `6751b917` | step frequency, 0.37 tip against v0.36.0 and schedule arms (`r1-*`) |
| 2 | [39079656093](https://github.com/sdogruyol/gcry/actions/runs/39079656093) | `a47a8b8a` on `a7605193` | the new criteria: gate commands, shipped harness, defect builds (`r2-*`), and ci.yml's `test-macos-gates` job as ci.yml runs it |

`bench/poison_freed.cr --counters` (`6751b917`) prints, per churn round, the
heap after the round's `GC.collect` split into size-class chunks that hold
an occupied block (`holding`), empty ones (`empty`; with `warm`, `grace`,
`dormant` from the last sweep) and `large`; the collections inside the round
with the threshold and pace each left (`cycles=iteration/threshold/pace`,
sampled every 1 024 iterations); chunks mapped and bytes unmapped; and one
line per size class with two or more chunks. `--rounds N` runs N rounds. The
first four rounds of a `--rounds 12` run are the gate's four.

Run 1's arms, interleaved per iteration so runner noise lands on all alike
(100 runs each, 20 for `l037`, 10 for the red arms):

| arm | build | command |
|---|---|---|
| `g037` | 0.37 tip | `bin/poison_freed --control` — the gate command, no counters |
| `c037` | 0.37 tip | `--control --counters` |
| `p037` | 0.37 tip | `GCRY_POISON_FREED=1 … --counters` (the gate's knob-on arm) |
| `t037` | 0.37 tip | `GCRY_THRESHOLD=16777216 … --control` — the old floor, fixed (no adaptation, no pacing) |
| `n037` | 0.37 tip | `GCRY_THRESHOLD_PACE=100 … --control` — the 8 MiB floor, pacing off |
| `l037` | 0.37 tip | `--control --counters --rounds 12` |
| `c036`, `p036` | v0.36.0 + this harness | control, knob on |
| `red`, `redc` | 0.37 tip + `defect.patch` | knob on, control |

`defect.patch` restores the 2026-09-04 defect exactly: `GCRY_POISON_FREED=1`
stands the bitmap sweep arm down and lets the header walk run, which
reclaims without clearing `occ`. `leak.patch` leaves a compile-time mask of
every reclaim's dead blocks occupied (`SCRATCH_LEAK_MASK`), a weaker defect
of the same mechanism. Neither is committed outside this directory.

Local: Linux x86_64 (the shared box), the same loops (`linux-local/`,
`linux-local-verify/`).

## What the step is made of

The arm allocates 200 000 strings a round and keeps 1 in 500. The kept
strings are size class 4, 80 B, atomic (`4a`), interleaved with the garbage
of the same class, so each chunk a cycle fills (3 276 blocks of 80 B in a
256 KiB Darwin chunk) keeps about six survivors and is never empty again.
The heap after a round is therefore the largest number of `4a` chunks any
one cycle has needed, plus about one chunk per other class, plus the
dormant budget; a cycle needs as many as it allocates before the next
collection.

- **Empty chunks are not it.** `GC.collect` is a releasing collection
  (`release_warm: true`): `warm` and `grace` read 0 after every round of
  every run; `empty` is 0.5–1.0 MB, all `dormant`, in every arm, step or not.
- **The step is `4a` chunks.** At 0.37 the control arm sits at 13 `4a`
  chunks (98 of 100 runs on macos-15-intel); every stepped round raised
  `holding` and the `4a` count (13 → 20, 21, 22 and 38 in the control runs
  that stepped) and nothing else by more than a chunk.
- **The round that steps has a long cycle after a paced collection.** A
  control cycle is 40 960 iterations (the 8 MiB threshold). In every stepped
  round of every control run that printed counters, one cycle ran
  61 440–120 832 iterations, after a collection that left the pace at
  153–300%:

      c037 intel  9.6 → 11.6 → 11.6 → 11.6   round 2: cycles [40960, 39936, 40960, 64512], pace [100, 100, 161, 100]; 4a 13→20
      c037 m1     9.6 → 12.4 → 12.1 → 12.1   round 2: cycles [40960, 39936, 69632, 39936], pace [100, 171, 100, 100]; 4a 13→22
      l037 intel  9.6 → 9.8 → 9.8 → 16.1 → 16.1 → … → 16.2 (12 rounds)
                                             round 4: cycles [40960, 120832], pace [300, 100]; 4a 13→38
      l037 m1     … 9.9 → 11.9 …             round 6: cycles [40960, 39936, 39936, 65536], pace [100, 100, 161, 100]; 4a 13→21

  The `l037` intel run is the CI failure's shape (9.4 → 10.1 → 16.4): one
  collection costing more than a tenth of the mutator time before it set the
  pace to 300%, the next cycle was 2.95× as long and filled 38 `4a` chunks.
- **They are reused.** That run's `4a` count per round reads `13, 13, 13,
  38, 38, 38, 38, 38, 38, 38, 38, 38` and its heap 16.1–16.4 MB for the
  eight rounds after the step: every later round's 200 000 strings went into
  the chunks the long cycle mapped. The `4a` blocks occupied after round 4
  are 1 610 to 1 620 in every run on macOS (1 604 on Linux), for 1 600 kept.

So the heap is a running maximum of cycle length. It rises only in a round
whose longest cycle beats every earlier one, and never past what the paced
threshold (3 × 8 MiB) allocates.

## Why 0.37, and how often

`r1-*/summary.txt` and `python3 analyze.py` (first four rounds; "shipped" is
the old test, last minus first > 4.0 MB; "proposed" is growth > 4 MB in
every round; "rc≠0" is the harness's own exit, the shipped test on
unrounded MB):

macos-15-intel:

| arm | runs | rc≠0 | shipped fails | proposed fails | stepped >1 MB | rounds paced | round-1 median MB | max MB | max growth | max round step |
|---|---|---|---|---|---|---|---|---|---|---|
| g037 | 100 | 0 | 0 | 0 | 2 | — | 9.40 | 11.90 | +2.20 | +2.00 |
| c037 | 100 | 0 | 0 | 0 | 1 | 2/400 | 9.60 | 12.60 | +2.00 | +2.00 |
| l037 | 20 | 1 | 1 | 0 | 1 | 1/240 | 9.60 | 16.35 | +6.59 | +6.25 |
| p037 | 100 | 1 | 1 | 0 | 14 | 400/400 | 14.10 | 16.85 | +4.25 | +2.00 |
| t037 | 100 | 0 | 0 | 0 | 0 | 0/400 | 12.85 | 14.35 | +1.50 | +0.75 |
| n037 | 100 | 0 | 0 | 0 | 0 | 0/400 | 9.60 | 10.35 | +0.75 | +0.75 |
| c036 | 100 | 0 | 0 | 0 | 0 | 0/400 | 12.35 | 13.10 | +0.50 | +0.50 |
| p036 | 100 | 0 | 0 | 0 | 100 | 400/400 | 12.35 | 16.10 | +3.75 | +3.75 |
| red | 10 | 10 | 10 | 10 | 10 | 40/40 | 45.85 | 164.60 | +118.75 | +40.75 |
| redc | 10 | 0 | 0 | 0 | 0 | 0/40 | 9.60 | 9.85 | +0.25 | +0.25 |

macos-latest:

| arm | runs | rc≠0 | shipped fails | proposed fails | stepped >1 MB | rounds paced | round-1 median MB | max MB | max growth | max round step |
|---|---|---|---|---|---|---|---|---|---|---|
| g037 | 100 | 1 | 1 | 0 | 1 | — | 9.40 | 15.40 | +6.00 | +5.50 |
| c037 | 100 | 0 | 0 | 0 | 1 | 2/400 | 9.62 | 12.38 | +2.50 | +2.76 |
| l037 | 20 | 0 | 0 | 0 | 0 | 6/240 | 9.62 | 12.12 | +2.30 | +0.26 |
| p037 | 100 | 1 | 2 | 0 | 27 | 400/400 | 12.38 | 16.12 | +4.24 | +4.00 |
| t037 | 100 | 0 | 0 | 0 | 0 | 0/400 | 12.88 | 13.88 | +1.00 | +0.76 |
| n037 | 100 | 0 | 0 | 0 | 0 | 0/400 | 9.62 | 10.12 | +0.50 | +0.26 |
| c036 | 100 | 0 | 0 | 0 | 0 | 0/400 | 12.38 | 12.88 | +0.50 | +0.50 |
| p036 | 100 | 0 | 0 | 0 | 100 | 400/400 | 12.38 | 15.62 | +3.24 | +3.00 |
| red | 10 | 10 | 10 | 10 | 10 | 40/40 | 45.88 | 164.62 | +118.74 | +40.74 |
| redc | 10 | 0 | 0 | 0 | 0 | 0/40 | 9.62 | 9.88 | +0.26 | +0.26 |

("max growth" is last minus first over all of a run's rounds, twelve for
`l037`; `l037` m1's steps were in rounds 6 and 12, past the gate's four.)

Linux x86_64, local: no control arm ever paced (0 of 1 440 rounds over
`c037`, `l037`, `n037`, `c036`), no control run stepped, and the knob-on arms
paced in all 800 rounds with one step of +1.5 MB (`linux-local/`).

- **Pacing is the mechanism.** With pacing off (`n037`) or the threshold
  fixed at 16 MiB (`t037`) no run stepped on either runner (0 of 400); every
  control step that printed counters followed a paced collection.
- **The 8 MiB floor is what makes the control arm pace.** At v0.36.0 the
  Darwin floor was 16 MiB: a cycle every 80 896 iterations, 26 `4a` chunks,
  and the control arm paced in 0 of 800 rounds. At 8 MiB a cycle is 40 960
  iterations — half the mutator time between collections — and the control
  arm paced in 11 of 1 280 rounds (`c037` 2 + 2 of 800, `l037` 1 + 6 of
  480; paces 101–300%). The collection did not halve with it, or the pace's
  ratio of collection to mutator time would not have moved.
- **The knob-on arm paced at 0.36.0 too**, in every round (a poisoning sweep
  writes every reclaimed payload): there it stepped in all 200 runs, by
  +3.0 MB in round 2, 1 MB under the old bar. At 0.37 it starts higher and
  wider (round 1 10.9–15.6 MB) and steps less often, but by up to +4.25.
- **How often the shipped test failed**, runs 1 and 2 together (run 2's
  `oldc` / `oldh` are the shipped harness interleaved with the new one):
  control 1 of 320 on each runner (`l037` intel, `g037` m1), knob-on 1 of
  200 on macos-15-intel and 6 of 200 on macos-latest (5 of them in run 2).
  That is about one `make poison-freed` in 120 on macos-15-intel and one in
  30 on macos-latest, against 0 of 400 runs at v0.36.0. The counts are small
  and run 2's macos-latest knob-on arm failed five times as often as run
  1's, so take the rates as an order of magnitude.
- Not the atomic quarter (`fa51f65f`): the live set is 0.12–0.22 MB, so the
  threshold sits on the floor with or without it (`thr=8.0` after every
  round). The Darwin hit path (`ec551749`) was not isolated; a faster
  mutator shortens the time a collection is weighed against, so it can only
  push the same way [INFERENCE].

## The new tests

The defect grows the heap in every round by what the round allocated: no
reclaimed block is handed out again, so each round's strings need fresh
chunks — +15.5 MB a round in 2026-09, +38 to +41 MB a round with
`defect.patch` on this tree, where classes 2a and 4 (non-atomic) grow
alongside `4a`. A paced step is a running maximum. So the arm now fails
(`a7605193`):

1. **when every round after the first grew by more than 4 MB.** Three such
   rounds are more than 12 MB; the most any healthy run grew over its four
   rounds is +7.0 MB (the CI failure; +6.8 in run 2's gate loop, +6.5 in
   run 1), and the highest any round read is 16.9 MB, in 2 320 runs on the
   macOS runners.
2. **when `occ` gained more than twice the kept strings' worth of set bits
   over the churn** (baseline after a `GC.collect` added before round 1,
   read after the last round's `GC.collect`). The heap test alone misses a
   leak that levels off, and the old test caught some of those: with an
   eighth of every reclaim left occupied (`leak.patch`, mask `0x0101…`) the
   chunks fill with lost blocks until the other seven eighths suffice, and
   the heap goes 22.5 → 28.0 → 30.9 → 31.2 MB on Linux, 25.4 → 33.1 → 34.4 →
   34.9 on macos-15-intel. `occ` is what the allocator reads to call a block
   taken, and it does not depend on the schedule: over 600 healthy runs the
   churn gained the 1 600 kept strings plus 5 to 20 blocks, against 49 000
   to 52 000 more for that leak, 4 300 to 5 900 more for a sixty-fourth (a
   heap of +1.7 MB on Linux, which the old test passed) and 2.3 to 2.4
   million more for the defect. The header allocator has no `occ` and reads
   0, which passes.

The tables below are `verify.py` on run 2's logs; "occupancy excess" is
blocks gained over the churn minus the 1 600 kept (−1 600 is a header build
reading 0), and `oldc` / `oldh` print none.

Local Linux, the same loop (`linux-local-verify/`):

| arm | runs | rc≠0 | FAIL lines | round-1 MB median | max MB | max last−first | max round step | occupancy excess min/median/max |
|---|---|---|---|---|---|---|---|---|
| ctl | 100 | 0 | — | 5.7 | 6.1 | +0.3 | +0.3 | 5/5/7 |
| hold | 100 | 0 | — | 9.5 | 11.7 | +2.2 | +2.2 | 5/5/7 |
| hdrc | 20 | 0 | — | 31.2 | 31.5 | +0.3 | +0.2 | -1600/-1600/-1600 |
| hdrh | 20 | 0 | — | 31.2 | 31.6 | +0.3 | +0.2 | -1600/-1600/-1600 |
| oldc | 100 | 0 | — | 5.7 | 6.0 | +0.3 | +0.2 | — |
| oldh | 100 | 0 | — | 9.0 | 10.7 | +1.3 | +1.3 | — |
| red | 10 | 10 | growth 10, occupied 10 | 43.1 | 163.2 | +120.1 | +40.3 | 2398417/2398417/2398417 |
| leak8 | 10 | 10 | occupied 10 | 22.5 | 31.2 | +9.7 | +7.7 | 52193/52225/52229 |
| leak64 | 10 | 10 | occupied 10 | 21.2 | 24.5 | +1.7 | +1.4 | 4307/4402/5035 |

## Verification on the macOS runners (run 2)

ci.yml's `test-macos-gates` job — its matrix, timeout and `make` lines as
ci.yml has them — run on probe commit `a47a8b8a` (= the branch's `a7605193`
plus `probe/` and the probe workflow): **both green**, `test (darwin x86_64,
gates)` job 117533830686 (17 min) and `test (darwin arm64, gates)` job
117533830670 (8 min), every gate in the job. Their
`make poison-freed` lines are in `r2-gates-jobs.txt`; x86_64's control arm
read 9.6 → 10.1 → 10.1 → 10.1 MB and gained 1 600 + 7 blocks.

The loop, interleaved per iteration (`r2-*/`):

macos-15-intel:

| arm | runs | rc≠0 | FAIL lines | round-1 MB median | max MB | max last−first | max round step | occupancy excess min/median/max |
|---|---|---|---|---|---|---|---|---|
| ctl | 100 | 0 | — | 9.6 | 16.4 | +6.8 | +6.3 | 6/7/20 |
| hold | 100 | 0 | — | 13.6 | 15.6 | +2.0 | +1.7 | 6/7/20 |
| hdrc | 20 | 0 | — | 19.1 | 19.9 | +0.5 | +0.3 | -1600/-1600/-1600 |
| hdrh | 20 | 0 | — | 19.1 | 19.9 | +0.8 | +0.5 | -1600/-1600/-1600 |
| oldc | 100 | 0 | — | 9.4 | 10.1 | +0.7 | +0.5 | — |
| oldh | 100 | 0 | — | 14.6 | 16.1 | +1.7 | +1.5 | — |
| red | 10 | 10 | growth 10, occupied 10 | 46.4 | 162.1 | +115.7 | +38.7 | 2315769/2317935/2320101 |
| leak8 | 10 | 10 | occupied 10 | 25.6 | 34.9 | +9.7 | +8.2 | 50692/51175/51200 |
| leak64 | 10 | 10 | occupied 10 | 25.4 | 31.9 | +8.5 | +7.7 | 5630/5776/5858 |

macos-latest:

| arm | runs | rc≠0 | FAIL lines | round-1 MB median | max MB | max last−first | max round step | occupancy excess min/median/max |
|---|---|---|---|---|---|---|---|---|
| ctl | 100 | 0 | — | 9.6 | 12.1 | +2.5 | +2.5 | 7/8/16 |
| hold | 100 | 0 | — | 13.1 | 16.4 | +5.2 | +4.3 | 7/8/13 |
| hdrc | 20 | 0 | — | 19.1 | 19.9 | +0.8 | +0.3 | -1600/-1600/-1600 |
| hdrh | 20 | 0 | — | 19.1 | 19.6 | +0.5 | +0.3 | -1600/-1600/-1600 |
| oldc | 100 | 0 | — | 9.4 | 12.6 | +3.2 | +3.2 | — |
| oldh | 100 | 5 | shipped 5 | 12.9 | 16.1 | +5.2 | +5.0 | — |
| red | 10 | 10 | growth 10, occupied 10 | 46.4 | 162.1 | +115.7 | +38.7 | 2315769/2317935/2320101 |
| leak8 | 10 | 10 | occupied 10 | 27.4 | 34.9 | +15.5 | +13.5 | 49203/50663/51204 |
| leak64 | 10 | 10 | occupied 10 | 24.9 | 31.9 | +9.0 | +6.2 | 4619/5775/5791 |

- The new gate: 0 of 400 runs failed. One macos-15-intel control run had
  the CI failure's shape, 9.6 → 10.1 → 10.1 → 16.4 MB, and passed both
  tests (occupancy excess 7).
- The shipped harness in the same loop: 5 of 100 knob-on runs failed on
  macos-latest (e.g. 10.9 → 13.4 → 13.9 → 15.4), 0 control.
- Every defect build failed, 60 of 60: the restored stand-down on both
  tests, both leak masks on the occupancy test.

The branch's final `bench/poison_freed.cr` differs from `a7605193` in
comments only (the numbers above).

Local, on the branch: `crystal tool format --check src spec process_spec
bench samples` clean; `make lint` 228 inspected, 0 failures; `make
poison-freed` passes all four arms; `crystal spec` 303 examples, 0
failures; `crystal spec -Dgcry_block_headers` 325, 0; `crystal spec
-Dgc_none process_spec` 207, 0; `crystal spec -Dgc_none -Dgcry_block_headers
process_spec` 208, 0.

## What this does not cover

- The heap test alone is now blind to a leak below 4 MB a round. The
  occupancy test covers any leak through `occ`; a defect that clears `occ`
  but never offers the freed blocks to the allocator (its capacity index or
  cursor search) shows only as heap growth, and would have to grow it by
  4 MB in every round to fail here.
- The occupancy test is vacuous on the header allocator (`poison_freed_hdr`,
  `GCRY_BITMAP_ALLOC=0`), which has no `occ` and never had the defect.
- The `GC.collect` added before round 1 resets the pace and collects arms
  1-3's garbage; round 1 starts from a collected heap where it used to
  start from theirs. Run 2's numbers are with it.

## Files

- `analyze.py` — run 1's tables (`python3 analyze.py`, or `analyze.py DIR`).
- `probe.sh`, `probe.py` — run 1's loop and summary; `verify.sh`,
  `verify.py` — run 2's (`python3 verify.py r2-macos-latest`).
- `defect.patch`, `leak.patch` — the scratch builds.
- `r1-macos-15-intel/`, `r1-macos-latest/`, `linux-local/` — run 1's logs,
  one per arm, gzipped, and the probe's own summary.
- `r2-macos-15-intel/`, `r2-macos-latest/`, `linux-local-verify/` — run 2's;
  `r2-gates-jobs.txt` — the gates jobs' `make poison-freed` output.
