# Kemal median-of-3 (quiet cut attempt 2)

Session: `2026-08-01-083831` · git `95c63f0` · Crystal 1.21.0 · WSL2
Order: `/json`×3 interleaved, then `/`×3 (gate first while cooler).

| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | Boehm RSS (KiB) | gcry RSS (KiB) | RSS × |
|------|------------------:|-----------------:|-------:|----------------:|---------------:|------:|
| `/json` | 41,840 | 31,759 | **75.9%** | 16,664 | 13,200 | **0.79×** |
| `/` | 87,886 | 70,095 | **79.8%** | 16,672 | 13,044 | **0.78×** |

**Verdict: NO-GO** — `/json` **75.9%** Boehm (target ~86%). Boehm med 41840 (v0.15 ~38.4k). soft=0.

