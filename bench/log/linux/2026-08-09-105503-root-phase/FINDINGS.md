# Fat app: the default path overtakes both the old default and `GCRY_SOUND=1`

Host: 12th Gen Intel i3-12100F (4C/8T), WSL2, Crystal 1.21.0, `--release`, EC1.
Fat app (acikturkiye) `/api/v1/`, 21 paired reps × 20 s, interleaved with the
config order rotated each round. The server binary was rebuilt against this
branch — `acikturkiye/lib/gcry` symlinks to the working tree, so a stale
`bin/acikturkiye-gcry` would have measured whatever branch last built it.

Companion to `../2026-08-09-104417-root-phase/` (Kemal EC4), which is the
cleaner measurement; this one carries a confound the EC4 run does not.

## Result — stratified

The app is bistable between a ~46 MiB and a ~72 MiB heap regime, so the raw
medians are not comparable and the harness says so. Stratified at 55 MiB:

```sh
bench/stratify_root_phase.py bench/log/linux/2026-08-09-105503-root-phase --cut=55
```

| Stratum | config | reps | pause ms | Δpause | work µs | Δwork |
|---------|--------|-----:|---------:|-------:|--------:|------:|
| ~46 MiB | `tuned` | 14 | 2.9 | +0.0% | 1114 | +0.0% |
| ~46 MiB | `tuned-nolw` | 18 | 2.9 | +1.6% | 1119 | +0.4% |
| ~46 MiB | `sound` | 16 | 3.0 | +6.5% | 1158 | +3.9% |
| ~72 MiB | **`tuned`** | 13 | **10.7** | +0.0% | **5144** | +0.0% |
| ~72 MiB | `tuned-nolw` | 9 | 28.8 | **+169.3%** | 21832 | **+324.4%** |
| ~72 MiB | `sound` | 12 | 18.2 | +70.2% | 11597 | +125.4% |

The new default beats **both** the old default and `GCRY_SOUND=1`. It starts at
`max(stack_top − 256 KiB, low_water)`: bounded by the lag *and* clear of the
untouched head. `sound` has only the second protection, so a fiber that once ran
deep drags its start below the lag floor.

## Why the raw table would have led the other way

Unstratified, the harness reports `tuned-nolw` at **−73.6% work** — i.e. the
control looking dramatically better than the change. That is regime mixing: the
control drew 9 large-heap reps against 13 and 12. Without stratifying, this run
argues for reverting the change.

## The confound this run carries

`multi_mutator_threads?` is `Thread` count **> 2**, and this app sits on that
boundary. The binary built 2026-08-06 reported 2 threads; the rebuild here
reports 3. The harness's `thr` column is a single `/proc` sample at the end of a
rep, not a per-collection reading, so some collections in a rep may have run
with the lag path inert and others with it live.

This does not change the direction — when the path is inert the change is a
no-op and cannot be worse — but it does mean **the magnitudes here are softer
than they look**, on top of the 39–74% within-stratum IQR. Cite the EC4 run for
a number; cite this one for the shape holding on a second, very different
workload.

`heap.low_water_skips` / `low_water_skipped_bytes` (added with this change, on
`/gc-stats`) exist to make that gate observable rather than inferred — this run
predates them.

## RSS: not readable here

```
tuned       reps: 75696,63456,70708,44888,44284,68224,73196,45784,67728,50344,…
tuned-nolw  reps: 81040,46304,45728,76020,72840,79476,62312,69248,50212,45988,…
sound       reps: 78048,77256,79568,76792,76164,47000,67912,45332,77396,80836,…
```

Every config draws from both regimes; the medians report which regime got more
reps, not what the collector retained. `tuned-nolw`'s apparent −28.8% is that
artefact. No RSS claim comes out of this run.
