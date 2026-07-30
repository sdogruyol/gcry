# Parallel + TLAB thr A/B

Date: 2026-07-29 · host: WSL2 i3-12100F · Crystal 1.21.0

## Method

- Kemal `bench/kemal`, `wrk -c 100 -d 30`, median-of-3 (`bench/run_all.sh kemal`).
- Parallelism: `EC_PARALLELISM=N` → `Fiber::ExecutionContext.default.resize(N)` in `server.cr` (not `CRYSTAL_WORKERS`).
- TLAB: `GCRY_FLAGS=GCRY_TLAB=1`.

## Same-day baseline (EC capacity 1, TLAB off)

Session: `bench/log/linux/2026-07-29-200917/`

| Path | % of Boehm | RSS × |
|------|----------:|------:|
| `/` | **87.7%** | **0.78×** |
| `/json` | **83.1%** | **0.79×** |

## HTTP crash matrix (pre-fix)

Short smoke (`wrk -c 100 -d 10 /json`):

| Config | Alive? | Notes |
|--------|:------:|-------|
| baseline | yes | ~37k req/s |
| `GCRY_TLAB=1` only | **no** | SEGV in `tlab_alloc_small` / `BlockHeader.free?` |
| `EC_PARALLELISM=4` only | **no** | `realloc(): invalid pointer` (libc abort) |
| EC=4 + TLAB | **no** | JSON builder corruption → SEGV |

`GCRY_KEEP_CHUNKS=1` + TLAB survived → empty-chunk munmap of unmarked TLAB freelist tails.

## TLAB@EC1 fix

FREE-claim now marks the `next_free` chain (tails stay FREE; sweep treats FREE+marked as live for empty-chunk retention). `tlab_alloc_small` abandons heads that fail `find_block`.

Verify: 5× `wrk -c 100 -d 30 /json` with `GCRY_TLAB=1` → **0/5** crashes (~23–27k req/s). `stw_mt --tlab` / `--tlab --nursery` + `nursery_tlab_smoke` OK.

## Still open

| Config | Status |
|--------|--------|
| `EC_PARALLELISM>1` (TLAB off) | still aborts (`realloc(): invalid pointer`) |
| EC>1 + TLAB thr vs Boehm | blocked on EC>1 stability |

Do not default-on Parallel / TLAB until EC>1 is HTTP-stable and thr is re-cut.
