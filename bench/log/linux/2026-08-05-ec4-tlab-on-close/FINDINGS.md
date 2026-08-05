# Phase C.4 — Accept Parallel TLAB-on thr residual

**Date:** 2026-08-05 · Host: WSL2 R9-9950X · Crystal 1.21.0  
**Branch:** `plan/parallel-tlab-on`  
**Plan:** [docs/PARALLEL_TLAB_ON.md](../../../../docs/PARALLEL_TLAB_ON.md)

## Decision

**Accept** the Parallel TLAB-on throughput gap vs TLAB-off. No further thr
lever this epic. Status stays **unsupported** (stderr warn); Phase **D**
promote deferred (needs multi-host soak + POLICY reword — separate PR).

## Research recipe (9950X tip)

```bash
EC_PARALLELISM=4 GCRY_TLAB=1 \
  GCRY_PARALLEL_DORMANT=1 GCRY_EMPTY_CHUNK_RETAIN=33554432 \
  GCRY_TLAB_SKIP_FIND_BLOCK=1
```

| Knob | Role |
|------|------|
| `GCRY_TLAB=1` | TLAB-on (unsupported) |
| `PARALLEL_DORMANT` + retain 32 MiB | RSS ~126× → ~3.5× (B′) |
| `TLAB_SKIP_FIND_BLOCK=1` | hit-path thr (~+20% vs B1 alone) (C.3) |

**Do not** use `GCRY_PARALLEL_RELEASE`. Skip-find is a munmap UAF footgun
outside reclaim-off / dormant.

## Tip numbers (same host, Kemal `/json`)

| Config | gcry abs | RSS × | Soak |
|--------|---------:|------:|------|
| TLAB-**off** Parallel (A4) | ~**108k** | ~**6×** | 40/40 |
| TLAB-on alone | ~48k | ~**126×** | 40/40 |
| TLAB-on + dormant32 (B′) | ~**58k** | ~**3.5×** | 20/20 |
| TLAB-on + dormant32 + skip (C.3 med3) | ~**63k** | ~(same band) | 20/20 |

Residual: recipe thr ≈ **⅗** of TLAB-off abs (~63k / ~108k). Soft errors
green; thr not a product win over supported TLAB-off.

## Epic ledger

| Phase | Verdict | Hub |
|-------|---------|-----|
| A | PASS baseline; RSS cliff on TLAB-on | `…-ec4-tlab-on-baseline/` |
| B′ | RSS closed by dormant32 | `…-ec4-tlab-rss-bp/` |
| C.1 | hit path: lock wait ≫ find_block | `…-ec4-tlab-hit-attr/` |
| C.2 | pad slot locks | **REJECT** `…-ec4-tlab-slot-pad/` |
| C.3 | skip find_block | **KEEP** opt-in `…-ec4-tlab-skip-find/` |
| **C.4** | **accept thr gap; document** | this file |

## Out of scope / next epic

- Promote to correctness-supported opt-in (Phase D checklist)
- Auto-enable bounded dormant when `TLAB∧EC>1`
- Hold-path micro-opts chasing the last ~⅖ vs TLAB-off
- Product default changes
