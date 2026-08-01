# EC4 quiet re-cut (dedupe + LAG 256 default)

Tip `5ddd56b` · Crystal release · WSL2 · `EC_PARALLELISM=4` · TLAB off ·
`wrk -c100 -d30` med-of-3 · same-host Boehm+gcry.

Session: `bench/log/linux/2026-08-01-092050/`

## Medians

| Path | Boehm | gcry | % Boehm | RSS × |
|------|------:|-----:|-------:|------:|
| `/` | 91,388 | 95,332 | **104.3%** | **6.20×** |
| `/json` | 65,244 | 46,623 | **71.5%** | **5.51×** |

`/json` trials gcry: 46623 / **52808** / 43548. Boehm: 65244 / 56544 / 70363.

## vs prior

| Cut | gcry `/json` | % Boehm EC4 |
|-----|-------------:|------------:|
| thr-gap recut (pre-dedupe) | ~53k | **~68%** |
| LAG 512 dedupe same-host | ~50.6k | **66.5%** |
| LAG 256 abs (cross-session) | ~58.3k | ~77% *(Boehm other session)* |
| **This re-cut (shipped defaults)** | **~46.6k** | **71.5%** |

## Verdict

Same-host `/json` **71.5%** — above pre-dedupe ~68%, **below** campaign bar
≥75% (stretch ~80%). Idle `/` noisy/above Boehm. RSS still ~5.5× (reclaim-off).
EC>1 remains experimental; no `PERF.md` fold-in.
