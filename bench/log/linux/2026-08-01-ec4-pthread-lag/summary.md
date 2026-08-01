# EC4 Parallel pthread LAG (SP on fiber)

Tip after STW dedupe + fiber LAG 256. TLAB off.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever

When suspend SP sits on a pool fiber, `scan_pthread_stack` used to walk the
**full** OS pthread mapping (~8 MiB × N) for leftover scheduler frames —
dominant `phase_stacks` after fiber-scan dedupe.

**Ship:** scan only the top **256 KiB** from stack high under
`multi_mutator_threads?`. `GCRY_STW_PTHREAD_LAG` overrides; `0` = full map.
EC1 unchanged (SP-on-pthread still SP-clamped; no multi LAG path).

## Soft soak (`wrk -c100 -d8` `/json` ×40)

| Config | OK | soft | hard | OK thr med |
|--------|---:|-----:|-----:|-----------:|
| pthread LAG 256 (default) | **40/40** | **0** | **0** | **~62.8k** |

## Quiet thr (`wrk -c100 -d30` med-of-3, same-host Boehm)

Session `2026-08-01-093853/`:

| Path | % Boehm | gcry med | Boehm med | RSS × |
|------|--------:|---------:|----------:|------:|
| `/json` | **73.4%** | 65,067 | 88,588 | **5.47×** |
| `/` | **111.0%** | 109,442 | 98,636 | **6.24×** |

vs prior same-host cut (`2026-08-01-092050/`): `/json` **71.5%** @ ~47k →
**73.4%** @ ~65k. Campaign ≥75% still open (stretch ~80%).

## Phase timings (last-collect med, `/json`)

| Phase | Post-dedupe (`092050`) | + pthread LAG |
|-------|-----------------------:|--------------:|
| stacks | ~7.0 ms | **~0.38 ms** |
| roots | ~1.9 ms | ~1.9 ms |
| pause p50 | ~34 ms | **~24 ms** |

## Gates

- `stw_mt_property_test --workers=2,4` **PASS**

## Verdict

**Ship** pthread LAG 256 default. Soft green; stacks phase collapsed; abs thr
up. EC>1 still experimental; no `PERF.md` fold-in. Next residual: sweep /
mark, or RSS reclaim.
