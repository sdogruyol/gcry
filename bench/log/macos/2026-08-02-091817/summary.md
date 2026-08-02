# Darwin confirm re-cut (tip / 0.17.0 pending)

Same-day confirm after `2026-08-02-085522/`. Host quiet (prior CPU
contender gone). `18513e0`, Crystal 1.21.0, scrub on, 256 KiB Darwin chunks.

## Gates

| Gate | Result | vs first cut |
|------|--------|--------------|
| Kemal `/json` | **83.2%** @ **0.99×** | hold (was 83.6% / 0.93×) |
| Kemal `/` | **89.5%** @ **1.07×** | hold (was 89.6% / 0.97×) |
| acik `/api/v1/` | **89.4%** @ **16.7×** | **host-soft Boehm** — see notes |
| Crashes | **0** | |

## Notes

- **Kemal confirmed.** Absolute band matches first cut (gcry `/json` ~52.5k
  both; Boehm ~63k). Headline stays **~84%** `/json`, **~90%** `/`, RSS
  **~0.93–1.07×**.
- **acik % inflated by soft Boehm.** Trial Boehm 654 / 729 / 849 (noisy);
  first cut was loud+stable ~955. gcry abs ~566–679 (first cut ~674–680).
  Prefer first-cut **~71%** @ **~18×** as the fair same-host ratio; this
  session only confirms abs thr band + RSS ~16–19× and 0 crashes.

## Artifacts

- `run-01/` — kemal + acik summaries, medians, gcstats, metadata
