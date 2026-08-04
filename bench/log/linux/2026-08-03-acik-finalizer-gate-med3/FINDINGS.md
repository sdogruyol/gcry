# Post-finalizer acik gate (Boehm × tip+EC gcry)

**Date:** 2026-08-03 · **Host:** WSL2 Ryzen 9 9950X · **Method:** med-of-3,
`wrk -c100 -d30`, `/api/v1/`, dual `/gc-collect` then process RSS.
**Variants:** `boehm` (system Crystal) vs `base` (tip + EC + `-Dgc_none` gcry,
no `PRECISE_STACK`). Harness: `bench/acik_stackmap_ab.sh` (`ACIK_BIN_DIR=.tmp`).

## Result

| variant | thr med | RSS KiB med | × Boehm | non2xx |
|---------|--------:|------------:|--------:|-------:|
| boehm | 137.9 | 55916 | 1.00× | 0 |
| **base (gcry)** | **126.2 (91.5%)** | **101064** | **1.81×** | 0 |

Trials (RSS KiB): boehm 44840 / 55916 / 56276 · base 101212 / 60712 / 101064.

## Context

| Session | RSS × Boehm | Note |
|---------|------------:|------|
| tip-baseline2-med3 (pre-fix, same host) | ~8.5× | finalizer Array leak |
| v0.17 Linux cut (i3, older tree) | ~3.43× | different host/demo |
| **this (post `3a0bffe`)** | **~1.81×** | LibC registry + resurrect |

Thr stays in the ~90% band. Heap live-attr after wrk was ~16 MiB; process RSS
here still includes mapped empty/warm chunks + binary — gate metric is RSS ×.

## Do not claim

- exclusivef / stack-maps closed the gap (this cut is `base`, maps off)
- i3 3.43× superseded without an i3 re-run
