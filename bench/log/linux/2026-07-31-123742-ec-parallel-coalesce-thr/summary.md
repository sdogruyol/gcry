# EC parallel thr re-cut (LAG + post-STW mutex + coalesce)

Session: `2026-07-31-123742-ec-parallel-coalesce-thr`
Commit: 4d78af0 Cut EC4 collect queue: post-STW mutex + auto-collect coalesce. SpinLock wait burned ~half a Kemal run; sleeping mutex plus skip-when-peer-collected brings /json to ~40k with 20/20 soak.
Method: `wrk -c 100 -d 30`, median-of-3, TLAB **off**, fresh process/trial.

## Med req/s

| Config | `/json` | `/` |
|--------|--------:|----:|
| Boehm EC1 | 37286 | 80133 |
| Boehm EC4 | 69910 | 116713 |
| gcry EC1 | 31123 | 65423 |
| gcry EC4 | 36447 | 74804 |

| Compare | `/json` | `/` |
|---------|--------:|----:|
| gcry EC1 % Boehm EC1 | 83.5% | 81.6% |
| gcry EC4 % Boehm EC4 | 52.1% | 64.1% |
| Boehm EC4/EC1 | 1.87× | 1.46× |
| gcry EC4/EC1 | 1.17× | 1.14× |

## vs prior sessions

| Session | gcry EC4 % Boehm EC4 `/json` | gcry EC4/EC1 `/json` |
|---------|----------------------------:|---------------------:|
| pre-LAG `100844` | ~23% | ~0.52× |
| LAG only `112014` | ~37% | ~0.87× |
| **this (LAG+mutex+coalesce)** | **52.1%** | **1.17×** |

Do **not** fold into Linux `docs/PERF.md` (EC1 headline). EC>1 remains experimental.

## Extra (gcry EC4 `/json` med trial)

- collections ~182, coalesced ~328, pause p99 ~107ms, post_stw wait_total ~17s / 30s
- RSS med ~39 MB vs Boehm EC4 ~17 MB (still higher)
- All 24 trials completed (no BOOT_FAIL / FAIL)
