# The residual spread: what it is not, and what the instrument can actually resolve

**Host: i3-12100F (4c/8t, one 12 MiB L3 shared by all 8 CPUs), WSL2.**

Two runs, `bench/root_phase_ab.sh`, 12 reps × 30 s each:

- this dir — **null control**: the same build against itself (`a` vs `b`,
  identical binary, identical env).
- `../2026-08-07-052428-root-phase/` — **ASLR on vs off**
  (`BENCH_NO_ASLR=1` → `setarch -R`).

Every A/B in this project bottoms out at 1.2–3% scatter between reps. This is
the first attempt to say what that scatter *is* rather than route around it.

## 1. The instrument's own noise floor, measured

Identical build vs itself, paired across 12 reps:

| phase | paired Δ | t | 95% CI | rep sd | r(a,b) |
|---|---:|---:|---|---:|---:|
| roots | +0.21% | +0.21 | −1.98 … +2.40 | 1.99% | −0.18 |
| static | +0.32% | +1.26 | −0.24 … +0.89 | 0.67% | +0.18 |
| stacks | +0.89% | +1.71 | −0.26 … +2.04 | 1.37% | +0.32 |
| mark | +0.92% | +0.61 | −2.41 … +4.26 | 2.08% | −0.53 |
| pause | +0.72% | +0.65 | −1.73 … +3.17 | 1.95% | −0.42 |
| **post-GC RSS** | **−0.07%** | **−0.16** | **−0.99 … +0.86** | **0.75%** | −0.09 |

The Δ column is correctly ~0 everywhere — the harness is unbiased. The CI column
is the useful output: **±2–3pp on phase timings, ±1pp on RSS, at 12 reps.**
Anything smaller than that is not resolvable by this instrument, at this rep
count, on this host.

Applied to the claims taken this week:

- Default-path control, `+1.11%` on `roots+static+stacks+mark`, CI −0.63…+2.85
  (`../2026-08-07-041413-root-phase/`) — **entirely inside the null band.** It
  did not measure a null effect; it measured nothing. The branch could have
  carried a ~1% regression and this run would not have seen it.
- `scrub_fibers` root work, **−9.1%** — far outside the floor. Real.
- Default-path **post-GC RSS +1.63%**, CI +0.58…+2.68 — outside a null band that
  is demonstrably centred on zero with comparable SEM (0.46 vs 0.42). **Survives
  the control.** RSS is the tightest metric this harness has, not the loosest.

## 2. The spread is per-process, not environmental

`r(a,b)` is the within-rep correlation between two *identical* configurations.
A shared per-rep environmental factor — thermal state, background load, a busy
minute — would push it high. It is ~0 or negative in every phase (−0.53 … +0.32,
n=12; |r| would need ≈0.58 to reach p<0.05).

So each server process is an independent draw. Combined with the earlier
observation that per-rep medians show no trend and no lag-1 autocorrelation
(`../2026-08-07-041413-root-phase/`), this eliminates everything that varies
*over the run* and points at something fixed per process launch.

## 3. Four hypotheses eliminated

| Hypothesis | Verdict |
|---|---|
| The load generator / wrk | **No** — the spread is in the collector's own `monotonic_ns` phase medians, with no wrk in the loop |
| The clock (WSL2 `CLOCK_REALTIME` stepping) | **No** — same reason; phases are timed with `monotonic_ns` |
| Thermal drift / slow environmental change | **No** — no trend (−0.05 µs/rep), no lag-1 autocorrelation, r(a,b)≈0 |
| CCD / L3 placement (the standing hypothesis) | **No, at least here** — this host has one L3 instance shared by all 8 CPUs; there is no boundary to migrate across, and the spread is present anyway |
| Address-space randomisation | **No** — see below |

## 4. ASLR is not it either

12 reps with the server under `setarch -R`, against 12 with randomisation on:

| metric | sd (ASLR on) | sd (ASLR off) | ratio | F(11,11) |
|---|---:|---:|---:|---:|
| roots | 3.01% | 2.36% | 0.78 | 0.62 |
| mark | 2.55% | 2.45% | 0.96 | 0.94 |
| pause | 1.91% | 2.01% | 1.05 | 1.12 |
| RSS | 1.70% | 2.25% | 1.32 | 1.69 |

Nothing significant (ns band at .05 is F ≈ 0.35–2.82). Turning layout
randomisation off does not quiet the collector.

**And there is a reason to have expected that.** ASLR randomises *virtual*
addresses. L3 indexing on this part is physical. Disabling ASLR does not make
the kernel hand back the same physical pages, so it cannot fix physical page
placement — which leaves that hypothesis untouched rather than tested.

One side observation supports the placement family: with ASLR off, post-GC RSS
takes only **8 distinct values across 12 reps** (12/12 with ASLR on), clustering
in near-duplicate pairs — 12000/12004, 12128/12136, 12660/12664. With layout
fixed the process lands in a small set of discrete states. That is the signature
of a quantised quantity, and corroborates reading the +1.63% RSS delta as a
count of 128 KiB size-class chunks rather than a retention change.

## What is left

Per-process, fixed at launch, not virtual layout. The leading remaining
candidate is **physical page placement** — which pages the kernel happens to
hand this process, and therefore how the heap distributes across L3 sets. Next
test would need control over that: THP on/off, or hugepage-backed heap chunks,
neither of which is a per-process switch the harness can set today.

Until then the operative number is section 1: **±2–3pp on phase timings, ±1pp on
RSS.** Publish nothing smaller from this host without more reps than 12.
