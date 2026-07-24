# gcry — Design

**A garbage collector Crystal can actually own.**

Crystal runs on [Boehm](https://github.com/ivmai/bdwgc) today. That works — and it also means the language’s most intimate runtime piece lives in C, behind a wall. **gcry** is the other path: a conservative mark–sweep collector written in Crystal, shipped as a shard, plugged in with `-Dgc_none`. No compiler fork. No waiting for upstream to grow a third backend.

This doc is the map: why the shape is what it is, how the pieces fit, and where the frontier is after **v0.9**.

---

## The bet

Crystal’s codegen and stdlib grew up around Boehm’s **conservative, non-moving** contract. Fighting that on day one (precise stacks, moving objects) means fighting the language. gcry takes the opposite route:

1. **Match the contract** — same `GC` surface, same pointer-shaped world.
2. **Win in Crystal** — readable hot paths, shard-speed iteration, real HTTP dogfood.
3. **Earn precision later** — stack maps and barriers are a compiler epic; the shard already carries everything that doesn’t need one.

As of v0.9.0 (same-host Kemal, median of 3): **`/json` ~92% of Boehm thr**, post-GC RSS **~0.97×**. Fat apps still show the conservative tax — see [docs/PERF.md](docs/PERF.md) and [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md). The point stands: this is not a lab toy.

## Goals

1. A **correct** conservative STW mark–sweep GC in Crystal.
2. Ship as a **shard**: `require "gcry"` + `-Dgc_none` reopens `module GC`.
3. Fibers on the default ExecutionContext (**parallelism 1**); experimental knobs for parallel contexts.
4. Collector hot paths **allocation-free** w.r.t. the managed heap.
5. Numbers you can trust: pause histograms, Prometheus, % of Boehm — not vibes.

## Non-goals (for now)

- Forking Crystal to add `-Dgc_gcry` (nice later; not required).
- Replacing Boehm as upstream default (adoption, not a design prerequisite).
- Precise / moving / compacting GC without stack maps + write barriers from the compiler.
- Full concurrent collection as the default.
- macOS / Windows process GC parity (Darwin stubs type-check; process init still Linux-first).
- Being a general C malloc for non-Crystal programs.

## Principles

| Principle | Why |
|-----------|-----|
| **`GC` parity first** | Integration beats novelty; real programs unlock real bugs. |
| **Conservative before precise** | Matches today’s Crystal; precise is a separate epic. |
| **Allocation-free collect** | `mmap`, immortal arenas, stack buffers — never `GC.malloc` mid-mark. |
| **STW before concurrent** | Correct fiber / thread roots first; concurrency is opt-in and measured. |
| **Small modules** | Heap, roots, mark, sweep, platform — each testable in isolation. |
| **Measure, then ship defaults** | Empty-chunk release, type_id gate, SP clamp earned their defaults; scrub / parallel-mark stay opt-in or experimental. |

## How it plugs in

Crystal already abstracts libgc behind `GC` (`boehm` | `none`). gcry **is** the `none` path filled in:

1. Build with **`-Dgc_none`** (no bdwgc link).
2. **`require "gcry"`** — reopens `module GC` (`src/gcry/gc_override.cr`).
3. Stdlib keeps calling `GC.malloc*` / fiber hooks; the facade forwards into `Gcry::*`.

```crystal
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}
```

```sh
crystal build -Dgc_none app.cr
```

Full surface vs Boehm: [docs/INTEGRATION.md](docs/INTEGRATION.md). Comparison checklist: [docs/COMPARISON.md](docs/COMPARISON.md).

## Architecture

```text
┌─────────────────────────────────────────────────────────┐
│                   Crystal runtime                       │
│         (__crystal_malloc* → GC.malloc*)                │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│           GC facade (shard reopen under gc_none)        │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│                         Gcry                            │
│  Heap ── size classes, TLAB, large cache, chunk release │
│  Roots ─ stacks, fibers, static maps, type_id gate      │
│  Collect ─ STW · scan · mark · sweep (split modules)    │
│  Layout / blacklist / scrub ─ less false retention      │
│  Barrier ─ soft-dirty / mprotect (nursery & incremental)│
│  Finalizer · Metrics · Observability · Platform         │
└─────────────────────────────────────────────────────────┘
```

### Heap

- Backing: `mmap` / `munmap` chunks (not system `malloc` for managed objects).
- Size classes for small objects; large objects in dedicated spans; exact-fit large freelist reuse.
- Headers: size, atomic vs pointerful, nursery / free flags, mark bits.
- Process default: **empty chunks munmap** outside STW (`GCRY_KEEP_CHUNKS=1` to escape).
- Optional **TLAB** freelist buffers for parallel contexts (`GCRY_TLAB=1`).

### Roots

- Running fiber: SP → stack bottom; other threads: STW + **SP clamp** when available.
- Parked fibers via `push_stack` / `before_collect`.
- Static ranges from `/proc/self/maps` (heap excluded).
- Explicit `add_root`, finalizers, disappearing links / `WeakRef`.
- Ambient candidates: **base-pointer-only** by default + root **type_id** gate (heap scan stays ungated for buffers).

### Collect

1. **STW** (process GC): signal-suspend other OS threads; library heaps can skip.
2. Optional **stack scrub** (opt-in): wipe unused words below SP / parked fiber SP — Boehm-style hygiene, not stack maps.
3. Push roots; **mark** (worklist outside the GC heap). Layout tables scan known offsets precisely where registered.
4. Optional **parallel mark** (experimental): STW-exempt pthreads steal grey objects — measure thr before enabling.
5. **Sweep** unmarked → freelists; release empty chunks; run finalizers after the world resumes.

Incremental / nursery paths exist behind env flags; process HTTP defaults stay **full STW major** (dirty heaps punish soft-dirty minors — measured).

### Bootstrap rule

During collect, the collector must **not** allocate from the managed heap. Immortal arenas, pre-sized mark stacks, `mmap` for metadata growth, stack temps only.

Unit tests exercise `Gcry::Heap` under Boehm as a library allocator; process GC needs `-Dgc_none`.

## Source layout

```text
src/gcry.cr                 # VERSION, public entry
src/gcry/
  heap.cr                   # arenas, size classes, alloc path
  block.cr · size_classes.cr · tlab.cr
  roots.cr · layout.cr · blacklist.cr · stack_scrub.cr
  collect.cr                # orchestration
  collect_stw.cr · collect_scan.cr · collect_mark.cr · collect_sweep.cr
  parallel_mark.cr · barrier.cr · mark.cr
  finalizer.cr · metrics.cr · observability.cr
  gc_override.cr            # module GC reopen
  platform/                 # linux STW, soft-dirty, mprotect, fork, roots, …
spec/ · process_spec/ · bench/ · samples/
```

## Where we are (v0.9)

Shipped and dogfooded on Linux:

| Area | State |
|------|--------|
| Process GC via shard | ✅ `-Dgc_none` |
| Fibers + Monitor STW | ✅ SP clamp on x86_64 / aarch64 |
| Empty-chunk RSS | ✅ default-on — Kemal ~**0.97×** Boehm |
| Layout / type_id / blacklist | ✅ defaults + escapes |
| Barriers (soft-dirty / mprotect) | ✅; nursery still **opt-in** |
| Observability | ✅ metrics, Prometheus, json_stats |
| Fork reinit | ✅ `pthread_atfork` (default) |
| Stack scrub | ✅ opt-in (`GCRY_CLEAR_STACK` / `GCRY_SCRUB_FIBERS`) |
| Parallel mark | ⚠️ experimental — HTTP thr often regresses |
| macOS process GC | ❌ stubs only |
| Compiler stack maps | ❌ frontier (see below) |

**Kemal (v0.9.0 cut):** `/` ~**89%**, `/json` ~**92%**, post-GC RSS ~**0.97×** — [PERF.md](docs/PERF.md).

**acikturkiye:** thr trial-median ~**93%**, post-GC RSS ~**2.84×** — dense conservative-live; shard levers mostly exhausted — [ACIKTURKIYE.md](docs/ACIKTURKIYE.md).

## Frontier

What still needs **compiler** (or radical runtime) help:

| Track | Why it matters |
|-------|----------------|
| **Stack maps / precise roots** | Closes fat-app RSS without hoping scrub + gates are enough |
| **Write barriers in codegen** | Sound concurrent / cheaper incremental for dirty HTTP heaps |
| **Moving / compacting** | Fragmentation & locality — only after precise roots |
| **macOS / Windows STW + roots** | Real process GC beyond Linux |
| **Parallel contexts by default** | TLAB + STW-exempt mark must win thr before flipping defaults |

Shard-only work that remains interesting: better layout coverage, smarter large-object policy, pause UX, and keeping parallel-mark honest under real load.

## Risks

| Risk | Mitigation |
|------|------------|
| Collector allocates from GC heap | Immortal arenas; hot-path rules; stress specs |
| Conservative false retention | Size classes, layout, type_id gate, SP clamp, opt-in scrub; measure vs Boehm |
| Fiber / MT root bugs | Explicit registry; STW; SP clamp; CI samples |
| “Just make it precise” expectations | Precise is a separate epic — documented, not blocked |
| Platform divergence | `platform/` isolation; Darwin stubs; Linux CI x86_64 + aarch64 |

## Success bar

- **Correctness** — no UAF / lost objects under stress and dogfood.
- **Integration** — real Crystal apps under `-Dgc_none` without a compiler patch.
- **Performance** — Kemal-class thr and RSS near Boehm; fat-app gaps named and tracked.
- **Maintainability** — Crystal you can read; modules you can bisect.

## References

- [docs/INTEGRATION.md](docs/INTEGRATION.md) — Crystal 1.21 GC / fiber contract
- [docs/PERF.md](docs/PERF.md) — % of Boehm methodology
- [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md) — fat-app dogfood
- [docs/POLICY.md](docs/POLICY.md) — OOM / fork / signals
- [docs/COMPARISON.md](docs/COMPARISON.md) — vs bdwgc
- [docs/HARDENING.md](docs/HARDENING.md) — env knobs
- Crystal `src/gc.cr`, `gc/boehm.cr`, `gc/none.cr`
- Crystal PR abstracting LibGC / `gc_none` ([#5314](https://github.com/crystal-lang/crystal/pull/5314))
- [bdwgc](https://github.com/ivmai/bdwgc)
- Crystal blog: [Garbage Collector](https://crystal-lang.org/2013/12/05/garbage-collector/) (Boehm as a starting point toward a custom GC)
