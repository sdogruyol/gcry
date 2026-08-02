# EC4 Parallel threshold 96 MiB (lazy tip) — REJECT

Tip: lazy-sweep default **64 MiB** Parallel threshold. Goal: cut ~190
majors/30s post-lazy freelist tax toward stretch **~80%**.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever

Env-only: `GCRY_THRESHOLD=100663296` (96 MiB) vs default
`PROCESS_GC_THRESHOLD_PARALLEL` (64 MiB). No code default change.

## Soft soak (96 MiB, `wrk -c100 -d8` ×40)

| OK | soft | thr med | pause p50 |
|---:|-----:|--------:|----------:|
| **40/40** | **0** | **~60.3k** | **~8.9 ms** |

## Quiet thr (`wrk -c100 -d30` med-of-3, `/json`, same-host)

| Config | % Boehm | gcry | Boehm | RSS × | majors med |
|--------|--------:|-----:|------:|------:|-----------:|
| **64 MiB (control)** | **83.1%** | 54,633 | 65,711 | **5.82×** | **148** |
| **96 MiB** | **80.0%** | 48,854 | 61,093 | **8.43×** | **84** |

Sessions: `../2026-08-02-051726/` (64), `../2026-08-02-050910/` (96).
Host quieter than lazy-sweep tip session (Boehm ~66k vs ~88k); pair is
decisive.

## Why not ship

Majors drop (~148→84) but thr **and** % regress vs same-host 64 MiB;
RSS↑ (~5.8×→8.4×); post-STW `phase_sweep` med ~13→**~17 ms** (larger
heap per epoch). Fewer collects ≠ free thr under reclaim-off freelist
churn.

## Verdict

**REJECT** (default stays 64 MiB). Soft green. Stretch ~80% still open
on a non-threshold surface (e.g. alloc freelist batch).
