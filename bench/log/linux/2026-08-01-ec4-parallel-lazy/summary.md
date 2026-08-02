# EC4 parallel post-STW lazy sweep — REJECT

Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.
Campaign bar: serial lazy **~78.8%** `/json`.

## Lever

Partition post-STW reclaim across 4 EC fibers by `size_class % N`
(disjoint freelist locks). Large objects stay on the collector fiber.
`GCRY_DISABLE_PARALLEL_LAZY_SWEEP=1` / `GCRY_PARALLEL_LAZY_WORKERS`.

## Soft soak (`wrk -c100 -d8` `/json` ×40)

| OK | soft | hard | OK thr med |
|---:|-----:|-----:|-----------:|
| **40/40** | **0** | **0** | **~56.2k** |

## Quiet thr (`wrk -c100 -d30` med-of-3, `/json`)

| Path | % Boehm | gcry med | Boehm med | RSS × |
|------|--------:|---------:|----------:|------:|
| `/json` | **73.6%** | 53,678 | 72,917 | **5.62×** |

## Why

Steals the same EC cores mutators need during the reclaim window. Serial
lazy already overlaps sweep with mutators under one class lock at a time;
4-way partition increases memory traffic + scheduler contention without
shortening the mutator-visible freelist-lock storm enough to pay back.
`phase_sweep` still ~15–18 ms wall.

## Verdict

**REJECT** (reverted). Soft green; thr below **78.8%** bar.
