# EC4 dormant + lazy sweep compatibility

Tip: lazy gate **78.8%** `/json`, RSS ~5.8×. Prior opt-in dormant **71.7%**
/ ~1.7× (lazy was forced off). Parent FINDINGS:
`../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever

1. `sweep_after_world?` — forbid post-STW lazy only for **munmap** / HOLED,
   not dormant-only empty reclaim.
2. Skip O(blocks) walk for already-dormant size-class chunks; recount retain
   budget. Counter: `sweep_dormant_skips`.

## Soft soak (retain 32 MiB, `wrk -c100 -d8` ×40)

| OK | soft | thr med | pause p50 | sweep med | skips med | RSS med |
|---:|-----:|--------:|----------:|----------:|----------:|--------:|
| **40/40** | **0** | **~55.3k** | **~8.8 ms** | ~19.5 ms | **0** | **~66 MiB** |

## Quiet thr (`wrk -c100 -d30` med-of-3, `/json`)

| Config | % Boehm | gcry | Boehm | RSS × |
|--------|--------:|-----:|------:|------:|
| dormant+lazy retain 32 | **75.1%** | 55,256 | 73,585 | **4.03×** |
| prior dormant (no lazy) | 71.7% | ~63k | ~88k | ~1.7× |
| lazy gate (no dormant) | **78.8%** | ~69k | ~88k | ~5.8× |

## Why skips ≈ 0

HTTP freelist churn revives dormant chunks before the next major; each
collect re-DONTNEEDs. Sweep walk length stays ~chunk count. RSS still drops
vs gate; thr stays below lazy-only.

## Verdict

**Ship opt-in improvement** (lazy stays on with `PARALLEL_DORMANT`). Soft
green; pause matches lazy. **Not** Parallel default (75.1% &lt; 78.8%).
Stretch ~80% still needs a lever that **removes** chunks from the walk
(e.g. careful post-STW munmap of excess) without revive churn.
