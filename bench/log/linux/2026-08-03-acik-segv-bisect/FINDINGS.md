# Bisect: acik `/gc-collect` SEGV (verify med3 t1)

**Date:** 2026-08-03 · tip+EC `acikturkiye-base` @ retain=0 defaults (`9228bb9`)

## Original (one shot)

`…/acik-defaults-verify-med3/` base t1: wrk -c100 -d30 OK → dual `/gc-collect`
both **200** → SEGV in EC **Monitor** (`pthread` `run_loop` / `monitor.cr`),
not in `Socket#finalize` / mutator. Address looked like heap UAF; stack too
thin for a precise site.

## Repro matrix (same bin, no SEGV)

| Config | Load | Iters | SEGV |
|--------|------|------:|-----:|
| default0 (retain=0) | c50 d8 + dual collect | 8 | 0 |
| oldcache 16+4 MiB | c50 d8 | 8 | 0 |
| empty0 + large 4 MiB | c50 d8 | 6 | 0 |
| large0 + empty 16 MiB | c50 d8 | 6 | 0 |
| default0 | c100 d30 + dual collect | 6 | 0 |
| default0 | c100 d25 + collect during wrk | 1 | 0 |
| default0 | c100 d15 + overlapping dual collect | 10 | 0 |

**Total: 0 / 45** under default0-heavy paths.

## Verdict

- **Not bisectable** to a commit: single unreproduced event; A/B retain knobs
  never crashed; git range `059d1bd..9228bb9` is one product-policy commit.
- **Not confirmed** as retain=0 regression (env release0 med3 also clean).
- Likely rare race (Monitor vs post-STW munmap / connection teardown); leave
  as watch item. If it returns: rebuild `--debug --error-trace`, capture full
  backtrace + `GCRY_TRACE=1`.

## Do not

- Revert Linux retain=0 defaults on this evidence alone
- Claim exclusivef / finalizer resurrect as the SEGV site (stack was Monitor)
