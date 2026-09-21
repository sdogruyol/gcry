# `make trace-smoke` traces with sampling off and must fail

**Date:** 2026-09-21 · host: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0
Tree `788245a` + the gates before this · `python3 bench/gate_arm_census.py`

`bench/trace_smoke.cr` enables `Gcry::Trace` on a file at `alloc_sample: 1`,
allocates, frees, collects, registers a finalizer, and requires alloc, free,
`collect_start`, `collect_end` and `finalizer` events in the NDJSON, plus a
heap dump whose line count and addresses agree with the live set. Every
check is a `raise`. Nothing showed any of them reachable.

## What changed

`--unsampled` enables the trace with `alloc_sample: 0`. `docs/HARDENING.md`
says `0` is off, and `Trace.alloc` / `Trace.free` return before emitting at
0, so the file carries collect and finalizer events and no alloc or free —
and the first event assertion has to raise. The recipe requires that arm to
exit non-zero; the CI step ran the binary directly and now runs the recipe.

## Measured

| arm | events | verdict |
|---|---|---|
| shipped | 23, dump 5 | ok |
| `--unsampled` | — | `no alloc events (expected: --unsampled)`, exit 1 — required |

A `--unsampled` run that reaches "ok" prints that `alloc_sample 0` is no
longer off, which is the other way this arm would stop meaning anything.

## Census

```
harness-driven gates:              100
red direction constructed per run: 75
red direction established by hand: 25
```

**100 / 74 / 26 → 100 / 75 / 25.** Recipe 1 (`!`). Left owed an arm:
`finalizer-complex`, `oom-test`(+short), `thread-storm`(+short), `soak`,
`soak-smoke`, `compiler-gc-contract`.
