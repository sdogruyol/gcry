# EC4 lazy (post-STW) sweep — stretch thr

Tip after mark-gen **76.6%** `/json`. Residual: `phase_sweep` ~6–12 ms
inside STW walking mostly-empty reclaim-off heap.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever

End STW after mark; reclaim under per-size-class freelist locks while
mutators run. Pause no longer includes O(heap) sweep. Gates
(`sweep_after_world?`):

- `lazy_sweep` (default on; `GCRY_DISABLE_LAZY_SWEEP=1` escapes)
- multi-mutator (Parallel)
- TLAB **off** (TLAB hits skip freelist lock → clear_mark race)
- empty-chunk reclaim off (no `@chunks` relink / munmap)
- `madvise_free_pages` off (no HOLED freelist rebuild)

EC1 and Parallel+reclaim/TLAB keep in-STW sweep.

## Soft soak (`wrk -c100 -d8` `/json` ×40)

| OK | soft | hard | OK thr med |
|---:|-----:|-----:|-----------:|
| **40/40** | **0** | **0** | **~68.4k** |

pause_p50 last-collect ~**8.3 ms** (was ~20 ms); `phase_sweep` still
~10–17 ms but **outside** recorded STW pause.

## Quiet thr (`wrk -c100 -d30` med-of-3, same-host Boehm)

Session `bench/log/linux/2026-08-01-123846/`:

| Path | % Boehm | gcry med | Boehm med | RSS × |
|------|--------:|---------:|----------:|------:|
| `/json` | **78.8%** | 69,237 | 87,857 | **5.81×** |
| `/` | **114.2%** | 117,521 | 102,896 | **6.24×** |

vs mark-gen (`100405`): `/json` **76.6%** @ ~67k → **78.8%** @ ~69k.
**Hold ≥76.6% cleared; stretch ~80% nearly met.**

## Phase timings (last-collect med, `/json`)

| Phase | mark-gen | + lazy sweep |
|-------|---------:|-------------:|
| clear | ~55 ns | ~38 ns |
| sweep | ~6.8 ms | ~7.6 ms *(post-STW)* |
| roots | — | ~2.1 ms |
| stacks | ~0.39 ms | ~0.38 ms |
| pause p50 | ~20 ms | **~8.5 ms** |

## EC1 smoke

Session `2026-08-01-124520/`: `/json` ~**34.7k** (no regress vs mark-gen
~33.6k). Lazy path inactive on EC1.

## Gates

- `stw_mt_property_test --workers=2,4` **PASS**
- Soft **0/40**

## Verdict

**Ship** lazy sweep for Parallel reclaim-off / TLAB-off. Campaign thr bar
moves to **~78.8%**; soft green; pause cut ~2×. Stretch **~80%** still
slightly open; residual is concurrent sweep freelist contention + RSS.
Experimental EC>1; no `PERF.md` fold-in.
