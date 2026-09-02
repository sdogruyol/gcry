# simdgc Phase 1 baseline — and what this box can actually resolve

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 (Zen 5, 24 threads, 12 GB)
Crystal 1.21.0 / LLVM 20.1.8 · `simdgc` @ 4ad7033 vs `master` @ 287404d
Sessions: `2026-09-02-214628`, `2026-09-02-215525` (simdgc);
`2026-09-02-215055-master-287404d`, `2026-09-02-215950-master-287404d` (master)

## Claim under test

Everything on `simdgc` so far is inert or neutral: SIMD kernels nothing calls,
a verbatim sweep refactor, an 8-byte `ChunkHeader` growth, and the
large-freelist madvise fix. The expectation is **no change**. The point of this
cut was to falsify that, not to confirm it.

## Result: not falsified

| | simdgc | master |
|---|---|---|
| `/json` % of Boehm | 102.0, 96.3 | 94.7, 80.0 |
| `/` % of Boehm | 101.5, 101.8 | 89.7, 86.0 |
| post-GC RSS × Boehm | 0.994, 0.963 | 0.974, 0.987 |
| pause p50 (ms) | 0.718, 0.725 | 0.736, 0.716 |
| gate | PASS, exit 0 | PASS, exit 0 |

RSS and pause are flat and genuinely so — absolute post-GC gcry RSS was
13008/12860 KiB against 12988/13024 KiB, within 1.3%, with the Boehm
denominator moving more than the numerator. The 24→32 byte header growth is
~8 bytes per 128 KiB chunk and is invisible at this resolution, which is the
expected answer and now a measured one.

## The throughput numbers looked like an 18% win. They are an artifact.

Block-ordered, the four runs separate cleanly by arm: simdgc `/` at 101.5/101.8
against master at 89.7/86.0, far outside the 0.02–0.08 noise ratios
`perf_smoke.sh` reports. That is exactly the shape a real win would have, and it
is not one — arm was perfectly confounded with time-block.

Two follow-ups killed it:

- **A null control.** Boehm-vs-Boehm — two binaries containing no gcry at all,
  so the true answer is 1.000 — came out 99.5% and 100.7% under the paired
  protocol, confirming the harness itself is unbiased and the per-trial spread
  is ±10–15%.
- **Paired interleaving.** 8 trials at 10 s with within-pair order alternating:
  `/json` +3.38% for simdgc (t=1.32, 95% CI [−870, +3077] rps, 5/8 wins);
  `/` **−3.60%** (t=−1.04, 95% CI [−6233, +2417] rps, 1/8 wins).

Both batches reverse or erase the block-ordered gap, the two paths disagree in
sign, and every confidence interval spans zero. Verdict: **no difference
outside noise, in either direction.**

## The finding that matters for the rest of the plan

**This box cannot resolve better than about ±10% on Kemal throughput**, and the
within-arm `/json` spread reached 14.7 points on master and 5.7 on simdgc across
plain repeated runs.

The plan's per-phase expectations are +5–10pp for Phase 2+4, +1–3pp for Phase 3,
+3–8pp for Phase 6. **Every one of those is at or below this host's resolution
under the default protocol.** Running `make bench-perf-smoke` twice and comparing
medians would let any of those phases claim a win it did not earn — or hide a
regression of the same size — and the 18% artifact above is what that failure
looks like when it happens.

So the protocol for every later phase is fixed here, not improvised then:

1. **Paired and interleaved**, alternating which arm runs first within each
   pair. Never all of A then all of B.
2. **Report a paired t-statistic and a 95% CI**, not a ratio of medians. A
   difference whose CI spans zero is not a result.
3. **Carry a null control** — same-GC vs same-GC — in any batch whose headline
   is a small effect, **at the same n as the comparison it validates**. If the
   null does not land on 1.00, the batch is unusable.
   *(Amended 2026-09-03 by `../2026-09-03-simdgc-bitmap-ab/`: at n=4 that
   batch's `/json` null read −12.80%, 0/4 wins, p=0.051 — condemning a batch
   that was in fact fine. At n=16 it was clean. A 4-pair null is a coin flip
   that will condemn good batches and bless bad ones.)*
4. **Size the batch to the effect.** The CI half-width above is ~±10% at n=8.
   Resolving 5pp needs roughly n=32 pairs (CI shrinks as 1/√n), which is about
   11 minutes per path at 10 s trials — affordable, and cheaper than a retracted
   claim.

`docs/PERF.md` already records a noise-floor section and the 2026-08-23 ordering
artifact that cost 77.8% vs 87.1% on one host; this is the same lesson arriving
on new hardware, and the reason the ordering discipline is not optional.

## Incidental

`perf_compare.py` printed `FAIL: post-GC RSS 0.99 vs baseline 0.884` on three of
four runs. That is against `bench/baseline/perf_smoke.json`, recorded on
`ubuntu-latest` at commit 7709898, which the script itself disclaims as
cross-runner-class. It is report-only, does not affect exit status, and **both
arms trip it equally** — so it says something about the baseline's portability,
not about this branch.
