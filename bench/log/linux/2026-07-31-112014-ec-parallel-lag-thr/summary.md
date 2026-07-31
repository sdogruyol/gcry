# EC parallel thr re-cut (STW LAG 512KiB)

Session: `2026-07-31-112014-ec-parallel-lag-thr` (`94aadaf`)
Method: `wrk -c 100 -d 30`, median-of-3, TLAB **off**, fresh process/trial.
Host: WSL2 · Crystal 1.21.0

## Med req/s

| Config | `/json` | `/` | RSS note |
|--------|--------:|----:|----------|
| Boehm EC1 | 38196 | 76890 | (rss capture unreliable this run) |
| Boehm EC4 | 76447 | 105771 | |
| gcry EC1 | 32272 | 61883 | |
| gcry EC4 | 28085 | 68102 | LAG; `/json` trials 29096 / **8485** / 28085 |

| Compare | `/json` | `/` |
|---------|--------:|----:|
| gcry EC1 % Boehm EC1 | **84.5%** | **80.5%** |
| gcry EC4 % Boehm EC4 | **36.7%** | **64.4%** |
| Boehm EC4/EC1 | **2.00×** | **1.38×** |
| gcry EC4/EC1 | **0.87×** | **1.10×** |

## vs pre-LAG (`2026-07-31-100844`)

| Compare | pre-LAG | LAG |
|---------|--------:|----:|
| gcry EC4 % Boehm EC4 `/json` | ~23% | **~37%** |
| gcry EC4 / gcry EC1 `/json` | ~0.52× | **~0.87×** |

One `/json` EC4 trial collapsed to ~8.5k (process likely wedged mid-run, rss=0); median still ~28k. Do **not** fold into Linux `docs/PERF.md` (EC1 headline).

## TLAB@EC4 (same session)

| Check | Result |
|-------|--------|
| Soak 20×8s `GCRY_TLAB=1` | **17/20** (3 DIE) |
| `/json` d=20 med-of-5 | TLAB-off **17844** / TLAB-on **18280** |

TLAB@EC4: correctness flakier than TLAB-off; thr not a clear win vs good LAG off runs. Stay opt-in.
