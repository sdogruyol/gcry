# Parallel + TLAB thr A/B

Date: 2026-07-29/30 · host: WSL2 i3-12100F · Crystal 1.21.0

## Method

- Kemal `bench/kemal`, `wrk -c 100 -d 8..30`.
- Parallelism: `EC_PARALLELISM=N` → `Fiber::ExecutionContext.default.resize(N)`.

## Baseline (EC1, TLAB off)

Session `2026-07-29-200917/`: `/json` **83.1%** Boehm.

## Mark-miss isolation (this session)

### Repro

`GCRY_THRESHOLD=32768` → even **EC1** dies at Kemal boot in `Log::AsyncDispatcher#write_logs` (`SIGSEGV @ 0x100000009`). Scrub on/off irrelevant.

### Knob matrix (EC1 thr=32KiB, 5×2s boot)

| Config | Survive |
|--------|---------|
| default (old: gate stacks) | 0/5 |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | **5/5** |
| `GCRY_INTERIOR=1` | 0/5 |
| `GCRY_DISABLE_NURSERY=1` | 0/5 |
| `GCRY_KEEP_CHUNKS=1` | 0/5 |
| `GCRY_DISABLE_LAYOUT=1` | 0/5 |

**Root cause:** `type_id_gate` on **stack** ambient roots rejected live Channel/Deque raw buffers (first word ≠ Crystal type_id). Dispatcher fiber then used a swept Channel.

### Fix

Gate **static** roots only by default. Stack/thread ungated (Boehm-like). Opt into old stack gating: `GCRY_TYPE_ID_GATE=1`.

### After fix

| Test | Result |
|------|--------|
| EC1 thr=32KiB boot | **8/8 OK** |
| EC1 thr=32KiB + wrk `/json` 8×8s | **0/8 fail** |
| EC4 default 20×10s (post-fix) | **2/20** |
| EC4 `GCRY_DISABLE_TYPE_ID_GATE=1` | **4/20** — gate not the residual |
| EC4 `GCRY_DISABLE_AUTO=1` | **0/20** — still collect/mark class |
| Boehm EC4 | 0/8 (earlier) |

## Still open / Parallel residual

Symptom after type_id_gate fix: `realloc(): invalid pointer` (glibc) under EC4.

GDB (SIGINT mid-load): **DEFAULT-1** in `flush_pending_empty_chunks`→`munmap` while **DEFAULT-3** in STW `sweep`/`index_remove`, and **DEFAULT-2** suspended in `GC.realloc`→`is_heap_ptr`. Cause: `@collecting` cleared before post-STW munmap → peer collect STW mid-flush.

### Fix (this session)

1. **type_id_gate stacks off** — EC1 thr=32KiB boot+wrk green.
2. **`@post_stw_lock`** — next collect waits for prior post-STW munmap (gdb showed STW mid-flush). Holding `@collecting` through flush made flakes *worse* (7/20); lock-without-suppressing-alloc is the right shape.
3. **`GC.realloc` span guard** — raise instead of `LibC.realloc` when address is in historic heap span but not in chunk index.

### EC4 matrix

| Config | fail |
|--------|-----:|
| pre type_id fix (approx) | ~4/20 |
| stacks ungated only | 2/20 |
| hold `@collecting` through flush | **7/20** (regressed) |
| `@post_stw_lock` (post-fix) | **1/20** |
| pthread always-scan | **1/40 … 2/60** |
| + SP-containing stack scan | **0/40** then **5/60** (noise) |
| + full fiber scan under STW | **1/60** |
| + scrub skip if SP on fiber | **2/60** |
| historic span + mutator HW SP | **2/60** (thr=64k **0/30**) |
| + start_world cache invalidate | **4/80** (~same class) |
| `DISABLE_SCRUB_FIBERS` | **4/40** (worse — scrub not root cause) |
| `DISABLE_LAYOUT` | **7/40** (worse) |
| `KEEP_CHUNKS` | **6/40** (worse) |
| `DISABLE_AUTO` | **0/20** |

Residual ~1–3/60 still collect/mark class (SEGV @ `0x…0008`). Also: monotonic `@heap_span_*` for LibC realloc/free guard; mutator scan from hardware SP−red zone; invalidate last-chunk cache at `start_world`.

Supported path: EC1, TLAB off.

## 2026-07-31 — thread bootstrap collect + re-measure

### Boot crash (symbolized)

`GCRY_THRESHOLD=32768` EC4 died at Kemal “ready” with `END_OF_STACK` /
`Thread#current_fiber cannot be nil`. nm stack:

`Thread#start` → `Fiber::new` → `GC.malloc` → `maybe_collect` → `run_collection`

Worker OS thread allocates its main fiber **before** `@current_fiber` is set.
Fix: skip process collect while `Thread.current.@current_fiber` is nil
(CHANGELOG Unreleased).

### After fix (same host)

| Config | Result |
|--------|--------|
| EC4 thr=32KiB boot+wrk | still bad — mostly boot hang / occasional SEGV @ `pthread_getattr_np` during further `Thread#start` under extreme collect rate |
| EC4 **default** threshold, 15×8s `/json` | **0/15** fail |
| EC4 **default** threshold, 40×8s `/json` | **0/40** fail |

Was ~1–3/60 before this session’s bootstrap guard (+ prior STW/SYSMON hardening on the branch). Torture thr=32KiB remains a stress tool, not the supported Parallel bar. Next: longer default soaks / thr=64k / TLAB@EC1.

## Long GDB hang (2026-07-30)

Single-process EC4 + `GCRY_THRESHOLD=32768` under gdb (`SIGSEGV nopass`, `SIGPWR` pass).
No SEGV in ~37m; process wedged ~100% CPU, HTTP dead.

SIGINT dump: **DEFAULT-1** in `unlink_freelist_range` (`collect_sweep.cr:434`) during
major `sweep` ← `allocate` ← Kemal `ParamParser.new`. Other DEFAULT threads in
STW `sigsuspend`. Thread 1 mid `HTTP::Headers#[]=` / Hash upsert when stopped.

Diagnosis: freelist `next_free` cycle → unlink never returns → world never restarts.
Mitigation: bound unlink walk + break self-loops (CHANGELOG Unreleased).

Log: `/tmp/longgdb.log` (also copied if path writable).
