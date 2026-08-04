# EC1 0.18 baseline (Phase 0)

Tip `c41fd56` (v0.17.0) · Crystal 1.21.0 · WSL2 x86_64 · EC1 · scrub on ·
auto-layouts off · TLAB off.

Session: `bench/log/linux/2026-08-02-120500/` (`run-01`).

## Quiet Kemal (median-of-3, `wrk -c100 -d30`)

| Path | % Boehm | gcry (med) | Boehm (med) | RSS × |
|------|--------:|-----------:|------------:|------:|
| `/json` | **87.9%** | 33,838 | 38,492 | **0.81×** |
| `/` | **85.0%** | 71,467 | 84,070 | **0.83×** |

Holds v0.16 PERF headline (~87% / ~0.80×). Gate for 0.18: **≥95%** `@` **≤1.0×**.
