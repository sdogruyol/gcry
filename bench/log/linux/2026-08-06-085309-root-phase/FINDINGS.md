# EC4: the sound profile is a 19× pause regression, and it is one knob

Host: AMD Ryzen 9 9950X (16C/32T), WSL2, Crystal 1.21.0, branch
`feat/sound-defaults`. Workload: Kemal `/json`, `wrk -c100`, **EC parallelism
4** (`-Dpreview_mt -Dexecution_context`, `EC_PARALLELISM=4`). Instrument:
`bench/root_phase_ab.sh`, 8 configs × 3 reps × 20 s, first 5 collections of
each rep dropped. 7883 collections analysed. The knob split in
`2026-08-06-090503-root-phase/` is part of this result and is reported below.

The EC1 companion cut is `2026-08-06-081512-root-phase/`. Read it first: it
establishes the method and why the throughput channel is unusable on this host.

## Measurement basis

`work` = `roots_ns + scrub_ns + stacks_ns`, and `pause` is reported alongside
it. Neither alone is honest:

- `roots_ns` is `monotonic_ns - t0 - scrub_ns`, so it **excludes** scrub — and
  turning scrub off is one of the knobs.
- `stacks_ns` is a **separate additive phase, not a sub-timing of roots**. This
  is not a technicality: `GCRY_STW_PTHREAD_LAG=0` leaves `roots_ns` flat and
  moves `stacks_ns` 15×, which a roots-only or roots+scrub basis reports as
  ~free (+2.8%) when the pause actually rises 64%.

## Result

| Config | roots µs | stacks µs | pause µs | Δwork | Δpause | label |
|--------|---------:|----------:|---------:|------:|-------:|-------|
| tuned | 6374.1 | 303.5 | **7206.7** | — | — | tuned |
| `GCRY_SOUND=1` | 136315.7 | 4608.1 | **141721.6** | +2001.9% | **+1866.5%** | sound |
| `GCRY_STW_STACK_LAG=0 GCRY_STW_PTHREAD_LAG=0` | 136219.2 | 4687.5 | **141704.8** | +2003.0% | **+1866.3%** | tuned |
| `GCRY_DISABLE_BLACKLIST=1` | 6470.7 | 305.2 | 7314.3 | +1.5% | +1.5% | tuned |
| `GCRY_UNALIGNED_CANDIDATES=1` | 6433.6 | 304.9 | 7277.6 | +1.0% | +1.0% | tuned |
| `GCRY_DISABLE_SCRUB_FIBERS=1` | 6461.2 | 301.6 | 7243.5 | +0.4% | +0.5% | tuned |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | 6398.9 | 293.5 | 7218.9 | +0.2% | +0.2% | tuned |
| `GCRY_INTERIOR=1` | 6342.9 | 306.1 | 7185.5 | −0.4% | −0.3% | tuned |

**The entire cost of the sound profile at EC4 is the STW lag knobs.** Setting
them alone reproduces the full profile to within the measurement's spread
(+1866.3% vs +1866.5% on pause); the other five heuristics together stay under
1.5%. This is not a percentage-level effect — the pause goes from **7.2 ms to
141.7 ms**, per collection.

That matches the origin story: the lag knobs were introduced against EC4
`phase_roots` ~100 ms/collect. `GCRY_SOUND=1` zeroes them and the regression
they were built to fix comes straight back (136 ms here).

## Which lag knob (`2026-08-06-090503-root-phase/`)

Same shape, 3 configs × 3 reps × 20 s:

| Config | work µs | pause µs | Δwork | Δpause |
|--------|--------:|---------:|------:|-------:|
| tuned | 6738.6 | 7249.4 | — | — |
| `GCRY_STW_STACK_LAG=0` | 137204.5 | 137876.3 | +1936.1% | **+1801.9%** |
| `GCRY_STW_PTHREAD_LAG=0` | 11360.8 | 11915.9 | +68.6% | **+64.4%** |

The two are additive (1802 + 64 ≈ 1866) and both are real, but they are not
the same order:

- **`stw_multi_stack_lag`** is the whole story — 19× the pause on its own, all
  of it inside `roots_ns` (6.4 ms → 137 ms) with `stacks_ns` untouched.
- **`stw_multi_pthread_lag`** is a genuine secondary cost, +64% pause, and it
  lands entirely in `stacks_ns` (304 µs → 4.7 ms) with `roots_ns` flat.

So the two knobs are not variants of one mechanism: one governs re-scanning
thread stacks during the root phase, the other the per-thread stack walk. Work
aimed at making lag 0 affordable has to target them separately, and
`stw_multi_stack_lag` first.

## Confidence

Root-phase IQR is 1.2–1.6% on the slow configs, so this is a consistent steady
state, not an outlier. Every config reports `thr=5`, so the EC4 shape genuinely
applied. Labels are correct — `no-stw-lag` and `stack-lag-0` report `tuned`
because they move only one axis. Each config contributed 493–1167 collections.

The slow configs complete roughly half as many collections in the same 20 s
(≈495 vs ≈1150). The medians are per collection so this does not distort the
comparison, but the mutator loses proportionally more time than the
per-collection figure alone suggests.

## The trap this run had to avoid

The server raises parallelism with `Fiber::ExecutionContext.default.resize(n)`,
which is a **no-op unless the binary was built with `-Dpreview_mt
-Dexecution_context`**. An EC4 run against the ordinary release binary
therefore measures EC1 while every label and env var claims EC4. The harness
now takes build flags from the environment, writes a separate binary name, and
records the server's thread count per rep — 5 under load at EC4 (4 workers +
main) against 2 at EC1. `meta.json` carries the build flags and
`EC_PARALLELISM`.

## What this changes

EC1 said the sound profile is effectively free: +1.3% of root work and **+0.1%
of pause**. That does not survive contact with parallel EC, and the two results
are not in tension — they are the same five cheap heuristics plus one knob
whose cost is invisible at parallelism 1 (`stacks_ns` is ~13 µs at EC1, 304 µs
here before the knob and 4.7 ms after).

For the defaults question (handover §6f): **shipping the sound profile by
default is not defensible in this shape.** It would be a 19× pause regression
for anyone on the supported Parallel EC opt-in, and pause is precisely what
that configuration is chosen for. The tractable path is to make root scanning
under Parallel EC cheap enough that lag 0 is affordable — starting with
`stw_multi_stack_lag` — not to trade the lag knobs away by default.

## Limits

- Pause composition, not throughput. See the EC1 FINDINGS for why the
  throughput channel is unusable here.
- One workload, one host, EC4 specifically. Nothing here measures EC2, EC8, or
  a workload with a different thread-stack profile.
- `sweep_ns` (~14.4 ms) again exceeds the pause and is outside it.
- The EC1 cut's FINDINGS quotes deltas on a `roots+scrub` basis, before
  `stacks_ns` was known to be additive. At EC1 `stacks_ns` is flat across
  configs, so its numbers shift by tenths of a point and its conclusions are
  unaffected; on this basis EC1 sound is +1.3% work / +0.1% pause.
