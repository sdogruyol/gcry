# Parallel + TLAB thr A/B

Date: 2026-07-29/30 · host: WSL2 i3-12100F · Crystal 1.21.0

## Method

- Kemal `bench/kemal`, `wrk -c 100 -d 10..30` (smokes + baseline).
- Parallelism: `EC_PARALLELISM=N` → `Fiber::ExecutionContext.default.resize(N)`.
- Allocator micro: `bench/ec_alloc_stress.cr` (`EC=4`, optional `GCRY_TLAB=1`, optional `GCRY_THRESHOLD`).

## Baseline (EC capacity 1, TLAB off)

Session `2026-07-29-200917/`: `/json` **83.1%** Boehm, `/` **87.7%**.

## TLAB@EC1 (fixed)

FREE-claim marks `next_free` tails; Kemal `GCRY_TLAB=1` @ EC1 OK.

## TLAB@Parallel allocator (mostly fixed)

Per-TLAB-slot `Crystal::SpinLock` around freelist claim / free / refill install.

| Mode | Result |
|------|--------|
| no auto-GC | **25/25 OK** |
| `GCRY_THRESHOLD=65536` | **22/25 OK** (remaining collect-time flakes) |

## EC>1 Kemal HTTP (still open)

Boehm control: `EC_PARALLELISM=4` Kemal `/json` **0/8 fail** — Parallel HTTP is fine under Boehm; gcry-specific.

Gcry symptoms under `/json`:

- `pointer is not a gcry allocation` (String::Builder `realloc`)
- `realloc(): invalid pointer` / `double free` in `Heap#realloc`
- SEGV (sometimes ASCII-looking addrs e.g. `0x6e6f736a` == `"json"`)

### Knob matrix (EC4, 8–10× ~10s wrk)

| Config | Result |
|--------|--------|
| default | flakes (~1/10–5/20) |
| `GCRY_KEEP_CHUNKS=1` | still flakes (not only empty-chunk munmap) |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | still flakes |
| `GCRY_INTERIOR=1` | still flakes |
| `GCRY_DISABLE_AUTO=1` | **0/8 fail** — GC-triggered |
| `GCRY_DISABLE_NURSERY=1` | still flakes |
| Boehm EC4 | **0/8 fail** |

So: premature reclaim / UAF under collect (freelist reuse or munmap), not fixed by interior/type_id/keep-chunks alone.

### Landed while investigating

| Fix | Why |
|-----|-----|
| `@index_lock` + always `with_alloc_lock` | Parallel chunk-index / counter races |
| TLAB per-slot locks | Parallel dual-alloc on freelist head |
| STW: scan running fibers; nil `current_fiber` → pthread stack | Mark miss when TLS briefly nil |
| **STW holds `Thread.lock`** (match Crystal `gc/none`) | Parallel EC lazy `threads.push` + alloc mid-mark/sweep |
| Full fiber stack + greg on other STW threads | Prior SP-only miss |

Post-`Thread.lock`: Kemal EC4 still **~5/20** fail on 10s `/json` wrk — necessary, not sufficient.

### Next

1. Diff Boehm’s per-thread `set_stackbottom(fiber.@stack.bottom)` path vs gcry fiber/thread scan under Parallel migration.
2. Harden `realloc` pin (explicit root should keep the buffer; still seeing double-free → mark miss of pinned / owner).
3. Only then thr A/B → 0.16.0 cut.

Supported product path remains EC parallelism **1**, `GCRY_TLAB` **off**.
