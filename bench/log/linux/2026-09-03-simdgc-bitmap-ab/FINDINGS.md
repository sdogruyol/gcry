# Phase 1 cut: GCRY_BITMAP=1 vs the header mark generation

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 · `simdgc` @ 31faa65
132 trials, `wrk -c50 -d10`, server restarted per trial, zero failures.
Raw data: `trials.jsonl`, `null-extension.jsonl`; scripts alongside.

## Setup validity

**One binary served both arms** (`sha256 316fdccf…`, `-Dgc_none --release`).
`GCRY_BITMAP` is a runtime knob, so there is no rebuild between arms and the
only difference is one environment variable — confirmed by a probe showing the
variable flips `Heap#bitmap_marks?` false→true, and unset or `=0` leaves it
false.

## Throughput: unmeasurable

Paired, n=16, alternating which arm ran first within each pair.

| path | bitmap − default | t | p | 95% CI | wins |
|---|---|---|---|---|---|
| `/json` | +1,068 rps (+2.58%) | +1.21 | 0.244 | [−1.95%, +7.12%] | 11/16 |
| `/` | −242 rps (−0.41%) | −0.20 | 0.847 | [−4.88%, +4.05%] | 9/16 |

Both CIs span zero and the two paths disagree in sign. **The point estimates
are not results.**

## RSS and pause: flat, and this time positively so

| path | default | bitmap | diff | 95% CI |
|---|---|---|---|---|
| `/json` post-GC VmRSS | 13,109 KiB | 13,090 KiB | −0.14% | [−1.22%, +0.94%] |
| `/` post-GC VmRSS | 12,744 KiB | 12,813 KiB | +0.54% | [−0.47%, +1.55%] |
| `/json` pause p50 | 0.775 ms | 0.778 ms | +0.38% | spans zero |
| `/` pause p50 | 0.841 ms | 0.848 ms | +0.88% | spans zero |

RSS resolves to ±1.5% and pause to a few percent, so unlike throughput these
**exclude** a meaningful regression rather than merely failing to find one. The
per-chunk bitmap costs no measurable RSS — expected, since the bits ride inside
the chunk instead of a side mmap, but now measured rather than argued.

## The ordering artifact is real, and alternation caught it

On `/` there is a **+3.37% second-position effect**, and the naive block-ordered
estimate **flips sign with schedule**: +1,700 rps when default ran first,
−2,184 rps when bitmap ran first. Alternation cancels it to −0.41%.

Block-ordering `/` would have manufactured a ~3% win or a ~3% loss depending
only on which arm happened to be scheduled first. Same mechanism as the +18%
artifact in `2026-09-03-simdgc-phase-1-baseline`; this is the second time it has
appeared on this host, and the first time the protocol caught it prospectively.

## Correction to the protocol: size the null control like the treatment

The baseline FINDINGS prescribed "a same-GC null control in any batch whose
headline is a small effect" without specifying its size. At the n=4 the batch
first used, the `/json` null came out **−12.80%, 0/4 wins, t=−3.15, p=0.051** —
which by the stated rule condemns a batch that is in fact fine. Extended to
n=16 the null is clean (0.961 on `/json`, 1.011 on `/`, both CIs spanning zero).

So the rule needs a size: **the null control gets the same n as the comparison
it validates.** A 4-pair null is a coin flip that will condemn good batches and
bless bad ones.

The extended null also carries the batch's most useful number. Its own envelope
on `/json` is **±7%**, and its point estimate strays **3.9%** from a known-true
1.000. An identical-binary comparison on this box produces deviations *larger*
than the +2.58% this batch attributes to the bitmap. That is the clearest
available statement of what "flat" is worth here.

## Power

- **Detectable at 80%:** ≥6.4% (`/json`), ≥6.3% (`/`).
- **Not detectable:** anything in the **±2–6%** band. A true 3% win or loss
  would produce a dataset indistinguishable from this one.
- Resolving 2% needs ~160 pairs per path, ~1.5 h per path at 10 s trials.
- Per-arm `% of Boehm` (`/json` 103.9% vs 106.5%; `/` 95.8% vs 95.4%) is the
  **weakest** figure here: Boehm was n=2 and its two `/` runs differ by 11%
  (58,058 vs 64,432). Do not quote those percentages as precise.

## What this does and does not license

Phase 1's expectation was flat, and flat is what the measurement supports. But
the bitmap arm does strictly **more** work than the default: readers take the
union (bitmap OR header generation), allocate-black still writes the header, and
the sweep still walks every header. So "flat" here means that added cost sits
below the noise floor — it is a licence to continue, not evidence of a win, and
it says nothing about Phase 3's payoff, which only arrives when the sweep stops
reading headers and the union retires.
