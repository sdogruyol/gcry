# EC1 hot-prefer dormant demotion — REJECT

Session: `bench/log/linux/2026-08-02-150536/`

| Path | % Boehm | gcry abs | RSS × |
|------|--------:|---------:|------:|
| `/json` | **84.5%** | 34,013 | **0.81×** |

vs Phase 0 baseline **87.9%** / 33,838 abs @ **0.81×**: no thr win (abs flat;
% soft from louder Boehm). Demote-from-kept adds sweep complexity. **Code
reverted**; Parallel dormant default-on kept separately.
