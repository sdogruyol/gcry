# EC1 0.16 quiet Kemal cut — NO-GO

git `95c63f0` · Crystal 1.21.0 · WSL2 x86_64 · `wrk -c100 -d30` · med-of-3 · soft=0

## Attempt 1 — this session (`run-01/`)

| Path | % Boehm | RSS × | Boehm med | gcry med |
|------|--------:|------:|----------:|---------:|
| `/json` | **80.4%** | 0.79× | 40,597 | 32,643 |
| `/` | **83.8%** | 0.78× | 90,582 | 75,908 |

## Attempt 2 — `../2026-08-01-083831/run-01/` (cooler start, worse %)

| Path | % Boehm | RSS × | Boehm med | gcry med |
|------|--------:|------:|----------:|---------:|
| `/json` | **75.9%** | 0.79× | 41,840 | 31,759 |
| `/` | **79.8%** | 0.78× | 87,886 | 70,095 |

## vs v0.15 cut (`2026-07-29-151144`, bebedae)

| | Boehm `/json` | gcry `/json` | % |
|--|-------------:|-------------:|--:|
| v0.15 | 38,398 | 33,154 | **86.3%** |
| best today | 40,597 | 32,643 | **80.4%** |

gcry absolute ≈ v0.15; Boehm ~6–9% hotter on this host → % score drops.
Same-host vs bebedae binary earlier was ~97–98% relative.

## Verdict

**NO-GO for 0.16 PERF/tag.** Need either:

1. Quieter / comparable Boehm band (~36–39k `/json`), or
2. Close remaining absolute gap if Boehm ~40k is the new normal on this machine.

RSS is fine (~0.78–0.79×). Do not update `docs/PERF.md` from these cuts.
