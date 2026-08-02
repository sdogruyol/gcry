# EC4 STW parallel sweep — REJECT

Tip after mark-gen (76.6% `/json`) and used_count skip reject. TLAB off.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever

Partition size-class reclaim across STW-exempt raw pthreads (shared mark
pool). Per-slot freelist heads + serial merge/policy. Gate: major +
`!release_empty_chunks_this_collect?` (Parallel reclaim-off). Auto
`parallel_sweep_workers = min(EC, 8)` when `EC_PARALLELISM>1`;
`GCRY_PARALLEL_SWEEP` overrides (`1` = serial).

## Soft soak (`wrk -c100 -d8` `/json` ×40, default EC4 → sweep=4)

| OK | soft | hard | OK thr med |
|---:|-----:|-----:|-----------:|
| **40/40** | **0** | **0** | **~41.8k** |

`parallel_sweep_runs` engaged; last `phase_sweep` ~9.5 ms (not a win).

## A/B (`wrk -c100 -d8` `/json` ×3, same binary)

| `GCRY_PARALLEL_SWEEP` | thr med | phase_sweep | runs |
|----------------------:|--------:|------------:|-----:|
| **1** (serial) | **~65k** | ~10–11 ms | 0 |
| **2** | ~63k | ~9–10 ms | ~46 |
| **4** (EC default) | **~49k** | ~9–10 ms | ~35 |

Sweep phase flat; thr regresses with helper count. Spin-wait pthread pool
(idle `Intrinsics.pause` loop) steals cores from EC mutators even between
collects — same pool design as parallel mark.

## Gates

- `stw_mt_property_test` plain + `--tlab` + `GCRY_PARALLEL_SWEEP=4` **PASS**
- `spec/collect_spec` + `heap_spec` **PASS**
- Soft **0/40**

## Verdict

**Reject** (code reverted). Soft green, but quiet/soak thr well below mark-gen
**~67k / 76.6%** bar. Parallelizing reclaim does not cut `phase_sweep` enough
to pay for helper-pool CPU. Next residual: RSS reclaim balance, or accept
≥75% and document stretch ~80% as open without sweep parallel.

No quiet med-of-3 vs Boehm (A/B already decisive vs serial same-host).
