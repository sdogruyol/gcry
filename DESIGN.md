# gcry — Design

Crystal currently relies on the Boehm–Demers–Weiser collector ([bdwgc](https://github.com/ivmai/bdwgc)) for automatic memory management. **gcry** is a Garbage Collector written in Crystal, intended as a drop-in alternative backend behind Crystal’s existing `GC` abstraction.

This document captures goals, non-goals, architecture, API surface, bootstrap constraints, and a phased roadmap.

## Motivation

- Crystal’s runtime already abstracts libgc behind `GC` (`boehm` and `gc_none` backends). A third backend is a natural extension.
- A Crystal-native collector enables dogfooding, easier experimentation (generational, incremental, barriers), and tighter integration with fibers and the Crystal runtime.
- Conservative collection remains the pragmatic first target: Crystal was shaped around bdwgc’s conservative model (pointer alignment, no precise stack maps).

## Goals

1. Implement a working conservative mark–sweep GC in Crystal.
2. Ship as a **shard** that reopens Crystal’s `GC` module: `require "gcry"` + build with `-Dgc_none`.
3. Support Crystal fibers under the 1.21+ `Fiber::ExecutionContext` default; later, parallel contexts / multi-thread STW.
4. Keep the collector core **allocation-free** with respect to the managed heap (no chicken-and-egg allocations during collect).
5. Provide measurable stats and knobs for tuning and comparison against bdwgc.

## Non-goals (near term)

- Patching or forking the Crystal compiler / stdlib to add a third built-in backend.
- Replacing bdwgc in upstream Crystal as the default (that is a later adoption decision).
- Precise / moving / compacting GC without compiler support for stack maps and write barriers.
- Full concurrent collection in the first releases.
- Windows / macOS parity on day one (Linux x86_64 first).
- Being a general-purpose C allocator for non-Crystal programs.

## Design principles

| Principle | Rationale |
|-----------|-----------|
| Match `GC` first | Integration beats novelty; API parity unlocks real Crystal programs. |
| Conservative before precise | Compatible with today’s Crystal codegen; precise is a separate epic. |
| Allocation-free collector | Hot paths use `mmap`, stack buffers, and out-of-heap arenas only. |
| STW before concurrent | Correctness and fiber roots first; concurrency later. |
| Small, testable core | Heap, mark, sweep, and roots as separable modules with unit tests. |

## Frozen API contract (Phase 0)

Researched against Crystal **1.21.0**. Full notes: [docs/INTEGRATION.md](docs/INTEGRATION.md).

gcry implements the same surface as `gc/boehm.cr` / `gc/none.cr`. Stdlib entry points (`__crystal_malloc*`) keep calling `GC.*`; the shard **reopens** `module GC` and replaces the `gc_none` stubs.

### Required for MVP (v0.1)

| Method | Role |
|--------|------|
| `init` | Process setup; register fiber root callback |
| `malloc(size : LibC::SizeT) : Void*` | Zeroed; may contain pointers |
| `malloc_atomic(size : LibC::SizeT) : Void*` | Non-zeroed; pointer-free |
| `realloc(ptr, size) : Void*` | Grow/shrink; keep atomic constraints |
| `free(pointer)` | Explicit free (zlib, GMP, …) |
| `collect` | Full STW mark–sweep |
| `enable` / `disable` | Pause automatic collection |
| `stats` | Meaningful `heap_size`, `free_bytes`, `bytes_since_gc`, `total_bytes` |
| `is_heap_ptr(pointer)` | Address in managed heap? |
| `set_stackbottom(...)` | Running fiber stack bottom (`Thread` form when `!without_mt`; `Void*` under `-Dwithout_mt`) |
| `push_stack(stack_top, stack_bottom)` | Scan suspended fiber stack |
| `before_collect(&block)` or equivalent in `init` | Push non-running fiber roots |
| `current_thread_stack_bottom` | Main fiber stack bounds |
| `lock_read` / `unlock_read` / `lock_write` / `unlock_write` | No-ops acceptable for MVP |

### Required later (Phase 3+)

| Method | Role |
|--------|------|
| `add_root` / `add_finalizer` / `register_disappearing_link` | Roots, finalizers, `WeakRef` ✅ Phase 3 |
| `prof_stats` | Full Boehm-shaped profiling (zeros OK until then) |
| MT / parallel `set_stackbottom` + STW | Parallel ExecutionContexts |
| `stop_world` / `start_world` | Multi-thread STW (process GC enables; signal-suspend like `gc/none`) |
| `pthread_*` GC registration | When threads must be tracked |

### Integration decision (shard override)

1. Build the program with **`-Dgc_none`** so Crystal loads the stub backend (no bdwgc link).
2. Early in the program (or via a prelude require), **`require "gcry"`**.
3. `src/gcry.cr` reopens `module GC` and overrides `malloc` / `collect` / fiber hooks / etc.

```crystal
# app.cr
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

puts "hello"
```

```sh
crystal build -Dgc_none app.cr
```

- Collector implementation lives under `Gcry::*`; the `GC` reopen is a thin facade.
- Unit tests of the heap can still run under default Boehm without installing gcry as process GC.
- **No Crystal source patch.** Upstream `-Dgc_gcry` is optional later, not required.
- **Parallel ExecutionContexts / multi-thread STW are out of MVP.** (Default context parallelism 1 is in scope.)

## Architecture

```text
┌─────────────────────────────────────────────────────────┐
│                   Crystal runtime                       │
│         (__crystal_malloc* → GC.malloc*)                │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│              GC facade (reopened by shard)              │
│         boehm | none ← overwritten by gcry              │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                         Gcry                            │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────┐ │
│  │   Heap   │  │  Roots   │  │   Mark   │  │  Sweep  │ │
│  │ arenas   │  │ stacks   │  │   bit    │  │ freelist│ │
│  │ size cls │  │ fibers   │  │   stack  │  │         │ │
│  └──────────┘  └──────────┘  └──────────┘  └─────────┘ │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────────┐ │
│  │Finalizer │  │  Stats   │  │ Platform (Linux, …)    │ │
│  └──────────┘  └──────────┘  └────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### Heap

- Backing store: `mmap` / `munmap` arenas (not the system `malloc` for managed objects).
- Size classes for small objects; large objects in dedicated spans.
- Block metadata (out-of-line or header): size, atomic vs pointerful, mark state.
- `malloc` clears memory; `malloc_atomic` does not and promises no interior pointers to scan.

### Roots

- Current thread stack (from stack pointer to registered stack bottom).
- Fiber stacks registered via Crystal’s fiber / `set_stackbottom` hooks.
- Explicit roots (`add_root`) and static data ranges as needed.
- Conservatively treat aligned words that look like heap pointers as live references.

### Mark–sweep (MVP)

1. Stop the world (v0.1: run collect on the mutator; no parallel-context STW).
2. Push roots; mark reachable blocks (worklist / mark stack allocated outside the GC heap).
3. Sweep unmarked blocks into freelists; optionally return empty spans to the OS.
4. Run finalizers after the mutator resumes (never allocate into a half-collected heap from finalizer registration paths without care).

### Bootstrap constraint

The collector and its metadata structures must not allocate from the managed heap during a collection. Prefer:

- Pre-reserved mark stacks and bitmaps in an immortal arena.
- Stack-allocated temporary buffers where bounds are known.
- `LibC` / `mmap` for expanding collector metadata when needed.

Early development and unit tests can run under `-Dgc_none` or against a harness that never installs gcry as the process GC until the core is solid.

## Proposed source layout

```text
src/
  gcry.cr                 # public module / version
  gcry/
    heap.cr               # arenas, size classes, malloc/realloc/free
    block.cr              # block metadata
    mark.cr               # conservative marking
    sweep.cr              # reclaim unmarked blocks
    roots.cr              # stack / fiber / explicit roots
    finalizer.cr          # finalizer queue
    stats.cr              # GC::Stats-compatible counters
    platform/
      linux.cr            # stack bounds, later STW helpers
spec/
  heap_spec.cr
  collect_spec.cr
  fiber_spec.cr
bench/
  alloc_churn.cr
DESIGN.md
```

## Phased roadmap

### Phase 0 — Research & contract ✅

- Documented Crystal’s `src/gc` (boehm / none) and fiber root registration.
- Froze the API contract and MVP success criteria (this document).
- Deliverable: [docs/INTEGRATION.md](docs/INTEGRATION.md) + this design doc.

### Phase 1 — Allocator (no collection) ✅

- Arena + size classes + `malloc` / `malloc_atomic` / `realloc` / `free`.
- Metadata and `is_heap_ptr`.
- Tests and simple fuzz (random alloc/free).
- Deliverable: `Gcry::Heap` usable without collecting.

### Phase 2 — Conservative mark–sweep MVP ✅

- Stack root scanning; mark bits; sweep to freelist.
- Threshold-triggered and explicit `collect`.
- Stats: heap size, free bytes, collection count.
- Deliverable: correct collector for default ExecutionContext (`Gcry::Heap#collect`).

### Phase 3 — Fibers & threads ✅

- `set_stackbottom`, `push_stack`, and `before_collect` for suspended fiber stacks (ExecutionContext: refresh bottom from `Fiber.current` at collect).
- `add_root`, disappearing links, finalizer queue (run after collect).
- Locks remain no-ops; process GC enables STW for the Monitor thread (and any other OS threads).
- Deliverable: multi-fiber-ready root API + finalizers / weak links (`spec/fiber_spec.cr`).

### Phase 4 — Shard `GC` override ✅

- Reopen `module GC` under `-Dgc_none` (`src/gcry/gc_override.cr`).
- LibC bootstrap until `GC.init` completes; Fiber `before_collect` / `push_stack` wired.
- Linux static roots via `/proc/self/maps` (excluding the managed heap).
- Samples: `samples/hello.cr`, `samples/alloc.cr` (`crystal build -Dgc_none …`).
- Deliverable: Crystal programs run with gcry as process GC via shard require only.

### Phase 5 — Hardening ✅

- Stress tests: `spec/stress_spec.cr` + `samples/stress.cr`.
- Process tuning: `GCRY_THRESHOLD`, `GCRY_DISABLE_AUTO`; finalizer nested-collect guard.
- CI: `.github/workflows/ci.yml` (Linux x86_64 specs + `-Dgc_none` samples).
- Notes: [docs/HARDENING.md](docs/HARDENING.md) (false retention, sanitizers).
- Deliverable: reliability bar for RC-style use on Linux x86_64.

### Phase 6 — Performance & advanced GC ✅

Shipped without compiler write barriers:

1. **Incremental marking** — `collect_a_little` / `GC.collect_a_little` (work-budget mark slices; black alloc while a cycle is active). Process GC (v0.3+) auto-majors use slices by default (`incremental_auto`; `GCRY_DISABLE_INCREMENTAL=1` for full STW).
2. **Nursery / minor GC** — young size-class freelists; `minor_collect`; old→young conservative scan (no barriers). Survivors promote to old space.
3. Nursery threshold constant: 512 KiB (`DEFAULT_NURSERY_THRESHOLD`). Library heap leaves nursery at `UInt64::MAX` unless configured. Process GC (v0.2+): nursery **off** unless `GCRY_NURSERY`; majors at 64 MiB (`PROCESS_GC_THRESHOLD`).
4. Bench: `bench/churn.cr` (library heap); `bench/kemal` + `make bench-kemal-wrk` (process GC). Pause counters: `Gcry.pause_stats`.

Deferred (need codegen / barriers):

- Write barriers + concurrent mark
- Compacting / moving / precise roots

Precise GC remains a **separate track**: Crystal stack maps and typed allocation, not only collector work.

### Phase 7 — Productization ✅

- Shard UX: polished README, `shard.yml` metadata, `Makefile` (`spec` / `samples` / `bench`).
- Tuning: `GCRY_THRESHOLD`, `GCRY_DISABLE_AUTO`, `GCRY_NURSERY`, `GCRY_DISABLE_NURSERY`.
- Policies: [docs/POLICY.md](docs/POLICY.md) (OOM emergency collect + raise, fork unsupported, not signal-safe).
- Comparison: [docs/COMPARISON.md](docs/COMPARISON.md) vs bdwgc.
- Deliverable: adopt-able v0.1 shard without patching Crystal.

### Phase 8 — Production hardening + STW perf ✅ (v0.5.0)

- Empty-chunk release stays **opt-in** (`GCRY_RELEASE_CHUNKS=1`); default-on loses too much vs Boehm.
- Pin finalizer Array buffers / Proc closures during mark (LibC-bootstrap metadata).
- Pause p50/p99; richer `GC.prof_stats` reclaim counters; `samples/json_churn.cr`.
- STW hot path: O(n) static-root×heap exclusion via sorted chunk index; `find_object` block-bytes cache; larger mark stack.
- Page-map + out-of-line mark bitmap **tried, not shipped** (no `/json` Boehm-% win under Kemal gate).
- Mark-epoch (skip `clear_all_marks` walk) **not** shipped — caused Hash corruption under Kemal; keep header bit marks.

### Phase 9 — STW soundness + Boehm parity ✅ (v0.6.0)

- Crystal 1.21 SYSMON STW + stack/static-root hardening (CI SIGBUS / live-object sweep fixes).
- Size-class ceiling **32 KiB**; `notice_reclaim` flag fast-path; incremental chunk index.
- Same-host Kemal `/json` ~**100%** of Boehm; acikturkiye `/api/v1/` ~**101%** — see [docs/PERF.md](docs/PERF.md), [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

### Phase 10 — Large-object / RSS ✅ (diagnostics)

- Large freelist reuse is **exact mapped-size** only (no fat VMA for a smaller need).
- Heap breakdown: `large_mapped_bytes` / `small_mapped_bytes` / `small_free_bytes`; `GCRY_LARGE_CACHE` retain limit.
- Empty-chunk `munmap` **outside STW**; occupancy `fully_free_chunk_bytes` / `released_chunk_bytes`.
- `size_class_live_bytes` + fill histogram; `GCRY_CHUNK_BYTES` (default 256 KiB).
- Measured: acikturkiye chunks are **dense live** (~64% live/mapped, ~76% ge75) — not sparse; 128 KiB trial no RSS win.

### Phase 11 — Soft-dirty nursery (in progress)

- Linux soft-dirty platform (`clear_refs` / pagemap bit 55) for old→young edges without compiler barriers.
- Process minors: dirty-page scan when `soft_dirty_armed`; else full old scan. Library heaps always full-scan.
- **Fixed:** minor finalizers/WeakRef only for nursery objects (`minor_only` leaves old unmarked).
- Chunk-scoped soft-dirty + dirty-fraction fallback (`soft_dirty_max_pct`); skip until major when too dirty.
- `GCRY_NURSERY` remains **opt-in**. WSL **6.18.33.2**: soft-dirty arms; HTTP workloads too dirty for a win (Kemal ~10× slower; acikturkiye RSS worse).
- Gate: default (nursery off) Kemal `/json` ≈ Boehm.

## MVP definition (v0.1)

- Platform: Linux x86_64, Crystal `>= 1.21` default ExecutionContext (parallelism 1)
- Model: stop-the-world, conservative mark–sweep
- Concurrency: Crystal fibers on the default context — **not** parallel contexts
- API: at least `init`, `malloc`, `malloc_atomic`, `collect`, stack-bottom / `push_stack`, `stats`
- Integration: `require "gcry"` + `crystal build -Dgc_none` runs hello-world and a small alloc/collect loop

Anything beyond that (MT, incremental, generational) is post-MVP.

## Risks

| Risk | Mitigation |
|------|------------|
| Collector allocates from GC heap | Immortal arenas; coding rules + tests that forbid managed alloc in hot paths |
| Conservative false retention | Good size classes; later generational collection; measure retained heap vs bdwgc |
| Fiber / MT root bugs | Explicit root registry; stress specs; STW before concurrent |
| Precise GC expectations | Keep precise as a separate roadmap; do not block MVP on it |
| Platform divergence | Linux-first; isolate `platform/` early |

## Success metrics

- Correctness: no use-after-free or lost objects under stress suites.
- Integration: Crystal stdlib samples and selected shards run under gcry.
- Performance: pause and RSS competitive with bdwgc on representative benches (parity first, then beat on targeted workloads).
- Maintainability: collector logic readable in Crystal; clear module boundaries.

## Decisions (Phase 0)

| Topic | Decision |
|-------|----------|
| Distribution | Pure shard; reopen `module GC` under `-Dgc_none` |
| Activation | `require "gcry"` + compile with `-Dgc_none` |
| Crystal patch | Not required |
| Crystal version | `>= 1.21.0` (matches researched stdlib) |
| `preview_mt` / parallel contexts in v0.1 | No — default ExecutionContext (parallelism 1) only |
| Early testing | `Gcry::*` under default Boehm; process GC via `-Dgc_none` once facade exists |

## Open questions (resolved for v0.1)

1. **Finalizers:** run on the same thread after collect (not a dedicated finalizer fiber).
2. **Return memory to OS:** `munmap` large objects on reclaim; keep size-class chunks mapped for freelist reuse.
3. **`add_root`:** maintain and scan an internal root set (not Boehm’s unused Array-only quirk).
4. **`stop_world` / `start_world`:** process GC enables signal-suspend STW and scans other threads' current-fiber stacks (Crystal 1.21 Monitor / SYSMON). Library `Gcry::Heap` leaves STW off.

## References

- [docs/INTEGRATION.md](docs/INTEGRATION.md) — Crystal 1.21.0 GC / fiber notes
- [docs/POLICY.md](docs/POLICY.md) — OOM / fork / signal policy
- [docs/COMPARISON.md](docs/COMPARISON.md) — bdwgc comparison checklist
- Crystal `src/gc.cr`, `src/gc/boehm.cr`, `src/gc/none.cr`
- Crystal PR abstracting LibGC / enabling `gc_none` ([#5314](https://github.com/crystal-lang/crystal/pull/5314))
- [bdwgc](https://github.com/ivmai/bdwgc)
- Crystal blog: [Garbage Collector](https://crystal-lang.org/2013/12/05/garbage-collector/) (historical context: Boehm as a starting point toward a custom GC)
