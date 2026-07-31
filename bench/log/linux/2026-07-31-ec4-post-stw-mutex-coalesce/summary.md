# EC4 pause/thr variance — post-STW mutex + collect coalesce

Date: 2026-07-31 · WSL2 · Crystal 1.21.0 · LAG 512KiB on · TLAB off

## Diagnosis (SpinLock baseline)

15× `wrk -c 100 -d 20` `/json` EC4:

| Class | Trials | Pattern |
|-------|--------|---------|
| Healthy ~21–25k | 12/15 | `post_stw_wait_total` **~8–11s** / 20s; p99 pause ~300–430ms (wait counted in pause) |
| Outlier ~1.5–11k | 3/15 | SEGV / `pointer is not a gcry allocation`; empty `/gc-stats` |

`phase_flush` ~1–4ms; `stw_stop` ~0; LAG roots ~8–20ms. Bottleneck = **serialized collect queue** on `@post_stw` SpinLock (waiters burn an EC worker core).

## Fixes

1. **`@post_stw_mutex`** — embedded `pthread_mutex` (no GC malloc at boot); waiters sleep.
2. **Auto-collect coalesce** — `maybe_collect` → `collect(coalesce: true)`; if a peer collect cleared debt while waiting, skip STW (`collect_coalesced` counter).
3. **Pause timer** — starts after mutex wait (p50/p99 = STW work, not queue time).
4. **`/gc-stats`** — `phase_post_stw_wait_ns`, `phase_stw_stop/start_ns`, `phase_flush_ns`, wait totals, `collect_coalesced`.

## Results

| Config | `/json` med (d=20) | Soak | Notes |
|--------|-------------------:|------|-------|
| SpinLock + LAG | ~22.5k (healthy) | — | 3/15 crash outliers |
| Mutex only | ~20.8k | 15/15 alive | wait still ~12s; no coalesce |
| Mutex + coalesce | **~40.1k** (5 trials 396–413k) | **20/20** | ~220 coalesced/run; p99 ~65–145ms |

EC1 smoke after change: ~34k (no regression).

Do **not** fold into `docs/PERF.md` (EC1 headline). EC>1 still experimental; residual mark-miss class may still appear under longer soak.
