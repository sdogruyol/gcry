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

## 2026-07-31 — multi-mutator STW stack LAG (512 KiB)

### Profile

EC4 Kemal `/json` `wrk -c 100 -d 12`: last-collect `phase_roots` was **~65–80%** of timed phases (~100–250ms) with classic `stw_full` (every parked fiber `guard→bottom`). EC1 `phase_roots` ~2–3ms.

Blanket clamp to `stack_top` (no lag) → soak fail class `pointer is not a gcry allocation` (4–9/30). `scan_range_safe` run-walking all pages made pauses **worse** (pipe probe × deep contiguous stacks).

### Change

`scan_all_fiber_roots` when `@world_stopped && multi_mutator_threads?`:

1. If a suspended thread SP sits on the fiber → scan from SP−red_zone.
2. Else if `fiber.running?` → still `guard` (no SP visible).
3. Else → `max(guard, stack_top − 512KiB)` (not full guard).

EC1 / single-mutator path unchanged (`stack_top` clamp). `scan_other_thread_stacks` unchanged (greg / current_fiber / SP / pthread).

### Results (same host, TLAB off)

| Check | Result |
|-------|--------|
| `stw_mt_property_test` plain + `--tlab` | PASS |
| EC4 soak 30×8s `/json` | **0/30** fail |
| A/B `/json` `wrk -c 100 -d 20` median-of-5 | LAG **30009** vs stw_full **15676** (**~1.91×**) |
| EC1 `/json` smoke (15s×3) | ~31–34k (no regression) |

Session notes: `bench/log/linux/2026-07-31-ec4-stw-lag/`. Still below Boehm EC4 (~80k) and noisy under load; do **not** fold into Linux `docs/PERF.md` (EC1 headline).

## 2026-07-31 — LAG re-cut vs Boehm + TLAB@EC4

Session `bench/log/linux/2026-07-31-112014-ec-parallel-lag-thr/` (`94aadaf`),
`wrk -c 100 -d 30`, median-of-3, TLAB **off** unless noted.

### Thr vs Boehm (LAG, TLAB off)

| Config | `/json` med | `/` med |
|--------|------------:|--------:|
| Boehm EC1 | 38196 | 76890 |
| Boehm EC4 | 76447 | 105771 |
| gcry EC1 | 32272 | 61883 |
| gcry EC4 | 28085 | 68102 |

| Compare | `/json` | `/` |
|---------|--------:|----:|
| gcry EC1 % Boehm EC1 | **84.5%** | **80.5%** |
| gcry EC4 % Boehm EC4 | **36.7%** | **64.4%** |
| Boehm EC4/EC1 | **2.00×** | **1.38×** |
| gcry EC4/EC1 | **0.87×** | **1.10×** |

vs pre-LAG (`2026-07-31-100844`): EC4 `/json` **~23%→~37%** Boehm; gcry EC4/EC1 **~0.52×→~0.87×**.
One EC4 `/json` trial collapsed (~8.5k); median still ~28k. EC>1 remains experimental; no `PERF.md` fold-in.

### TLAB@EC4 (LAG on)

| Check | Result |
|-------|--------|
| Soak 20×8s `/json` `GCRY_TLAB=1` | **3/20** fail (DIE) |
| `/json` `wrk -c 100 -d 20` med-of-5 | TLAB-off **17844** (noisy; one ~524) / TLAB-on **18280** (tighter 14–20k) |

**Verdict:** TLAB@EC4 is **not** a thr win over good LAG TLAB-off runs (~26–30k) and soak is worse than TLAB-off 0/30. Keep `GCRY_TLAB=1` opt-in/experimental for Parallel. Next Parallel lever: alloc-path contention / pause variance (outlier trials), not TLAB default.

## 2026-07-31 — EC4 pause/thr variance (post-STW mutex + coalesce)

### Diagnosis

15× EC4 `/json` `d=20` with new `/gc-stats` wait timers (SpinLock + LAG):

- Healthy runs (~22k): **`post_stw_wait_total` ~8–11s** per 20s — collect queue on SpinLock dominates; waiters burn an EC core.
- Outliers (~1.5–11k, 3/15): SEGV / mark-miss (`pointer is not a gcry allocation`); empty stats.

STW phase work (roots/sweep) after LAG is small vs queue time.

### Fixes

1. Replace `@post_stw` SpinLock with embedded **`pthread_mutex`** (no GC alloc at boot).
2. **`collect(coalesce: true)`** from `maybe_collect`: if peer collect cleared debt while waiting, skip (`collect_coalesced`).
3. Pause ring starts **after** mutex wait; expose wait/stop/start/flush + coalesced in `/gc-stats`.

### Results

| Build | `/json` med d=20 | Soak |
|-------|-----------------:|------|
| SpinLock baseline | ~22.5k (3/15 crash) | — |
| Mutex only | ~20.8k | 15/15 alive |
| Mutex + coalesce | **~40.1k** (5× 39.6–41.3k) | **20/20** |

EC1 smoke ~34k. Session: `bench/log/linux/2026-07-31-ec4-post-stw-mutex-coalesce/`. Still experimental; no `PERF.md` fold-in. Next: longer soak + quiet Boehm EC4 re-cut with coalesce.

## 2026-07-31 — Boehm re-cut (LAG + mutex + coalesce)

Session `bench/log/linux/2026-07-31-123742-ec-parallel-coalesce-thr/` (`4d78af0`),
`wrk -c 100 -d 30`, median-of-3, TLAB **off**.

| Config | `/json` med | `/` med |
|--------|------------:|--------:|
| Boehm EC1 | 37286 | 80133 |
| Boehm EC4 | 69910 | 116713 |
| gcry EC1 | 31123 | 65423 |
| gcry EC4 | 36447 | 74804 |

| Compare | `/json` | `/` |
|---------|--------:|----:|
| gcry EC1 % Boehm EC1 | **83.5%** | **81.6%** |
| gcry EC4 % Boehm EC4 | **52.1%** | **64.1%** |
| Boehm EC4/EC1 | **1.87×** | **1.46×** |
| gcry EC4/EC1 | **1.17×** | **1.14×** |

| Session | EC4 % Boehm `/json` | EC4/EC1 `/json` |
|---------|--------------------:|----------------:|
| pre-LAG | ~23% | ~0.52× |
| LAG only | ~37% | ~0.87× |
| **LAG+mutex+coalesce** | **~52%** | **~1.17×** |

gcry EC4 now **scales above EC1** on `/json` (no longer anti-scales). Residual: ~half Boehm EC4; ~17s post_stw wait_total / 30s; RSS ~2× Boehm. No `PERF.md` fold-in. Next: longer soak; then shrink remaining queue / alloc gap.

## Long GDB hang (2026-07-30)

Single-process EC4 + `GCRY_THRESHOLD=32768` under gdb (`SIGSEGV nopass`, `SIGPWR` pass).
No SEGV in ~37m; process wedged ~100% CPU, HTTP dead.

SIGINT dump: **DEFAULT-1** in `unlink_freelist_range` (`collect_sweep.cr:434`) during
major `sweep` ← `allocate` ← Kemal `ParamParser.new`. Other DEFAULT threads in
STW `sigsuspend`. Thread 1 mid `HTTP::Headers#[]=` / Hash upsert when stopped.

Diagnosis: freelist `next_free` cycle → unlink never returns → world never restarts.
Mitigation: bound unlink walk + break self-loops (CHANGELOG Unreleased).

Log: `/tmp/longgdb.log` (also copied if path writable).
