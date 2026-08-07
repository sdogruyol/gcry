# `scrub_fibers` re-cut — every axis, second session

Three runs, one evening, all on `feat/sound-defaults`.

**Host: i3-12100F (4c/8t, one 12 MiB L3), WSL2 — not the 9950X the office
session's numbers come from.** Every comparison below against an earlier figure
is therefore cross-host. That was not noticed while the runs were taken; the
harnesses did not record the CPU, and they do now.

- `../2026-08-06-192859-sound-profile/` — Kemal `/json` throughput + post-GC RSS,
  9 interleaved rounds × 20 s, `tuned` vs `GCRY_DISABLE_SCRUB_FIBERS=1` vs Boehm.
- `../2026-08-06-194128-root-phase/` — Kemal per-collection phases, 3 reps × 20 s.
- this dir — acikturkiye per-collection phases + post-GC RSS, 9 reps × 40 s.

The purpose was to validate the ROADMAP item "turn `scrub_fibers` off by
default: it loses on every axis measured". It does not.

## 1. Throughput — retracted, and unresolvable in principle

| | office session | this session |
|---|---|---|
| paired mean | **+1.29%** (scrub-off ahead) | **−1.22%** (scrub-off behind) |
| rounds won | 8/9 | 3/9 |
| significance | 3.2σ | 1.25σ, 95% CI −3.47%…+1.04% |

Opposite sign — but on a different machine, so this is not the clean
same-host contradiction it was first written up as. Per-round sd was 2.93% here
against the ~1.2% the 9950X run's 3.2σ implies, which is what a 4-core part
under the same load would be expected to do. Neither of those is the reason to
distrust either number.

The reason is the effect size. From the phase trace on the same workload:

- 131 collections per 20 s pass
- `roots + scrub + stacks` = 223 µs per collection → 29 ms per 20 s → **0.146%
  of wall time**
- turning scrub off moves that by 9.1% → **0.013% of wall time**

and there is no indirect path: collection count is identical (131 vs 131), mark
moves 230.2 → 227.6 µs, sweep 2127.0 → 2139.9 µs. Both published readings are
~100× larger than the largest effect the mechanism can produce.

**Neither +1.29% nor −1.22% is a measurement of this knob.** More rounds would
not have helped; the effect is two orders of magnitude under the floor.

## 2. Root work — real, and bigger than recorded

Kemal EC1, 379 steady-state collections per config:

```
config      n     roots   static  stacks   scrub    mark    sweep   pause    Δwork   Δpause
tuned     379     182.3    91.2    13.1     27.6   230.2   2127.0   548.5    +0.0%    +0.0%
no-scrub  379     189.7    92.0    13.0      0.0   227.6   2139.9   529.3    -9.1%    -3.5%
```

−9.1%, against the −1.7% recorded earlier, with IQR tightening 11.2% → 8.2%.
The likely cause of the gap is that the earlier cut ran **blocked** — all of one
config's reps, then the next. `bench/root_phase_ab.sh` now interleaves reps and
rotates the within-round order, the same fix `sound_profile_ab.sh` needed.

Scrub costs 27.6 µs and makes the root scan 7.4 µs cheaper, netting −20.3 µs.

## 3. Kemal RSS — flat

| Config | req/s | % Boehm | RSS × | pause p50 |
|--------|------:|--------:|------:|----------:|
| Boehm | 41699 | — | — | — |
| tuned | 35963 | 86.2% | 0.76× | 0.56 ms |
| scrub-off | 35668 | 85.5% | 0.75× | 0.53 ms |

12704 → 12480 KiB. The `gc_override.cr` note putting scrub on default cites
Kemal RSS 1.04× → 0.95×; that does not appear on today's collector.

## 4. Fat-app RSS — the justification does not reproduce

This is the axis scrub exists for (acik 3.00× → 2.65×). Two runs of the *same
comparison* disagree in sign:

| reps | tuned median | scrub-off median | Δ |
|-----:|-------------:|-----------------:|--:|
| 3 | 43792 KiB | 63972 KiB | **+46.1%** (scrub-off worse) |
| 9 | 70780 KiB | 46048 KiB | **−34.9%** (scrub-off better) |

Per-rep, at n=9:

```
tuned     70504 76536 69928 76892 44012 79136 81236 70780 68992
no-scrub  77788 70608 79652 45152 42312 46460 46048 43220 43668
```

These are not two distributions, they are one bistable outcome: every value is
either ~44 MiB or ~70–80 MiB. acik flips between a small- and a large-heap
collection regime, and post-GC RSS records whichever one the process happened to
end in. tuned ended large 8/9 reps, scrub-off 3/9 — Fisher exact **p = 0.0498**,
at a 55 MiB threshold chosen after seeing the data, with scrub-off's transition
falling in one unexplained consecutive block (reps 1–3 large, 4–9 small).

**A lead, not a result.** The headline phase deltas from the same run (−93.6%
work, −86.4% pause) are pure regime mixture and must not be quoted; the harness
raises its multimodal warning on both configs (IQR 118.7% and 73.7%).

Stratified by regime — the only like-for-like comparison the data supports:

| Stratum | n (tuned / off) | Δwork | Δpause |
|---------|----------------:|------:|-------:|
| small (~44 MiB) | 184 / 449 | −4.3% | −4.0% |
| large (≥55 MiB) | 359 / 100 | +1.4% | +10.3% |

A wash.

## Method notes

- **The fat-app binary was stale.** `acikturkiye-gcry` (built 07:40) returned no
  `soundness` or `scan_static_roots` in `/gc-stats`; both exist in this tree. Its
  `lib/gcry` is a symlink to the live checkout, so a rebuild picks up the branch —
  rebuilt as `acikturkiye-gcry-branch`, and the first acik run of the evening was
  discarded. `root_phase_ab.sh` now names this cause in the error instead of
  reporting `soundness=None`.
- `root_phase_ab.sh` gained per-key `key@binary`, interleaved+rotated reps, and
  post-GC RSS capture (median over reps) during this session.

## What this leaves

No perf axis decides `scrub_fibers`: its stated benefit does not reproduce and
its measured cost is ~0.01% of wall time. What remains is the property it was
listed under — it zeroes below a parked fiber's *estimated* SP, from another
thread, where bdwgc only wipes below the calling thread's own hardware SP. Two
places in `scrub_parked_fiber_stacks` are worth reading against that claim, both
unverified:

- the wipe runs to `top` with no red-zone allowance, while the scanner
  deliberately treats `sp − 128` as live (`STACK_SCAN_RED_ZONE`);
- the mid-swap `fiber_stack_holds_foreign_sp?` guard is applied only under
  `multi`, i.e. skipped at EC1, and the comment justifying that is a throughput
  argument for skipping a safety check.

Next step is a test, not a benchmark.
