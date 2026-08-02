# EC4 alloc freelist batch pop (TLAB-off) — REJECT default

Tip: lazy Parallel TLAB-off. Goal: cut mutator×lazy freelist lock
contention via USED stash (`GCRY_ALLOC_BATCH=N`).
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever

Under freelist lock, claim up to N FREE nodes as **USED** (+mark while
collecting); stash extras on a per-thread chain; hits skip freelist lock.
STW `flush_all_alloc_batches` returns unused stash to the freelist.
Opt-in env; default **0** (off). A/B used **N=8**.

## Soft soak (`GCRY_ALLOC_BATCH=8`, `wrk -c100 -d8` ×40)

| OK | soft | thr med | pause p50 |
|---:|-----:|--------:|----------:|
| **40/40** | **0** | **~40.2k** | **~9.4 ms** |

Hits/refills show batching engaged (~7:1).

## Quiet thr (`wrk -c100 -d30` med-of-3, `/json`, same-host)

| Config | % Boehm | gcry | Boehm | RSS × |
|--------|--------:|-----:|------:|------:|
| **control** (batch off) | **88.1%** | 49,513 | 56,232 | **5.48×** |
| **batch=8** | **63.3%** | 39,590 | 62,565 | **5.50×** |

Sessions: `../2026-08-02-054813/` (control), `../2026-08-02-054142/` (batch8).

## Why not ship

Soft green, but quiet thr **regresses hard** vs same-host tip (~25 pp / ~−10k
abs). Slot-lock + USED rewrite on hit and/or larger live-before-hand-off
set likely outweigh freelist-lock amortization under Kemal churn.

## Verdict

**REJECT** as Parallel default. Code stays **opt-in** (`GCRY_ALLOC_BATCH`,
default 0) for further dogfood; do not enable by default.
