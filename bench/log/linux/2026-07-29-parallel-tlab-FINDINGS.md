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

Was ~1–3/60 before this session’s bootstrap guard (+ prior STW/SYSMON hardening on the branch). Torture thr=32KiB remains a stress tool, not the supported Parallel bar.

## 2026-07-31 — TLAB@EC1

### Correctness

| Config | Result |
|--------|--------|
| `GCRY_TLAB=1` EC1 default thr, 20×8s `/json` | **0/20** fail |
| `GCRY_TLAB=1` EC1 thr=32KiB, 20×8s `/json` | **0/20** fail |
| `stw_mt_property_test --tlab --workers=2,4` | PASS |
| `nursery_tlab_smoke` | PASS |

### Throughput (same host, `wrk -c 100 -d 15..20` `/json`)

| Build | req/s (approx) | vs TLAB-off |
|-------|----------------:|------------:|
| TLAB off | ~33–34k | 100% |
| TLAB on | ~24–26k | **~71–77%** |

`/gc-stats` under load: TLAB hit rate ~98%, but each hit still does `find_block` (chunk index) + per-slot lock + `@alloc_lock` for counters — dominates EC1. Removing `find_block` from the hit path SEGVs (stale FREE heads after empty-chunk release). Epoch-gated `find_block` / EC1 lock elision also SEGVd in this session — left unreverted; needs a careful follow-up.

**Decision:** TLAB@EC1 is **correctness-supported opt-in** (`GCRY_TLAB=1`), **not** a thr default. Keep TLAB off on the supported EC1 path. TLAB remains for Parallel prep.

## 2026-07-31 — EC>1 thr vs Boehm

Session `bench/log/linux/2026-07-31-100844-ec-parallel-thr/` (`019b003`), Crystal 1.21.0,
WSL2 i3-12100F, `wrk -c 100 -d 30`, median-of-3, TLAB **off**, fresh process per trial.

| Config | `/json` med req/s | `/` med req/s | post-GC RSS kb |
|--------|------------------:|--------------:|---------------:|
| Boehm EC1 | 39681 | 84235 | ~16700 |
| Boehm EC4 | 72811 | 93810 | ~16000 |
| gcry EC1 | 31699 | 73117 | ~13100 |
| gcry EC4 | 16426 | 33753 | ~20–23k |

| Compare | `/json` | `/` |
|---------|--------:|----:|
| gcry EC1 % of Boehm EC1 | **79.9%** | **86.8%** |
| gcry EC4 % of Boehm EC4 | **22.6%** | **36.0%** |
| Boehm EC4 / EC1 | **1.83×** | **1.11×** |
| gcry EC4 / EC1 | **0.52×** | **0.46×** |

**Verdict:** Parallel EC4 is correctness-quieter than before (0/40 soak) but **anti-scales** under HTTP — about half of EC1 thr and ~23% of Boehm EC4 on `/json`, with higher RSS and ~50–100ms latency. STW / multi-mutator full fiber scan / lock hold across stop→start dominate. Keep EC>1 **experimental**; supported path stays EC1 + TLAB off. Next lever for Parallel thr: shrink STW work when `Thread` count > 2 (full-scan cost), measure with `GCRY_TLAB=1` only after EC4 TLAB-off is closer to EC1.

## Long GDB hang (2026-07-30)

Single-process EC4 + `GCRY_THRESHOLD=32768` under gdb (`SIGSEGV nopass`, `SIGPWR` pass).
No SEGV in ~37m; process wedged ~100% CPU, HTTP dead.

SIGINT dump: **DEFAULT-1** in `unlink_freelist_range` (`collect_sweep.cr:434`) during
major `sweep` ← `allocate` ← Kemal `ParamParser.new`. Other DEFAULT threads in
STW `sigsuspend`. Thread 1 mid `HTTP::Headers#[]=` / Hash upsert when stopped.

Diagnosis: freelist `next_free` cycle → unlink never returns → world never restarts.
Mitigation: bound unlink walk + break self-loops (CHANGELOG Unreleased).

Log: `/tmp/longgdb.log` (also copied if path writable).
