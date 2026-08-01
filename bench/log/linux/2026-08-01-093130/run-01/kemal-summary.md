# Kemal median-of-3 — EC1 4KiB scrub + non-atomic counters

Session: `2026-08-01-093130` · Crystal 1.21.0 · Boehm ~40k fair

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | Boehm RSS (KiB) | gcry RSS (KiB) | RSS × |
|------|------------------:|-----------------:|-------:|----------------:|---------------:|------:|
| `/json` | 35,780 | 31,067 | **86.8%** | 16,628 | 13,340 | **0.80×** |
| `/` | 84,745 | 65,668 | **77.5%** | 16,632 | 13,264 | **0.80×** |

soft=0
**Verdict: GO** — `/json` **86.8%**.

