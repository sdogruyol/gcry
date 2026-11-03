# 0.40 on the Linux host against 0.39.0 and Boehm, second refresh (2026-11-05)

The README's Linux table again, on the `release-0.40.0` tip `2658369a`, the
method of `../2026-11-01-0.40-linux-host/` unchanged: since that session
(`src/` at `2c600dfb`) the default path took the growth-priced pace
(`a62a47fd..f3ccc4dc`), hot heap fields first (`19cf3a60`), the scrub band
(`e2737a33`), the pthread clamp (`21462240`), the parked-seed and Monitor
scrubs (`23a78cd9`, `2c6a3aa4`, `acd6d3e4`, `7bfb0358`, `2658369a`) and
claimed-not-live (`2721f940`). Against `v0.39.0` (`c0d570c5`) and Boehm,
Crystal 1.21.0, QEMU x86-64 guest, 12 vCPUs. Every arm is the tip's
`bench/crystal_metric` and `bench/kemal` with only `lib/gcry/src` swapped
(`build.sh`), `--release`, `-Dgc_none` for gcry, 16- and 64-byte pad arms
of both trees (nops ahead of all code). `session.sh`: crystal-metric with
`../2026-10-31-revcomp-host-placement/scripts/ab.py`, 11 reps, ten
benches, seven arms in random order per rep, under one hold of the heavy
lock; then Kemal with `../2026-10-18-0.37-kemal/kemal_ab.sh`, 9 trials, the
lock per run. Kemal `/json` read 0.40 slower than 0.39.0, so `kpads.sh`
followed: Kemal again with the 16- and 64-byte pad arms of both trees (seven
arms, 9 trials). Nothing else was built or run on the host meanwhile.

Session 2026-11-03 04:21 – 04:49 UTC, Kemal pads 04:53 – 05:22. Load
(`load.txt`, 30 s samples): 1.00–1.62 during crystal-metric, 1.65–2.43
during Kemal and 1.15–3.59 during the Kemal pads (Kemal's own server and
`wrk` are on the host); the first refresh read 1.03–1.96 and 1.12–2.50.
`host-snapshots.txt` has `uptime` and the top processes before, at each
step and after: the desktop (gnome-shell, ptyxis) and idle agent shells, no
other benchmark or build. No process of the session was left running.

Files: `cm.md` (ab.py's table, ratio of medians), `cm-runs.json`,
`cm-paired.txt` (per arm, paired against `v039`: wall, timed section,
setup; `../2026-10-31-revcomp-host-placement/scripts/an.py`), `kemal.tsv`,
`kemal-summary.txt`, `kemal-pads.tsv`, `kpads-summary.txt`,
`malloc-atomic-phase.txt` (`GC::malloc_atomic<UInt64>`'s address in each
binary, mod 64).

## crystal-metric

Speed % of Boehm / peak × Boehm (ratios of medians, as the README's table),
0.40 against 0.39.0 paired wall (median [IQR]), and each tree's spread of
median wall over its three placements (plain, p16, p64), in seconds:

| bench | Boehm | 0.39.0 | 0.40 | 0.40 vs 0.39.0, paired wall | pad range 0.39.0 | pad range 0.40 |
|---|---:|---|---|---:|---:|---:|
| Primes | 0.669 s, 659 MB | 105% / 0.94× | 105% / 0.94× | +0.2% [−2.0, +1.9] | 0.637–0.638 | 0.628–0.639 |
| JsonParsePure | 0.841 s, 690 MB | 105% / 0.81× | 106% / 0.80× | −0.8% [−2.7, +1.5] | 0.798–0.815 | 0.793–0.809 |
| Binarytrees | 0.528 s, 51 MB | 109% / 0.74× | 112% / 0.74× | −2.4% [−3.2, −1.3] | 0.476–0.486 | 0.471–0.478 |
| JsonGenerate | 1.539 s, 1303 MB | 107% / 0.59× | 108% / 0.59× | −0.4% [−1.3, +0.4] | 1.442–1.466 | 1.422–1.446 |
| JsonParseSerializable | 0.868 s, 572 MB | 107% / 0.71× | 107% / **0.77×** | −0.1% [−1.3, +2.0] | 0.814–0.834 | 0.815–0.840 |
| JsonParsePull | 0.854 s, 539 MB | 105% / 0.76× | 107% / **0.78×** | −1.9% [−2.4, −1.0] | 0.813–0.824 | 0.801–0.831 |
| RegexDna | 2.385 s, 496 MB | 98% / 0.44× | 100% / 0.44× | −0.9% [−2.1, +1.1] | 2.397–2.430 | 2.395–2.415 |
| Revcomp | 1.940 s, 833 MB | 97% / 0.63× | 98% / 0.63× | −2.1% [−2.4, −1.6] | 2.000–2.010 | 1.973–1.997 |
| Knuckeotide | 0.680 s, 47 MB | 100% / 1.18× | 101% / 1.17× | −0.5% [−2.1, +1.2] | 0.676–0.679 | 0.676–0.679 |
| Brainfuck | 2.662 s, 14 MB | 106% / 1.00× | 106% / 1.00× | −0.6% [−4.8, +5.0] | 2.501–2.573 | 2.503–2.589 |

- **No wall time slower than 0.39.0 beyond its spread.** Every row's pad
  ranges overlap but Revcomp's, where all three 0.40 arms are faster than
  all three 0.39.0 arms; Binarytrees, JsonParsePull and Revcomp are faster
  beyond their spread. The first refresh had Primes +2.0% and
  JsonParseSerializable +0.7% slower unpadded (inside 0.39.0's placements);
  both are level here.
- **Peaks: JsonParseSerializable 0.71× → 0.77× (439 against 408 MB, +7.5%)
  and JsonParsePull 0.76× → 0.78× (419 against 408 MB, +2.6%).** Both are
  the growth-priced pace, which trades peak for fewer collections on these
  two rows (`../2026-11-02-pace-growth/`: +3% to +16% against the tip
  before it, at most 0.99× Boehm's); in the first refresh (before the pace)
  0.40 matched 0.39.0's peak on both. Every 0.40 arm reads 428–439 MB and
  every 0.39.0 arm 408 MB, so it is not placement. Both stay at or under
  0.78× Boehm's. Every other row's peak is within ±1.5% of 0.39.0's
  (JsonParsePure −1.4%).
- **Revcomp: 98% of Boehm, 0.39.0 97%.** The allocation entry moved:
  `GC::malloc_atomic<UInt64>` starts at `0x1c3c0` (≡ 0 mod 64, the fast
  phase of `../2026-10-31-revcomp-host-placement/`) in 0.40 unpadded and at
  `0x1c390` (≡ 16, the slow one) in 0.39.0 unpadded. Timed sections over
  each tree's three placements: 0.40 0.542–0.564 s (≡ 0, 48, 32), 0.39.0
  0.561–0.580 s (≡ 16, 0, 48), the slowest 0.39.0 arm the one at ≡ 16;
  paired −6.8% timed, −2.1% wall. [INFERENCE] the gain is where the entry
  and the bench's loop land, as attributed on 2026-10-31, not a faster
  collector: 0.39.0 padded by 16, at ≡ 0, closes 0.016 of the 0.038 s gap.
- The whole session ran slower than the first refresh's (Boehm Primes
  0.669 against 0.616 s, JsonGenerate 1.539 against 1.498 s), the host on
  the day; 0.40's ratios are within a point of that session's on every
  allocating row but Knuckeotide (101% against 99%) and Binarytrees (112%
  against 107%, with 0.39.0 at 109% against 107%).
- Brainfuck, which allocates nothing, spans 3% across each tree's pads,
  and reads 106% for both trees against Boehm here (99–100% in the first
  refresh): Boehm's arm, not gcry's.

## Kemal

`kemal-summary.txt` (9 trials, ratios of medians; `kemal_ab.sh` prints them
against whichever arm comes first, here 0.40) and `kpads-summary.txt`:

| route | Boehm | 0.39.0 | 0.40 | 0.40 vs 0.39.0, paired per trial |
|---|---:|---:|---:|---:|
| `/json` | 44 286 req/s, 16.0 MB | 105.6%, 1.24× | **103.6%, 1.24×** | −1.8% [−2.0, −0.9] |
| `/` | 72 488 req/s, 16.0 MB | 98.0%, 1.23× | **97.2%, 1.24×** | −2.6% [−3.1, −0.2] |

- **`/json` is 1.8% slower than 0.39.0 beyond the spread here, and that is
  placement.** In the pad session, paired against 0.39.0 unpadded: 0.39.0
  padded by 16 bytes −2.0% [−3.4, −1.7] and by 64 −0.9% [−1.5, +0.7]; 0.40
  −2.1% [−3.3, −0.4], padded by 16 −1.3% [−3.0, −0.7], by 64 −1.8% [−2.4,
  +0.6]. % of Boehm: 0.39.0's arms 102.2–104.9%, 0.40's 103.3–104.3%, all
  three 0.40 arms inside 0.39.0's band. Kemal `/json` moves with the
  stdlib JSON/HTTP path's placement (`../2026-10-19-kemal-placement/`).
- **`/` −2.6% [−3.1, −0.2]** in the main session and −0.6% [−1.6, +1.1]
  in the pad session, 0.39.0 padded at +0.3% and +2.8%, 0.40 padded at
  −0.9% and +0.7%: level. `/` is not GC-bound.
- Peaks: the same 19.8 MB on both routes and every arm (19.7–19.9 MB).
- In the first refresh's session 0.40 read 106.8% on `/json` (0.39.0
  104.4%); 0.39.0 reads 105.6% and 104.9% in the two sessions here. The
  rows move by about two points between sessions for both trees.
