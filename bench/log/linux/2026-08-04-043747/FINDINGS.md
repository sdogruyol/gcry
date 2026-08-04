# Kemal KEEP_CHUNKS=1 after retain=0 tip

**Date:** 2026-08-04 · same host/method as `2026-08-04-042404/`  
**Flags:** `GCRY_KEEP_CHUNKS=1` (escape only)

## Result

| Path | % Boehm | RSS × |
|------|--------:|------:|
| `/` | **87.3%** | **3.34×** |
| `/json` | **92.6%** | **3.25×** |

vs prior KEEP on 9950X (`080248/`): **90.1%** @ **3.23×** — same shape
(soft thr hit, RSS fail). Not a default.

Paired default cut: `…/2026-08-04-042404/` → **85.0%** @ **0.78×**.
