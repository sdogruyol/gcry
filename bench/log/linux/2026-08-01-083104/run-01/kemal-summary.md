# Kemal median-of-3 (quiet cut attempt 1)

Session: `2026-08-01-083104` · git `95c63f0` · Crystal 1.21.0 · WSL2
Load start: see uptime-start.txt (LA ~0.78); end LA ~2.0 (host warmed mid-cut).

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | Boehm RSS (KiB) | gcry RSS (KiB) | RSS × |
|------|------------------:|-----------------:|-------:|----------------:|---------------:|------:|
| `/` | 90,582 | 75,908 | **83.8%** | 16,652 | 13,028 | **0.78×** |
| `/json` | 40,597 | 32,643 | **80.4%** | 16,680 | 13,156 | **0.79×** |

**Verdict: NO-GO** — `/json` 80.4% (need ~86% band). Boehm med 40597 (v0.15 cut had ~38.4k). soft=0.

