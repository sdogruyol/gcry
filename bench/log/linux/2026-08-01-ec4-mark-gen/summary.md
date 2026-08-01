# EC4 in-header mark generation (kill phase_clear)

Tip after pthread LAG. TLAB off.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever

`clear_all_marks` walked every non-FREE block (~3 ms under Parallel
reclaim-off). **Ship:** 8-bit mark generation in `BlockHeader` flags bits
8–15; `clear_all_marks` bumps `@header_mark_gen` (O(1)). Wrap at 255 does a
full gen clear then resets to 1. Synced to `BlockHeader.mark_gen` for
`marked?` / barriers. Side-bitmap path unchanged.

## Soft soak (`wrk -c100 -d8` `/json` ×40)

| OK | soft | hard | OK thr med |
|---:|-----:|-----:|-----------:|
| **40/40** | **0** | **0** | **~67.4k** |

## Quiet thr (`wrk -c100 -d30` med-of-3, same-host Boehm)

Session `2026-08-01-100405/`:

| Path | % Boehm | gcry med | Boehm med | RSS × |
|------|--------:|---------:|----------:|------:|
| `/json` | **76.6%** | 66,629 | 86,981 | **5.80×** |
| `/` | **105.2%** | 104,087 | 98,969 | **5.87×** |

vs pthread-LAG cut (`093853`): `/json` **73.4%** @ ~65k → **76.6%** @ ~67k.
**Campaign bar ≥75% met** (stretch ~80% still open).

## Phase timings (last-collect med, `/json`)

| Phase | pthread LAG | + mark-gen |
|-------|------------:|-----------:|
| clear | ~3.0 ms | **~55 ns** |
| sweep | ~4.3 ms | ~6.8 ms *(host noise)* |
| stacks | ~0.38 ms | ~0.39 ms |
| pause p50 | ~24 ms | **~20 ms** |

## EC1 smoke

Session `2026-08-01-101242/`: `/json` ~**33.6k** (0.16 band; no regress).

## Gates

- `stw_mt_property_test --workers=2,4` **PASS**
- `spec/collect_spec` + `heap_spec` **PASS**

## Verdict

**Ship** mark-gen. Soft green; `phase_clear` eliminated; EC4 `/json` **76.6%**
crosses ≥75%. EC>1 still experimental (RSS ~5.8×); no `PERF.md` fold-in.
Next residual: sweep walk / RSS.
