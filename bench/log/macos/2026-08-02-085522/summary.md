# Darwin re-cut (tip / 0.17.0 pending)

First macOS A/B since v0.13 (`2026-07-27-181415/`). Host: Apple M2 Pro,
Crystal 1.21.0, `18513e0` (`v0.16.0-19`), scrub on, 256 KiB Darwin chunks,
`wrk -c 100 -d 30`, median-of-3.

## Gates

| Gate | Result |
|------|--------|
| Kemal `/json` med-of-3 | **83.6%** @ **0.93×** → hold vs v0.13 **83.9%** |
| Kemal `/` med-of-3 | **89.6%** @ **0.97×** → soft vs v0.13 **92.6%** (−3pp) |
| acikturkiye `/api/v1/` med-of-3 | **70.7%** thr @ **18.4×** RSS → softer than v0.13 **~78%** / **~16×** |
| Crashes | **0** |

## vs v0.13 Darwin cut

| Workload | v0.13 | tip | Δ |
|----------|------:|----:|--:|
| Kemal `/json` thr | 83.9% | **83.6%** | −0.3pp |
| Kemal `/json` RSS × | 0.93× | **0.93×** | flat |
| Kemal `/` thr | 92.6% | **89.6%** | −3.0pp |
| Kemal `/` RSS × | 1.06× | **0.97×** | better |
| acik thr | 77.9% | **70.7%** | −7.2pp |
| acik RSS × | 15.8× | **18.4×** | worse |

## Notes

- **Kemal `/json` is the gate** — holds. Idle `/` soft is host noise (Boehm
  abs ~86–87k both cuts; gcry abs ~78k vs ~81k).
- **Fat-app thr drop** is real: Boehm louder (~955 vs ~921) and gcry abs
  lower (~675 vs ~718). Live set still ~1.1 GiB `size_class_live_bytes`;
  pause p50 ~26 ms; ~497 majors / 30s. Stack maps remain the next win.
- **Confirm:** `2026-08-02-091817/` — Kemal hold (83.2% / 89.5%). acik %
  jumped to 89.4% on soft/noisy Boehm (654–849); gcry abs still ~650–680.
  Keep this session’s **~71%** as the fair fat-app ratio.
- Docs updated: `PERF-macos.md`, `ACIKTURKIYE-macos.md`, README macOS table,
  DESIGN / ANNOUNCE / COMPARISON / ROADMAP / CHANGELOG.

## Artifacts

- `run-01/kemal-summary.md`, `kemal-median.tsv`, `kemal-gcry-gcstats-*.json`
- `run-01/acik-summary.md`, `acik-median.tsv`, `acik-gcry-gcstats-*.json`
- `run-01/metadata.yaml`
