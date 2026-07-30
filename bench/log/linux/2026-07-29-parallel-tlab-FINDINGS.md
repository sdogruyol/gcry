# Parallel + TLAB thr A/B

Date: 2026-07-29/30 · host: WSL2 i3-12100F · Crystal 1.21.0

## Method

- Kemal `bench/kemal`, `wrk -c 100 -d 30` (or shorter smokes).
- Parallelism: `EC_PARALLELISM=N` → `Fiber::ExecutionContext.default.resize(N)`.
- Allocator micro: `bench/ec_alloc_stress.cr` (`EC=4`, optional `GCRY_TLAB=1`).

## Baseline (EC capacity 1, TLAB off)

Session `2026-07-29-200917/`: `/json` **83.1%** Boehm, `/` **87.7%**.

## TLAB@EC1 (fixed)

FREE-claim marks `next_free` tails; 5×30s `/json` with `GCRY_TLAB=1` OK. Still green after Parallel index-lock work.

## EC>1 status (open)

Kemal `EC_PARALLELISM=2/4` still dies under `/json` (`not a gcry allocation` / SEGV / `realloc(): invalid pointer`).

### Landed while investigating

| Fix | Why |
|-----|-----|
| `@index_lock` around chunk index + mutator `chunk_containing` | Parallel raced `index_insert` vs lookups / last-chunk cache |
| `with_alloc_lock` always locks | Was a no-op when TLAB off (large/chunk/counters) |
| `ensure_tlabs` under `@alloc_lock` (+ non-recursive under_lock boot) | Parallel TLAB table init race |
| Full fiber stack scan for other STW threads | SP/greg alone insufficient under Parallel |

### Still failing

| Config | Note |
|--------|------|
| Kemal EC>1 (TLAB off) | Still crashes under wrk |
| `ec_alloc_stress` + `GCRY_TLAB=1` + EC=4, no auto-GC | Intermittent **double free** / `not a gcry allocation` on realloc — lock-free TLAB claim still races under Parallel |
| `ec_alloc_stress` EC=4, TLAB off, no auto-GC | OK |

Next: make TLAB freelist head claim atomic (or serialize) under Parallel; re-bisect Kemal EC>1 without TLAB once alloc stress is green with GC on.
