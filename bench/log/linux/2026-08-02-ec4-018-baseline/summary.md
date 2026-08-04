# EC4 Parallel lazy baseline (Phase 0) — reclaim-off

Tip before Parallel dormant default-on. Session:
`bench/log/linux/2026-08-02-145600/` · `EC_PARALLELISM=4` · TLAB off · lazy on ·
empty reclaim **off** (v0.17 shape).

| Path | % Boehm | gcry (med) | RSS × |
|------|--------:|-----------:|------:|
| `/json` | **80.5%** | 50,874 | **5.48×** |
| `/` | **92.3%** | 84,724 | **6.21×** |

Holds v0.17 lazy opt-in band (~78–81%). Secondary gate target: **≥75% @ ≤4×**.
