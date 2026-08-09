# The fat app's 14.5× sound-pause regression has reversed sign

Host: 12th Gen Intel i3-12100F (4C/8T), WSL2, Crystal 1.21.0, `--release`, EC1.
Fat app (acikturkiye) `/api/v1/` driven through `bench/root_phase_ab.sh`,
**21 paired reps** × 20 s, interleaved with the config order rotated each round.
Confirmed by `../2026-08-09-062117-root-phase/` (9 reps, same shape).

This retires the **17 ms → 213 ms (+1347%)** row that
`docs/SOUND-DEFAULTS.md` and `docs/PERF.md` carried for `GCRY_SOUND=1` on this
app, and closes the ROADMAP item "re-cut the fat app's large-heap case against
the low-water fix".

## The medians are not comparable, and the harness says so

Unstratified, `root_phase_ab.sh` refused the comparison outright:

```
*** WARNING: multimodal samples — these medians are NOT comparable ***
    configs with IQR > 50% of median: tuned, sound
      tuned   heap MiB p10/p50/p90: 45 / 47 / 72
      sound   heap MiB p10/p50/p90: 45 / 47 / 74
```

This app is bistable between a ~46 MiB and a ~70 MiB heap regime and draws its
regime per process, so a median over the mixture is a median over two different
machines. Everything below is stratified at 55 MiB, dropping the first 5
collections of each rep (the heap is still growing there) — the same sample
rule the harness itself uses.

## Result

| Stratum | reps (tuned / sound) | n (tuned / sound) | tuned pause | `GCRY_SOUND=1` pause | tuned root work | sound root work |
|---------|---------------------:|------------------:|------------:|---------------------:|----------------:|----------------:|
| small heap (~46 MiB) | 15 / 15 | 349 / 315 | 2.7 ms | 2.7 ms (**+1.7%**) | 1112 µs | 1142 µs (**+2.7%**) |
| large heap (~70 MiB) | 10 / 13 | 241 / 269 | 24.3 ms | **18.1 ms (−25.4%)** | 20 364 µs | **11 449 µs (−43.8%)** |

`root work` is `roots + scrub + stacks`. The 9-rep run gives −28.8% / −44.2%
against this run's −25.4% / −43.8%: two independent cuts agreeing to 3pp on
pause and 0.4pp on root work.

Reproduce:

```sh
bench/stratify_root_phase.py bench/log/linux/2026-08-09-071144-root-phase --cut=55
```

## Why the default is now the slower path

The low-water skip is gated on `lag == 0` in `fiber_stack_scan_top`. So:

- `GCRY_SOUND=1` sets `stw_multi_stack_lag = 0` → the parked-fiber scan starts
  at the stack's low-water mark and skips the never-faulted head.
- The **default** (`lag = 256 KiB`) takes the `lagged = t - lag` branch, which
  the skip never reaches → it still faults in a fixed 256 KiB window per parked
  fiber, much of which was never written.

On a fat app with many parked fibers that inverts the ordering: the profile
that scans *more completely* scans *fewer pages*. `docs/SOUND-DEFAULTS.md`
predicted the sign from the EC4 cut ("sound's p5 is already below tuned's,
because tuned's fixed 256 KiB window can itself include untouched pages"); here
it is the median of a whole stratum, not a tail.

`mark` moves the other way, as expected from a more conservative profile:
2133 → 2635 µs (+24%) at the large stratum. It is an order of magnitude smaller
than the root-work saving, so it does not change the sign.

## What this does not say

- **The magnitude is soft.** Within-stratum pause IQR is 38% (sound) and 50%
  (tuned) — the harness's own comparability threshold. The sign is reproduced
  across two runs; the −25% is not a three-digit number.
- **Rep counts per stratum are unequal and uncontrollable** (10 vs 13): the
  regime is drawn per process, and nothing in the harness can pin it. More reps
  buys more draws, not balance.
- **It says nothing about Kemal EC4**, where lag 0 still costs +83% and the
  fixed window is not the dominant term. Ungating the skip on the default path
  needs that control before it ships.

## Follow-up

ROADMAP: "Apply the low-water skip to the `lag > 0` default path" — either
ungate the skip or make `lag = 0` the default, gated on a Kemal EC4 control.
