# EC1 production-readiness re-cut (tip after Parallel productize)

Parent: Parallel TLAB-off lazy supported opt-in (`f18d461`). Darwin not
re-cut (this host is WSL2 Linux).

## Gates

| Gate | Result |
|------|--------|
| `crystal spec --release` | green after WSL mprotect pending |
| `perf_smoke` `BENCH_RUNS=5` `MIN_PCT=70` | **PASS** `/json` **84.0%** (alone; contested run failed) |
| acikturkiye `/api/v1/` med-of-3 | thr **89.8%** · RSS **3.43×** → `thr-acik` |
| Kemal quiet med-of-3 | `/json` **83.1%** @ **0.81×** → `thr-kemal` |

## Notes

- **Thr hold** on fat-app (~90% vs v0.15 **90.0%**). **RSS worse** than v0.15
  **2.54×** (now **3.43×**) — dense conservative-live; not a Kemal-class
  reclaim win. Documented in `docs/ACIKTURKIYE.md`.
- Kemal `/json` **83.1%** is host-soft vs v0.16 PERF headline **~87%**
  (Boehm louder ~39k; gcry abs ~33k still in band). **Do not** replace
  PERF headline with this smoke.
- Darwin Kemal / acik: re-cut later same day → `bench/log/macos/2026-08-02-085522/`.
