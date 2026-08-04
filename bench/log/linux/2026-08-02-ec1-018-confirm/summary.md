# EC1 0.18 confirm cut

Session: `bench/log/linux/2026-08-02-152806/` · tip after lever reverts.

| Path | % Boehm | RSS × |
|------|--------:|------:|
| `/json` | **85.4%** | **0.76×** |
| `/` | **82.3%** | **0.83×** |

Soft vs Phase 0 baseline **87.9%** @ **0.81×** (`120500/`) — host noise;
RSS better. PERF 0.18 headline prefers the Phase 0 quiet hold band.
