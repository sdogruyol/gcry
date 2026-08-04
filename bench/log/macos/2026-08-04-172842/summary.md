# Darwin Kemal tip re-cut (stack-maps)

Host: Apple M2 Pro, Crystal 1.21.0, tip `fda578a` (stack-maps), scrub on,
256 KiB Darwin chunks, `wrk -c 100 -d 30`, median-of-3.
`FORCE_REBUILD=1 bash bench/run_all.sh kemal`.

## Gates

| Gate | Result |
|------|--------|
| Kemal `/json` med-of-3 | **84.0%** @ **1.01×** → hold vs v0.17 **83.6%** @ **0.93×** |
| Kemal `/` med-of-3 | **90.7%** @ **0.95×** → hold/soft-up vs v0.17 **89.6%** @ **0.97×** |
| Crashes | **0** |

## vs v0.17 Darwin cut (`2026-08-02-085522/`)

| Workload | v0.17 | tip | Δ |
|----------|------:|----:|--:|
| Kemal `/json` thr | 83.6% | **84.0%** | +0.4pp |
| Kemal `/json` RSS × | 0.93× | **1.01×** | +0.08× (noise; still ~1×) |
| Kemal `/` thr | 89.6% | **90.7%** | +1.1pp |
| Kemal `/` RSS × | 0.97× | **0.95×** | flat |

## Notes

- **`/json` remains the gate** — holds on tip. RSS still Boehm-class.
- Fat-app Darwin tip base (~90% @ 0.63×) is separate:
  `…/2026-08-04-acik-stackmap/` / [ACIKTURKIYE-macos.md](../../../docs/ACIKTURKIYE-macos.md).
- Do not merge into Linux [PERF.md](../../../docs/PERF.md).

## Artifacts

- `run-01/kemal-summary.md`, `kemal-median.tsv`, `kemal-gcry-gcstats-*.json`
- `run-01/metadata.yaml`
