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

## TLAB@Parallel allocator (fixed in tree)

Per-TLAB-slot `Crystal::SpinLock` around freelist claim / free / refill install.

Pitfalls closed while landing:

| Bug | Symptom | Fix |
|-----|---------|-----|
| `Pointer(Atomic).malloc` under `@alloc_lock` | Boot hang with `GCRY_TLAB=1` (GC.malloc → re-enter SpinLock) | `StaticArray(Crystal::SpinLock, MAX_TLABS)` — no GC alloc in boot |
| `flush_all_tlabs` took slot locks under STW | Livelock when suspended mutator held the slot | Flush unlocked under STW only |
| Refill returned head without re-claim | Dual-alloc / wrong USED state | Always `next` after refill and claim under slot lock |
| Stress harness | Raise without `wg.done` hung WaitGroup | `ensure { wg.done }` |

`ec_alloc_stress` `GCRY_TLAB=1 EC=4`:

| Mode | Result |
|------|--------|
| no auto-GC (`GCRY_DISABLE_AUTO` / thr=MAX) | **25/25 OK** |
| `GCRY_THRESHOLD=65536` | **22/25 OK** (remaining: SEGV / silent abort under collect) |

## EC>1 Kemal HTTP (still open)

Kemal `EC_PARALLELISM=2/4` still flakes under `/json`:

- `pointer is not a gcry allocation` (String::Builder `realloc`)
- `realloc(): invalid pointer`
- SEGV (sometimes at ASCII-looking addrs e.g. `0x6e6f736a` == `"json"`)

Debug stack (dbg binary): `Heap#realloc` ← `String::Builder#resize` ← `/json` handler.

### Evidence

| Probe | Result |
|-------|--------|
| `GCRY_KEEP_CHUNKS=1` EC4 | Can survive multi-×10s wrk with real thr (munmap masking) |
| EC4 plain, 8×10s wrk (post scan tweak) | **3/8 fail** |
| EC2+TLAB 8×8s (earlier) | 8/8 ok (lucky / lower pressure) |
| EC4+TLAB | Still intermittent SEGV |
| `ec_alloc_stress` EC4 TLAB off, no auto-GC | OK |

### Landed while investigating

| Fix | Why |
|-----|-----|
| `@index_lock` + always `with_alloc_lock` | Parallel chunk-index / counter races |
| TLAB per-slot locks | Parallel dual-alloc on freelist head |
| STW: scan running fibers in `scan_all_fiber_roots`; nil `current_fiber` → pthread stack | Mark miss when TLS briefly nil / running fiber skipped |
| Full fiber stack + greg on other STW threads | Prior SP-only miss |

### Next

1. Bisect remaining EC>1 mark miss vs allocator race (KEEP_CHUNKS narrows toward mark/sweep+munmap).
2. Consider interior-pointer / `String::Builder` buffer reachability under Parallel (realloc pin exists; ambient stack may still drop raw buffers if owner missed).
3. Only then thr A/B → 0.16.0 cut.

Supported product path remains EC parallelism **1**, `GCRY_TLAB` **off**.
