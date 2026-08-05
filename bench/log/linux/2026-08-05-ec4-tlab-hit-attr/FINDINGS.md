# Phase C.1 — TLAB hit-path attribution (EC4 `/json`)

**Date:** 2026-08-05 · Host: WSL2 R9-9950X · Crystal 1.21.0  
**Branch:** `plan/parallel-tlab-on`  
**Plan:** [docs/PARALLEL_TLAB_ON.md](../../../../docs/PARALLEL_TLAB_ON.md)

## Method

`perf` unavailable on this WSL kernel. Added research knob
`GCRY_TLAB_HIT_ATTR=1`: `CLOCK_MONOTONIC` ns around per-hit **slot-lock wait**,
**slot-lock hold**, **`find_block`**, and **refill**. Exposed on `/gc-stats`.

- Binary: `/tmp/kemal-gcry-attr` (`-Dgc_none --release`, path shard tip)
- Load: `wrk -c100 -d20 -t4 /json` after 5s warm; `EC_PARALLELISM=4`
- Attr **slows** the path — use **composition %**, not abs thr vs B′ quiet

## Results

### B1 recipe + attr (`b1-dormant32-attr/`)

`GCRY_TLAB=1 GCRY_PARALLEL_DORMANT=1 GCRY_EMPTY_CHUNK_RETAIN=33554432 GCRY_TLAB_HIT_ATTR=1`

| Metric | Value |
|--------|------:|
| wrk `/json` | **47 102** req/s |
| tlab hit rate | **98%** |
| attr samples | 91.2M |
| **lock wait** avg | **193 ns/hit** · **57.8%** of (wait+hold) |
| **lock hold** avg | **141 ns/hit** · **42.2%** of (wait+hold) |
| **`find_block`** avg | **63.5 ns/call** · **45.0%** of hold · **19.0%** of (wait+hold) |
| refill | 999k calls · avg **1.9 µs** (miss path; not hit-dominated) |
| heap | small_mapped ~124 MiB · dormant ~64 MiB |

### Same recipe, attr off (`b1-dormant32-noattr/`)

| Metric | Value |
|--------|------:|
| wrk `/json` | **55 447** req/s |
| hit rate | 98% |

Attr tax on this cut ≈ **15%** thr (55k → 47k) — expected (4× `clock_gettime` per hit).

### TLAB-on alone + attr (`tlab-on-alone-attr/`)

| Metric | Value |
|--------|------:|
| wrk `/json` | **41 011** req/s |
| lock wait | **58.0%** of crit · 198 ns/hit |
| lock hold | **42.0%** · 144 ns/hit |
| `find_block` | **47.1%** of hold · **19.8%** of crit · 67.8 ns/call |
| heap | small_mapped ~1.5 GiB · dormant 0 |

Composition matches B1; RSS cliff does **not** change hit-path shape.
(`find_block` only ~4 ns slower with ~15k chunks vs ~1k — index size not the
main tax.)

First B1+attr attempt SIGSEGV’d mid-wrk (`Invalid memory access @ 0x50`);
retry green. Treat as soft flake under attr slowdown; soak gates stay on
non-attr recipe.

## Verdict

1. **Hit path is lock-dominated, not `find_block`-dominated.** Under EC4
   `/json`, ~**58%** of timed critical time is **slot-lock wait**, ~**42%**
   hold; `find_block` is ~**half of hold** (~**19%** of wait+hold).
2. **Refill is rare** (hit rate 98%); avg refill ~2 µs but not the thr gap vs
   TLAB-off.
3. **~193 ns wait/hit** on a *per-thread* slot is suspicious for true sharing —
   hypothesis for C.2: **false sharing** on adjacent `@tlab_slot_locks` in the
   `StaticArray`, or residual cross-thread free/refill on the same slot.
   Re-validate before padding locks.
4. Prior FINDINGS (“every hit does `find_block` + slot lock”) still true;
   **ordering of cost on tip 9950X:** wait ≫ hold ≃ 2× `find_block`.

## Next (Phase C.2 candidates — one lever)

| Lever | Rationale | Reject if |
|-------|-----------|-----------|
| Cache-line pad `@tlab_slot_locks` | cuts false-sharing wait | TLAB-off regresses / no wait drop |
| Epoch-gated skip of `find_block` on hot head | recovers ~19% crit | SEGV / soft soak |
| Shrink hold (move counters / mark out) | hold already 42%; smaller win | correctness |

Do **not** promote `GCRY_TLAB_HIT_ATTR` — research only.
