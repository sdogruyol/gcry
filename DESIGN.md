# gcry — Design

Crystal currently relies on the Boehm–Demers–Weiser collector ([bdwgc](https://github.com/ivmai/bdwgc)) for automatic memory management. **gcry** is a Garbage Collector written in Crystal, intended as a drop-in alternative backend behind Crystal’s existing `GC` abstraction.

This document captures goals, non-goals, architecture, API surface, bootstrap constraints, and a phased roadmap.

## Motivation

- Crystal’s runtime already abstracts libgc behind `GC` (`boehm` and `gc_none` backends). A third backend is a natural extension.
- A Crystal-native collector enables dogfooding, easier experimentation (generational, incremental, barriers), and tighter integration with fibers and the Crystal runtime.
- Conservative collection remains the pragmatic first target: Crystal was shaped around bdwgc’s conservative model (pointer alignment, no precise stack maps).

## Goals

1. Implement a working conservative mark–sweep GC in Crystal.
2. Match Crystal’s `GC` module API closely enough to compile and run programs with a flag such as `-Dgc_gcry`.
3. Support Crystal fibers (stack registration / `set_stackbottom`) and, later, multi-threading (`preview_mt`).
4. Keep the collector core **allocation-free** with respect to the managed heap (no chicken-and-egg allocations during collect).
5. Provide measurable stats and knobs for tuning and comparison against bdwgc.

## Non-goals (near term)

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

## Target Crystal `GC` API

gcry should implement (or wrap into) the same surface Crystal expects:

| Method | Role |
|--------|------|
| `init` | Process-wide collector setup |
| `malloc(size)` | Zeroed, pointer-bearing memory |
| `malloc_atomic(size)` | Non-zeroed, pointer-free memory |
| `realloc(pointer, size)` | Grow/shrink; preserve atomic vs pointerful constraints |
| `free(pointer)` | Optional explicit free (bdwgc compatibility) |
| `collect` | Trigger a collection cycle |
| `enable` / `disable` | Pause automatic collection |
| `add_root(object)` | Pin a reference as a root |
| `add_finalizer(object)` | Register finalizer |
| `register_disappearing_link(pointer)` | Weak / disappearing link support |
| `set_stackbottom(...)` | Associate stack bottom with a thread (fibers) |
| `is_heap_ptr(pointer)` | Query whether an address is in the managed heap |
| `stats` / `prof_stats` | Heap and collector statistics |

Internal Crystal entry points (`__crystal_malloc`, `__crystal_malloc_atomic`, and friends) should continue to call into `GC.*`; only the backend behind `GC` changes.

## Architecture

```text
┌─────────────────────────────────────────────────────────┐
│                   Crystal runtime                       │
│         (__crystal_malloc* → GC.malloc*)                │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                      GC facade                          │
│              (boehm | none | gcry)                      │
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

1. Stop the world (single-threaded MVP: just run collect on the mutator thread).
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

### Phase 0 — Research & contract

- Document Crystal’s `src/gc` (boehm / none) and fiber root registration.
- Freeze the API table above and success criteria for MVP.
- Deliverable: this design doc + short integration notes.

### Phase 1 — Allocator (no collection)

- Arena + size classes + `malloc` / `malloc_atomic` / `realloc` / `free`.
- Metadata and `is_heap_ptr`.
- Tests and simple fuzz (random alloc/free).
- Deliverable: `Gcry::Heap` usable without collecting.

### Phase 2 — Conservative mark–sweep MVP

- Stack root scanning; mark bits; sweep to freelist.
- Threshold-triggered and explicit `collect`.
- Stats: heap size, free bytes, collection count.
- Deliverable: correct single-threaded collector.

### Phase 3 — Fibers & threads

- `set_stackbottom` and fiber stack roots.
- `add_root`, disappearing links, finalizer queue.
- Multi-thread STW (suspend / safepoint) when targeting `preview_mt`.
- Deliverable: multi-fiber (then multi-thread) collect without corruption.

### Phase 4 — Crystal runtime integration

- `gc_gcry` backend behind Crystal’s `GC` module.
- Build real programs with the flag; compare RSS, pause, throughput vs bdwgc.
- Deliverable: demo Crystal apps running on gcry.

### Phase 5 — Hardening

- Stress tests (alloc storms, deep fiber recursion, finalizer + alloc loops).
- Sanitizers where feasible; false-retention analysis.
- CI matrix (Linux x86_64, then aarch64); later Windows / macOS.
- Deliverable: release-candidate reliability bar.

### Phase 6 — Performance & advanced GC

Suggested order:

1. Incremental marking (shorter pauses)
2. Generational nursery (Crystal object churn)
3. Write barriers + compiler cooperation (enables precise / concurrent paths)
4. Concurrent mark
5. Compacting / moving (requires precise roots)

Precise GC is a **separate track**: it needs Crystal codegen changes (stack maps, typed allocation), not only collector work.

### Phase 7 — Productization

- Upstream Crystal PR or officially supported `-Dgc_gcry`.
- Tuning knobs (heap growth, collect threshold, env vars).
- OOM, fork-safety, and signal-safety policy.
- bdwgc parity checklist for supported platforms.

## MVP definition (v0.1)

- Platform: Linux x86_64
- Model: stop-the-world, conservative mark–sweep
- Concurrency: single thread + Crystal fibers
- API: at least `init`, `malloc`, `malloc_atomic`, `collect`, `set_stackbottom`, `stats`
- Integration: Crystal program built with `-Dgc_gcry` runs hello-world and a small alloc/collect loop

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

## Open questions

1. Ship as a standalone shard that patches/overrides `GC`, or as a patch set against crystal-lang/crystal?
2. Finalizer execution model: same thread vs dedicated finalizer fiber?
3. How aggressively to return memory to the OS vs retain freelists?
4. Minimum Crystal version and whether `preview_mt` is in-scope for v0.1 (lean: no).
5. Naming of the compile flag (`gc_gcry` vs `gcry`) and module layout inside the compiler tree.

## References

- Crystal `GC` module API
- Crystal PR abstracting LibGC / enabling `gc_none` ([#5314](https://github.com/crystal-lang/crystal/pull/5314))
- [bdwgc](https://github.com/ivmai/bdwgc)
- Crystal blog: [Garbage Collector](https://crystal-lang.org/2013/12/05/garbage-collector/) (historical context: Boehm as a starting point toward a custom GC)
