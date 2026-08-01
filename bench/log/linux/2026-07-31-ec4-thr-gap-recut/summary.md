# EC4 thr gap re-cut (trylock-skip + Parallel 64 MiB threshold)

Tip after empty-chunk Parallel gate + index_lock fix. TLAB off.
`wrk -c 100 -d 30`, median-of-3. Session: this dir.

## Levers

1. **Auto-collect trylock-or-skip:** do not sleep on `@post_stw` when
   `coalesce` — failed trylock increments `collect_coalesced` and returns.
   Wait_total ~11s/20s → ~0 (yield-loop variant *hurt* thr; skip wins).
2. **`EC_PARALLELISM>1` default threshold 64 MiB** (`PROCESS_GC_THRESHOLD_PARALLEL`),
   unless `GCRY_THRESHOLD` set. A/B d=20: 32→**~47k**, 64→**~53k**, 128→~51k.
3. Fiber scrub off: thr regresses — keep default-on.

## Medians (req/s)

| Config | `/json` | `/` |
|--------|--------:|----:|
| Boehm EC1 | 76167 | 128584 |
| Boehm EC4 | 77997 | 111591 |
| gcry EC1 | 51863 | 89666 |
| gcry EC4 | 53200 | 83472 |

| Compare | `/json` | `/` |
|---------|--------:|----:|
| gcry EC4 % Boehm EC4 | **68.2%** | **74.8%** |
| gcry EC1 % Boehm EC1 | **68.1%** | **69.7%** |
| gcry EC4/EC1 | **1.03×** | **0.93×** |
| Boehm EC4/EC1 | **1.02×** | **0.87×** |

Prior coalesce cut (`123742`): EC4 `/json` **~52%** Boehm @ **~36k** abs;
EC4/EC1 **~1.17×**. This host pass: Boehm barely EC-scales (noise); **absolute**
gcry EC4 `/json` **~53k** (was ~36k). Do **not** fold into `docs/PERF.md`.

## Notes

- `post_stw_wait_total` often \<1 ms (occasional ~40 ms).
- Parallel empty-chunk release still off → RSS ≫ Boehm.
- EC>1 remains experimental.
