# Kemal median-of-3 — 0.16 candidate (Boehm ~40k fair baseline)

Session: `2026-08-01-085210` · git `95c63f0` · Crystal 1.21.0 · WSL2
Boehm `/json` ~40k treated as fair same-host baseline (not dismissed as host noise).

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | Boehm RSS (KiB) | gcry RSS (KiB) | RSS × |
|------|------------------:|-----------------:|-------:|----------------:|---------------:|------:|
| `/json` | 40,895 | 33,797 | **82.6%** | 16,768 | 13,028 | **0.78×** |
| `/` | 91,565 | 70,380 | **76.9%** | 16,648 | 13,048 | **0.78×** |

soft=0
**Verdict: NO-GO** — `/json` **82.6%** (gate ~86% of fair Boehm ~40k).

