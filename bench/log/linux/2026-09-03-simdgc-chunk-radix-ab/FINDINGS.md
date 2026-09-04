# Phase 2 cut: GCRY_CHUNK_RADIX=1 — the mark got faster, and the plan's
# throughput target turns out to be unreachable on this workload

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 · `simdgc` @ e67d3fa
256 trials, `wrk -c50 -d10`, server restarted per trial, zero failures.
n=32 pairs per path; treatment and null interleaved in the same rounds.
Data and scripts alongside: `trials.jsonl`, `analysis.txt`, `did.txt`,
`robust.txt`, `ancova.txt`.

## Result 1 — the radix works: phase_mark −10 to −18%

| path | radix − default | t | p | 95% CI | wins |
|---|---|---|---|---|---|
| `/json` | **−6.63%** | −2.55 | 0.016 | [−11.94%, −1.33%] | 25/32 |
| `/` | **−17.72%** | −4.37 | 0.0001 | [−25.98%, −9.46%] | 29/32 |

Survives everything thrown at it:

- **Non-parametric** — sign test p=0.0021 / 2.6e−6, Wilcoxon p=0.0022 / 1.3e−6.
- **Live-set confound** — the radix arm happened to snapshot a 21% smaller heap
  on `/json`, which would shorten a mark on its own. ANCOVA on Δlive_objects
  makes the effect *larger* (−9.34%, −18.46%): the confound ran against the
  result.
- **Position artifact removed** — DiD gives −10.10% and −18.19%.
- Null on the same metric is flat (+3.58%, +0.50%), and `phase_sweep` /
  `phase_stacks` do not move on either path, which is what should happen.

Pause follows at −3–4% on both paths by both measures, the size a 10–18% cut to
29% of the pause predicts. Fast-hit rate 99.7% explains the mechanism.

## Result 2 — the +5–10pp throughput hypothesis is refuted, not merely unproven

Throughput is unmeasurable (`/json` +2.69%, CI [−2.65%, +8.02%]; `/` −1.37%,
CI [−5.77%, +3.03%]; signs disagree, wins are coin flips). But the batch's own
instrumentation makes the stronger statement:

| | `/json` | `/` |
|---|---|---|
| collections in a 10 s load | 67.2 | 25.5 |
| total STW pause | 52.9 ms | 21.9 ms |
| **GC duty cycle** | **0.529%** | **0.219%** |
| `phase_mark` share of pause | 29.0% | 28.6% |
| ceiling if *all* GC pause vanished | +0.53% | +0.22% |
| ceiling if *all* mark time vanished | **+0.15%** | **+0.06%** |
| what the measured mark win is worth | **+0.010%** | **+0.011%** |

Every lookup the radix accelerates is inside STW, so the pause is the entire
addressable budget. **An infinitely fast mark buys 0.15pp on `/json`.** The plan
asked 5–10pp from a component worth 0.15pp; that is unreachable at any sample
size, on any hardware, with any implementation.

This retires the throughput expectations for the mark-side phases as written.
See "What this means for the plan" below.

## Result 3 — unhypothesised: +16–21% RSS, and it was transparent huge pages

| path | default | radix | diff | 95% CI | wins |
|---|---|---|---|---|---|
| `/json` VmRSS | 13,477 KiB | 16,359 KiB | **+21.38%** | [+17.72%, +25.05%] | 31/32 |
| `/` VmRSS | 13,197 KiB | 15,361 KiB | **+16.39%** | [+12.51%, +20.27%] | 31/32 |

The null resolves RSS to ±0.8% and reads flat, so this is not the harness.
smaps named it outright:

```
7fd07f993000-7fd080193000  Size: 8192 kB  Rss: 2048 kB  AnonHugePages: 2048 kB
```

`chunk_radix.cr` claimed "~8 bytes per page of live heap, 0.2% of the heap". The
arithmetic was right; the assumption was not. With THP in `always` a single
touched entry faults a **2 MiB** huge page, so resident cost stops tracking the
live heap and becomes ~2 MiB per 4 GiB region holding any chunk — **160× the
estimate** on a 13 MB heap. Bounded (five loads plateaued at 2172 KiB) but a
fixed per-process tax, which is the wrong shape for a collector judged on
RSS × Boehm.

**Fixed**: the tables are now `MADV_NOHUGEPAGE`d, the same policy and the same
reasoning as `map_chunk`. Measured directly, 20k live strings:

| | VmRSS | AnonHugePages | fast hits |
|---|---|---|---|
| radix off | 6084 kB | 0 | 0 |
| radix on, fixed | 6184 kB (**+1.6%**) | 0 | 60,245 |
| radix on, `GCRY_RADIX_THP=1` | 8184 kB (**+34.5%**) | 2048 | 60,245 |

The whole tax is huge-page rounding, and the table is byte-for-byte as effective
without it. `GCRY_RADIX_THP=1` is kept because the huge page also gives the
table one TLB entry, and whether that paid for part of the mark win is an open
A/B — that knob's only reason to exist.

## A flaw in the schedule, caught by the same-n null

77 of 256 trials logged `wrk` socket timeouts, determined **entirely by absolute
position within the round**, not by arm: positions 3, 6, 8 afflicted in both
parities, the other five never. The schedule alternated within-pair order — as
the protocol requires — but left absolute position confounded, so on `/` the
radix always drew an afflicted slot and default never did.

It was recoverable only because the null inherited the identical confound,
making it removable by difference-in-differences. **A 4-pair null could not have
estimated an artifact worth ±1–3.6%** — the second time the same-n null rule has
paid for itself.

It also dissolves the throughput sign disagreement: `/json` put the radix in a
clean slot (+2.69%), `/` in an afflicted one (−1.37%). *The two paths never
disagreed about the radix; they disagreed about position.*

**Protocol correction:** alternating within-pair order is not sufficient. Balance
each arm across absolute position in the round, or rotate arms through all
positions. Interleaving fixed which arm ran *first*; it did not fix which arm
ran *third*.

## Power

MDE at 80%, from the batch's own paired SDs: throughput 7.6% / 6.2%,
`phase_mark` 7.5% / 11.7%, pause p50 1.3% / 5.8%, RSS 5.2% / 5.5%. n=32 gave a
throughput CI half-width of ±4.4–5.3% against the ±5% the 1/√n rule predicted,
so the sizing model holds.

Multiplicity: ~24 tests per family. Two marginal hits (`phase_clear` `/json`
p=0.048 on a 0.2 µs quantity; `idle_sweep` `/json` p=0.045) read as multiplicity
— the null's own `idle_sweep` on `/` gave −12.67% at p=0.054 from a comparison
whose true answer is zero. Only `phase_mark` (both paths, same sign) and RSS
survive.

## What this means for the plan

The mark-side phases are being measured against the wrong axis. Kemal spends
**0.2–0.5% of wall time stopped for GC**, so the plan's per-phase throughput
expectations — +5–10pp for Phase 2+4, +3–8pp for Phase 6 — cannot be delivered
by anything that makes marking faster, however much faster it gets.

Three honest options, to be chosen before the next cut rather than after it:

1. **Restate the phase gates on the axis the work actually moves**: `phase_mark`,
   `phase_sweep`, pause p50/p99. Those resolve at n=32 and the radix already
   cleared them decisively.
2. **Find a workload with a real GC duty cycle** — the acikturkiye fat app, or
   `bench/churn.cr`-shaped allocation storms — and make *that* the throughput
   gate. Kemal `/json` stays the regression guard it is good at.
3. **Accept that the throughput target belongs to the allocator**, not the
   collector: Phase 3 and 6 touch every allocation, which is where the mutator's
   time actually goes on this workload.

Phase 2's own verdict: **the mechanism is proven, the default stays off.** The
RSS regression is fixed but unmeasured post-fix at Kemal scale, and the
throughput case cannot be made from this workload at all.
