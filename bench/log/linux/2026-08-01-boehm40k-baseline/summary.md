# Boehm ~40k fair baseline — tip vs gate

git `95c63f0`. Soft=0. Gate = **86% of same-session Boehm** (not the old 38.4k).

## Probe (interleaved bebedae / tip / Boehm)

| bin | `/json` med | % Boehm | vs 86% gate (33.7k) |
|-----|------------:|--------:|--------------------:|
| bebedae | 34,517 | **88.1%** | +812 |
| tip | 34,028 | **86.8%** | +322 |
| Boehm | 39,193 | 100% | — |

tip/bebedae = **98.6%**. tip p50 6.6ms vs bebedae 8.9ms; tip more collects (186 vs 156).

## Formal quiet cut (`2026-08-01-085210`)

| Path | % Boehm | Boehm med | gcry med | RSS × |
|------|--------:|----------:|---------:|------:|
| `/json` | **82.6%** | 40,895 | 33,797 | 0.78× |
| `/` | **76.9%** | 91,565 | 70,380 | 0.78× |

86% of Boehm 40.9k ≈ **35.2k**; tip short ~**1.4k** (~4%).

## Reading

- gcry abs stable ~**33.8–34.0k** across runs.
- Boehm fair band **~39–41k**; % swings **~83–87%** with Boehm variance.
- Relative to v0.15 bebedae: tip ≈ **99%**.

**Formal cut: NO-GO at strict 86%.** Probe was GO on cooler Boehm (~39.2k).
Next: +~1.5k abs thr, or accept ~83% headline under Boehm~41k.
