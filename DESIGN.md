# gcry — Design

**A garbage collector Crystal can actually own.**

Crystal runs on [Boehm](https://github.com/ivmai/bdwgc) today. That works — and it also means the language’s most intimate runtime piece lives in C, behind a wall. **gcry** is the other path: a conservative mark–sweep collector written in Crystal, shipped as a shard, plugged in with `-Dgc_none`. No compiler fork. No waiting for upstream to grow a third backend.

This doc is the map: why the shape is what it is, how the pieces fit, and where the frontier is after **v0.20**.

---

## The bet

Crystal’s codegen and stdlib grew up around Boehm’s **conservative, non-moving** contract. Fighting that on day one (precise stacks, moving objects) means fighting the language. gcry takes the opposite route:

1. **Match the contract** — same `GC` surface, same pointer-shaped world.
2. **Win in Crystal** — readable hot paths, shard-speed iteration, real HTTP dogfood.
3. **Earn precision later** — stack maps and barriers are a compiler epic; the shard already carries everything that doesn’t need one.

As of **v0.20.0**, process GC runs on **Linux and macOS** (Crystal ≥ 1.21, no compiler fork). Linux Kemal (v0.16 carry): **`/json` ~87% of Boehm thr**, post-GC RSS **~0.80×**. macOS Kemal tip: **`/json` ~84%**, RSS **~1×**. Fat-app Linux tip ~**90–96%** thr @ ~**1–1.6×** RSS (finalizer + retain=0; was ~**3.43×** at v0.17); Darwin tip ~**98%** thr @ ~**0.97×** RSS at n=9 (2026-08-14 re-cut; was ~**18×** at v0.17, and the ~**0.63×** carried before does not reproduce) — see [docs/PERF.md](docs/PERF.md), [docs/PERF-macos.md](docs/PERF-macos.md), [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md). Stack maps ship dormant.

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
- Windows process GC parity (macOS process GC landed in v0.10; soft-dirty stays Linux-only).
- Being a general C malloc for non-Crystal programs.

## Principles

| Principle | Why |
|-----------|-----|
| **`GC` parity first** | Integration beats novelty; real programs unlock real bugs. |
| **Conservative before precise** | Matches today’s Crystal; precise is a separate epic. |
| **Allocation-free collect** | `mmap`, immortal arenas, stack buffers — never `GC.malloc` mid-mark. |
| **STW before concurrent** | Correct fiber / thread roots first; concurrency is opt-in and measured. |
| **Small modules** | Heap, roots, mark, sweep, platform — each testable in isolation. |
| **Measure, then ship defaults** | Empty-chunk release, type_id gate, SP clamp earned their defaults; parallel-mark stays experimental. A default is also *withdrawn* when the measurement stops supporting it — fiber scrub lost its on tip. |

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
  block.cr · size_classes.cr · tlab.cr · mark_bitmap.cr
  roots.cr · layout.cr · blacklist.cr · stack_scrub.cr · stack_maps.cr
  collect.cr                # orchestration
  collect_stw.cr · collect_scan.cr · collect_mark.cr · collect_sweep.cr
  mark.cr · parallel_mark.cr · barrier.cr
  finalizer.cr · metrics.cr · observability.cr · trace.cr · heap_dump.cr
  gc_override.cr            # module GC reopen
  thread_birth_root.cr      # root a Thread from pthread_create until it publishes
  unowned_stack_roots.cr · birth_grace.cr   # root arms, each with a no-op twin
  invariant.cr · mark_audit.cr · thread_block_audit.cr
  address_space_audit.cr · poison_holders.cr · ec_queue_audit.cr
  segv_report.cr · raw_out.cr · stw_watchdog.cr · monitor_gate.cr
  clock.cr · crystal_process_compat.cr
  platform/
    linux_stw.cr · linux_roots.cr · linux_stack.cr · linux_fork.cr
    linux_softdirty.cr · linux_mprotect.cr · linux_pagemap.cr
    linux_proc_sp.cr · linux_address_space.cr · linux_thread_census.cr
    darwin_stw.cr · darwin_roots.cr · darwin_stack.cr · darwin_stubs.cr
    thread_staging.cr       # both platforms
spec/ · process_spec/ · bench/ · samples/
```

The audit modules are **default-off diagnostics**, not collector path: each is
reached only through its own `GCRY_*` knob, each counts what it walked so a null
result cannot be an arm that never ran, and each is gated by a `make` target
that breaks it on purpose and requires the red.

## Where we are (v0.20)

Shipped and dogfooded on Linux + macOS. **v0.20.0 closes a use-after-free in
fiber creation**, and ships the instruments that found it. The missing root was
the stack of a fiber that is *ending*: `Thread#dying_fiber` parks it, the owning
`Fiber` is already off the fiber list, and the thread may still be running on
it — interleaved with poison on, **10/24 crashes → 0/24**, against a twin arm
that walks the same memory and offers nothing at **12/24**, plus a 5 h × 3 soak
clean (~52 000 collections, ~526 000 fibers, 0 errors). v0.19.0 closed the
suspended-register class on Darwin and Linux aarch64; v0.18.0 closed fat-app RSS
on the shard-only path. Stack maps stay **dormant**; Parallel TLAB-off + lazy
sweep stays a **supported opt-in**. Default path: EC parallelism **1**,
`GCRY_TLAB` **off** (the Linux Kemal headline still carries v0.16).

**The thread family is a different defect and is still open** — see
[Frontier](#frontier-after-020).

| Area | State |
|------|--------|
| Process GC via shard | ✅ `-Dgc_none` (stock Crystal ≥ 1.21) |
| Fibers + Monitor STW | ✅ SP clamp on x86_64 / aarch64; **dying-fiber stack rooted** (v0.20) |
| Thread birth window | ⚠️ `GCRY_STAGED_WAIT` **default-on** — the collector waits for a thread `pthread_create` has returned but Crystal has not published (crashes 6/60 → 0/60, census gaps 3/30 → 0/30, ~1.4% of collections wait at all); `thread_birth_root.cr` roots the `Thread` object across the same window. The second UAF that motivated both is **open** |
| Empty-chunk RSS | ✅ default-on — Kemal Linux ~**0.80×** Boehm (v0.16 carry); fat-app tip ~**1–1.6×** |
| Layout / type_id / blacklist | ✅ defaults + escapes |
| Barriers (soft-dirty / mprotect) | ✅; nursery **opt-in** (default off); soft-dirty Linux-only |
| Observability | ✅ metrics, Prometheus, json_stats, `GCRY_TRACE`, heap dump |
| Crash instruments | ✅ **default-off**, and each rides the gate that caught the defect it was built for: `GCRY_SEGV_REPORT`, `GCRY_POISON_FREED` / `_TAG` / `_HOLDERS`, `GCRY_MARK_AUDIT`, `GCRY_ADDRESS_SPACE_AUDIT`, `GCRY_THREAD_BLOCK_AUDIT`, `GCRY_THREAD_CENSUS`, `GCRY_EC_QUEUE_AUDIT` |
| Heap counters | ✅ flip to **atomic** the moment a second thread is created, before it can allocate — the plain path loses **5 723 of 1 200 000** at four threads, and a single-threaded program keeps the cheap one |
| Fork reinit | ✅ `pthread_atfork` (default) |
| Stack / fiber scrub | ⚠️ fiber scrub **opt-in** (`GCRY_SCRUB_FIBERS=1`; EC1 **4 KiB** blind, Parallel 512 B + safe) — it wipes below another fiber's *estimated* SP and no measurement supports the default it used to have; margin measured at **zero** on both ABIs (x86_64 clean through 56 B, aarch64 through 64 B); `GCRY_CLEAR_STACK` also opt-in |
| Parallel EC (TLAB-off + lazy) | ✅ **supported opt-in** — EC4 `/json` ~**79%** Boehm; TLAB-on / munmap still experimental — FINDINGS `2026-07-29-parallel-tlab-FINDINGS.md` |
| Parallel mark | ⚠️ experimental — HTTP thr often regresses |
| Test suite | ✅ invariants, property tests, process-STW MT (± TLAB ± nursery), ASan / Valgrind, musl, 5 h soak, nightly fuzz, and **12 purpose-broken `make` gates** across 9 CI jobs (see [TEST_PLAN.md](docs/TEST_PLAN.md)) |
| macOS process GC | ✅ Mach `thread_suspend` + dyld roots + `MADV_FREE_REUSABLE` (Crystal ≥ 1.21) |
| Compiler stack maps | ⚠️ machinery shipped **dormant** — not product default; see [STACK_MAPS.md](docs/STACK_MAPS.md) |

**Kemal Linux (v0.16.0 carry):** `/` ~**82%**, `/json` ~**87%**, post-GC RSS
~**0.80×** — [PERF.md](docs/PERF.md). The tip default-path re-cut (fiber scrub
off) lands `/json` **81.4%** @ **0.77×**, inside the ~80–85% band this host has
carried since v0.16, so **the headline does not move on three trials**.

**Kemal macOS (tip):** `/` ~**91%**, `/json` ~**84%**, post-GC RSS
~**0.95–1.01×** — [PERF-macos.md](docs/PERF-macos.md).

**acikturkiye:** Linux tip ~**90–96%** thr @ ~**1–1.6×** RSS —
[ACIKTURKIYE.md](docs/ACIKTURKIYE.md). Darwin tip ~**98%** @ ~**0.97×** at n=9
(2026-08-14 re-cut) — [ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md).

## v0.10 — macOS process GC

**Goal met and tagged:** `-Dgc_none` + `require "gcry"` runs real process GC on Darwin (arm64 + x86_64).

| Shipped | Deferred |
|---------|----------|
| Crystal Mach `thread_suspend` / resume STW + `thread_get_state` SP clamp | Soft-dirty (Linux-only) |
| `pthread_get_stackaddr_np` stack bounds | Full parity nursery / mprotect wins |
| dyld main-image `__DATA` / `__DATA_CONST` static roots | Windows |
| Host-page reclaim (now `MADV_FREE_REUSABLE` on Darwin) | Stack maps / fat-app RSS |
| CI: `macos-latest` native specs + samples | — |

Requires Crystal **≥ 1.21** (ExecutionContext Monitor + `Fiber#run` unlock pairing). Linux PERF re-cut completed in **v0.16.0**; Darwin Kemal re-cut in **v0.17.0**.

## Frontier (after 0.20)

| Track | Why it matters |
|-------|----------------|
| **The thread family — second UAF** | gcry reads a `Thread`'s `@system_handle` out of a block it has already freed, inside `stop_world`. The mechanism is named — the birth window, with the pre-stop wait *giving up* — and `thread_birth_root.cr` roots the object `GC.pthread_create` is already handed, changing nothing about the stopped world. The local gate is deterministic (20/20, window held open with a raw pthread); the CI rate is **not** decisive yet (9 green aarch64 reruns, Fisher p ≈ 0.2 against a 3/10 control on a bursty fleet). Open until CI has the runs to say so |
| **Stack maps / precise roots** | The only lever left for EC1 `/json` ≥95% @ ≤1.0× RSS — shard-only levers are **exhausted** (i3 + 9950X hunt MISS). Should end in a **decision** rather than an implementation: either precise roots pay measurably, or `GCRY_PRECISE_STACK` stays research and the target is restated — spike [docs/STACK_MAPS.md](docs/STACK_MAPS.md) |
| **Darwin low-water skip** | Linux took EC4 pause **8.06 → 3.60 ms** from it and Darwin takes none. Blocked on the `mach_vm_page_query` disposition bits, not on code: 4 of 5 arms hold on a Darwin host, and the one the soundness argument turns on — a page that leaves residency with its contents *intact* — is still INCONCLUSIVE because the runner will not compress |
| **Write barriers in codegen** | Sound concurrent / cheaper incremental — the precondition for nursery + incremental on by default |
| **Windows process GC** | `platform/` is `linux_*` / `darwin_*` only; the widest good-first-issue surface on the board |
| **Parallel+TLAB / munmap supported** | TLAB-off + lazy is a supported opt-in (~79%); TLAB-on + empty munmap still experimental — FINDINGS `2026-07-29-parallel-tlab-FINDINGS.md` |
| **Parallel contexts by default** | Only if TLAB + parallel-mark win thr |
| **Moving / compacting** | After precise roots |
| **Attribute the residual per-rep spread** | It bounds every perf claim either release makes: ±2–3pp on phase timings, ±1pp on post-GC RSS, at 12 reps |

Shard-only polish continues (Parallel thr/RSS, curated layouts, large-object page
policy). Darwin fat-app RSS closed on the tip re-cut without stack maps, as Linux
did in v0.18; what still wants them is the Kemal `/json` ceiling. Process-STW
property tests are no longer frontier — they run in CI on both architectures,
with TLAB and with nursery.

## Risks

| Risk | Mitigation |
|------|------------|
| Collector allocates from GC heap | Immortal arenas; hot-path rules; stress specs |
| Conservative false retention | Size classes, layout, type_id gate, SP clamp, fiber scrub; measure vs Boehm |
| Fiber / MT root bugs | Explicit registry; STW; SP clamp; thread staging + census; dying-fiber and thread-birth roots; CI samples |
| **A defect only CI can see** | Both recent use-after-frees were named by instruments rather than by reading the collector, and the open one has *never* reproduced locally. So the instruments ship: default-off, riding the gates that caught the defect, counting what they walked so a silence is readable, and each broken on purpose and observed red before its quiet is worth anything |
| “Just make it precise” expectations | Precise is a separate epic — documented, not blocked |
| Platform divergence | `platform/` isolation; Darwin real surface + soft-dirty stubs; CI Linux x86_64 + aarch64 + musl, macOS arm64 |

## Success bar

- **Correctness** — no UAF / lost objects under stress and dogfood.
- **Integration** — real Crystal apps under `-Dgc_none` without a compiler patch.
- **Performance** — Kemal-class thr and RSS near Boehm; fat-app gaps named and tracked.
- **Maintainability** — Crystal you can read; modules you can bisect.

## References

- [docs/INTEGRATION.md](docs/INTEGRATION.md) — Crystal 1.21 GC / fiber contract
- [docs/PERF.md](docs/PERF.md) — % of Boehm methodology (**Linux** cut)
- [docs/PERF-macos.md](docs/PERF-macos.md) — Darwin Kemal A/B (separate)
- [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md) — fat-app dogfood (Linux)
- [docs/ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md) — fat-app dogfood (Darwin)
- [docs/POLICY.md](docs/POLICY.md) — OOM / fork / signals
- [docs/COMPARISON.md](docs/COMPARISON.md) — vs bdwgc
- [docs/HARDENING.md](docs/HARDENING.md) — env knobs
- Crystal `src/gc.cr`, `gc/boehm.cr`, `gc/none.cr`
- Crystal PR abstracting LibGC / `gc_none` ([#5314](https://github.com/crystal-lang/crystal/pull/5314))
- [bdwgc](https://github.com/ivmai/bdwgc)
- Crystal blog: [Garbage Collector](https://crystal-lang.org/2013/12/05/garbage-collector/) (Boehm as a starting point toward a custom GC)
