# acikturkiye gcry vs Boehm — 2026-08-23, paired and order-rotated

**Not a headline cut.** The host is a developer desktop and was not idle: load
average went 4.86 → 12.50 across the run, with a `crystal` compile, chromium,
electron and postgres competing for the same 20 cores. Absolute req/s from this
machine means nothing, and nothing here can be compared with the i3-12100F or
9950X sessions the published band comes from.

What survives that is the **paired ratio**. Each trial runs both arms
back-to-back and the order alternates, so within-trial drift cancels instead of
always landing on the same arm; the reported figure is the median of the
per-trial ratios, not the ratio of the medians.

Binaries: `-Dgc_none --release` and `--release`, both at gcry `114b5cd`
(`chunk-index-race` merged). Path `/api/v1/` (36 KB JSON), `wrk -c 100 -d 20`,
5 s warmup, fresh process per run, dual `/gc-collect` then `VmRSS`.

| trial | first | Boehm req/s | Boehm KiB | gcry req/s | gcry KiB | thr | RSS |
|------:|-------|------------:|----------:|-----------:|---------:|----:|----:|
| 1 | boehm | 948.71 | 61,356 | 824.33 | 87,376 | 86.9% | 1.42× |
| 2 | gcry  | 930.34 | 55,780 | 812.13 | 84,988 | 87.3% | 1.52× |
| 3 | boehm | 932.17 | 51,712 | 819.79 | 85,416 | 87.9% | 1.65× |
| 4 | gcry  | 948.30 | 60,484 | 812.07 | 86,748 | 85.6% | 1.43× |
| 5 | boehm | 904.29 | 51,600 | 811.05 | 85,296 | 89.7% | 1.65× |
| 6 | gcry  | 925.10 | 58,140 | 803.44 | 85,168 | 86.9% | 1.46× |

**Median of per-trial ratios: thr 87.1% of Boehm, post-GC RSS 1.49×.**

## What the design bought

The throughput ratios span **85.6–89.7%** — a 4-point spread — while the
absolute numbers wander (Boehm 904–949) and the host load more than doubles
underneath. The first attempt at this, with a fixed boehm-then-gcry order and
n=3, produced 77.8% and a Boehm column that fell 1114 → 1018 → 845 monotonically:
a fixed order charges all of the within-trial drift to whichever arm runs second.
Rotating the order removes it — boehm-first trials give 86.9 / 87.9 / 89.7 and
gcry-first give 87.3 / 85.6 / 86.9, with no separation between the two groups.

`docs/ACIKTURKIYE.md` already records the n=3 failure on this app and says not
to cite such a median; this is the same lesson arriving again, on a different
host.

## Two things worth noting from the run

- **gcry's RSS is the stable column, not Boehm's.** gcry 85.2–87.4 MiB across
  six trials; Boehm 51.6–61.4 MiB. Almost all of the RSS-ratio spread
  (1.42–1.65×) comes from Boehm moving, not from gcry.
- **No sign of the bistable heap regime here.** gcry reported 227–232
  collections and an 87–91 MiB heap in every trial, which is one regime, not two.

## What it does not say

Whether the tip is inside the published **~90–96% thr @ ~1–1.6× RSS** band.
87.1% is below that band's throughput floor, and this host cannot resolve a
3-point difference: different CPU, and a load average that doubled mid-run. A
quiet-machine cut is what would answer it.

Reproduce: `bash bench/acik_ab.sh` (see the script header for knobs).
