# Parallel + TLAB thr A/B

Date: 2026-07-29/30 · host: WSL2 i3-12100F · Crystal 1.21.0

## Method

- Kemal `bench/kemal`, `wrk -c 100 -d 10..30`.
- Parallelism: `EC_PARALLELISM=N` → `Fiber::ExecutionContext.default.resize(N)`.
- Allocator micro: `bench/ec_alloc_stress.cr`.

## Baseline (EC1, TLAB off)

Session `2026-07-29-200917/`: `/json` **83.1%** Boehm, `/` **87.7%**.

## Status summary

| Path | Status |
|------|--------|
| EC1, TLAB off | Supported |
| TLAB@EC1 | Fixed (FREE-claim tails) |
| TLAB@Parallel alloc (no auto-GC) | Solid (per-slot locks) |
| TLAB@Parallel + GC | Mostly OK (~1/12 stress fail) |
| **Kemal EC>1 + collect** | **Still open** (~3/20 on 10s `/json`) |
| Boehm EC4 | **0/8** — Parallel HTTP fine under Boehm |

## EC>1 evidence

`GCRY_DISABLE_AUTO=1` → 0 fail (GC-triggered). KEEP_CHUNKS / type_id / interior do not close flakes.

Hot crash: `Heap#realloc` ← `String::Builder#resize` ← `/json` (double-free / not a gcry / SEGV).

### Latest after realloc suppress + Boehm-like scan (this session)

| Test | Result |
|------|--------|
| EC4 default, 20×10s wrk | **3/20 fail** (was ~5/20) |
| EC4 single process 6×15s | **LONG_OK** |
| EC4 + `GCRY_DISABLE_SCRUB_FIBERS` | still flakes (scrub not the sole cause) |
| EC1 regression | OK |

### Landed

| Fix | Note |
|-----|------|
| `@index_lock`, always `with_alloc_lock` | Chunk index races |
| TLAB per-slot locks | Dual-alloc |
| STW `Thread.lock` | Match Crystal `gc/none` |
| Running-fiber STW scan | TLS nil / skipped running |
| **`@suppress_collect` in growing realloc** | Pin window: no collect mid-copy |
| **Always scan fiber stack** (drop `name=="main"` early-out) | Every Thread main fiber is named `"main"` |
| **`String::Builder` layout** | `@buffer` noscan |

### Next

1. Remaining EC>1 SEGV under collect (not only realloc) — mark miss of live HTTP objects.
2. Compare Boehm suspend-time stack walk vs gcry `safe:` holes / scrub interaction under Parallel.
3. Stability gate then thr A/B → 0.16.0.
