# EC4 STW scan dedupe + LAG 256 KiB

Tip after v0.16.0. TLAB off. Parent FINDINGS:
`../2026-07-29-parallel-tlab-FINDINGS.md`.

## Levers

1. **`phase_scrub_ns`** — parked-fiber scrub timed separately on `/gc-stats`
   (excluded from `phase_roots_ns`).
2. **Parallel stack dedupe** — drop `scan_fiber_stack_full` in
   `scan_other_thread_stacks`; `scan_all_fiber_roots` already covers running
   fibers under `stw_multi`. Keep greg + `scan_stack_containing_sp` + pthread.
3. **Default `stw_multi_stack_lag` 256 KiB** (was 512) after A/B below.

## Soft soak (`wrk -c100 -d8` `/json`, fresh process/trial, soft counted)

| Config | OK | soft | hard | OK thr med |
|--------|---:|-----:|-----:|-----------:|
| dedupe + LAG 512 | **40/40** | **0** | **0** | **~53.7k** |
| dedupe + LAG 256 | **40/40** | **0** | **0** | **~49.7k** |

## Quiet thr (`wrk -c100 -d30` med-of-3)

| Config | Session | `/json` med | notes |
|--------|---------|------------:|-------|
| dedupe + LAG 512 vs Boehm EC4 | `2026-08-01-084247` | **~50.6k** (**66.5%** Boehm) | Boehm med ~76.0k |
| dedupe + LAG 256 (gcry only) | `2026-08-01-085706` | **~58.3k** | ≥ 512 cut; ship |
| EC1 smoke `/json` | `2026-08-01-090325` | **~31.4k** | no EC1 regress vs 0.16 band |

Cross-session vs Boehm EC4 from 084247: LAG 256 ~**76.7%** (not same-host
re-cut; cite abs). Prior thr-gap recut was ~68% @ ~53k.

## Phase timings (last-collect med, `/json` LAG 512 dedupe)

| Phase | Prior sizeclass (`v2-off-t1`) | Dedupe |
|-------|-----------------------------:|-------:|
| roots | ~12.5 ms | **~2.2 ms** (scrub split out; scrub ~12 µs) |
| stacks | ~12.5 ms | **~6.5 ms** |
| pause p50 | ~48 ms | **~37 ms** |

## Gates

- `stw_mt_property_test --workers=2,4` **PASS** (default LAG 256 rebuild)

## Verdict

Ship dedupe + LAG 256 default. Soft green. Pause phases cut; quiet thr abs
up on LAG 256. EC>1 still **experimental** (RSS high; no `PERF.md` fold-in).
Stretch bar ~80% Boehm needs a quiet same-host Boehm+gcry re-cut.
