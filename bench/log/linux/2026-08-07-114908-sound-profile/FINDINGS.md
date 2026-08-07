# Default-path control after the low-water change — and a non-replication

Host: AMD Ryzen 9 9950X (16C/32T), WSL2, Crystal 1.21.0, `--release`, EC1.
Kemal `/json`, `wrk -c100`, 9 rounds × 30 s, interleaved with the order rotated
each round, rates from `CLOCK_MONOTONIC`.

`master` is `f027c06` built from its own `git worktree`. Both builds run at
**default configuration** — no `GCRY_*` set. This re-takes the control from
`2026-08-06-153032-sound-profile/`, which predates today's scan-path changes:
the low-water skip in `scan_pthread_stack` is not gated on `lag == 0`, so it is
live on the default path and the old control no longer describes this code.

## Two runs, and they disagree

| Cut | mean | median | branch faster | SEM | σ | 95% CI |
|-----|-----:|-------:|--------------:|----:|--:|--------|
| `…-113415` (9 rounds) | −2.09% | −3.51% | 3/9 | 0.96% | −2.2 | −3.97 … −0.22% |
| `…-114908` (9 rounds, this) | −0.57% | −0.45% | 4/9 | 1.42% | −0.4 | −3.36 … +2.22% |
| **pooled (18 rounds)** | **−1.33%** | −0.48% | 7/18 | 0.85% | −1.6 | **−3.00 … +0.34%** |

The first cut looked like a real regression — 2.2σ, interval excluding zero —
and was briefly reported as one. It did not replicate. Pooled over 18 rounds the
interval includes zero.

**Conclusion: no measurable default-path regression, bounded at roughly
−3.0% … +0.3%.** That bound, not the point estimate, is the result.

## The suspect was cleared in the same run

This cut carried a third configuration to test the obvious hypothesis — that
the pagemap read added to `scan_pthread_stack` costs something on a path where
the scan is already clamped to live frames and has nothing to skip:

| Comparison | mean | σ | 95% CI |
|------------|-----:|--:|--------|
| branch vs master | −0.57% | −0.4 | −3.36 … +2.22% |
| branch `GCRY_STACK_LOW_WATER=0` vs master | −0.88% | −0.7 | −3.22 … +1.46% |
| **branch vs branch with the skip off** | **+0.32%** | +0.4 | −1.39 … +2.03% |

Turning the skip off does not move the default path. So whatever the first cut
saw, it was not this — and there is nothing here to fix.

## Why both cuts are kept

Either one alone would be misleading. The first says "regression, 2.2σ"; the
second says "nothing". Keeping the pair records the actual epistemic state, and
records that a 9-round paired cut at this spread can produce a 2σ result that
evaporates. This host's throughput channel resolves ~±1.5% at best, after four
separate biases were removed from the harness
(`2026-08-06-140037-sound-profile/FINDINGS.md`); a −1.33% point estimate sits
inside that.

## Limits

- One host, one workload, EC1, one session. 18 rounds is not a lot for an
  effect this size — resolving ±0.5% would need roughly 100.
- Says nothing about EC4 or the fat app on the default path.
- `master` here is `f027c06`, not the merge base of the branch's first commit.
