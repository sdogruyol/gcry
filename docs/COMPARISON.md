# Comparison checklist — gcry vs bdwgc

**One-liner:** both are *conservative mark–sweep* collectors. gcry is Crystal-native STW-by-default; Boehm is the C library Crystal ships with (more platforms, MT/fork polish).

Scope: **Linux x86_64 + aarch64**, Crystal `>= 1.21`, default `Fiber::ExecutionContext` (parallelism 1).
Use this when evaluating gcry as a process GC (`require "gcry"` + `-Dgc_none`).

| Area | gcry (0.8.0) | bdwgc (Crystal default) |
|------|-----------------------------|-------------------------|
| Integration | Shard reopen of `GC` under `-Dgc_none` | Built-in `gc/boehm` |
| Language of core | Crystal | C |
| Collection model | Conservative STW mark–sweep (nursery / incremental opt-in only) | Conservative (BDW) |
| Fibers / ExecutionContext | STW other OS threads; fiber + stack roots | Yes (LibGC + thread bottoms) |
| Parallel fibers (multi OS thread) | Experimental (`GCRY_TLAB=1`; `GCRY_PARALLEL_MARK` measure-first — HTTP thr can regress) | Yes |
| Fork safety | **atfork reinit** (default; `LibC.fork`); `GCRY_DISABLE_ATFORK=1` poisons | `GC_set_handle_fork` |
| Finalizers | Same-thread, after collect | LibGC finalizers |
| Weak / disappearing links | Yes | Yes |
| Auto-collect knobs | `GCRY_THRESHOLD` (default 32 MiB), `GCRY_KEEP_CHUNKS`, `GCRY_INTERIOR`, … | LibGC env / APIs |
| Empty-chunk RSS | Release **default-on** (munmap outside STW) | LibGC reclaim |
| Mark filter | Base-pointer-only + root `type_id` gate + layout; STW SP clamp (`GCRY_DISABLE_SP_CLAMP=1`) | Interior pointers typical |
| Incremental | Opt-in `GCRY_INCREMENTAL=1` (experimental without barriers); default full STW | Yes (BDW) |
| Generational | Nursery without write barriers (opt-in) | Optional BDW modes |
| Compacting / moving | No | Mostly no (conservative) |
| Precise roots | No (needs compiler) | No |
| Platforms | Linux x86_64 + aarch64; macOS stubs | Broad |
| Unit-test mode | `Gcry::Heap` under Boehm | N/A |
| `prof_stats` | Heap / reclaim / explicit-free counters filled | Full LibGC fields |
| Kemal `/json` (same host) | thr ~**89%**; post-GC RSS ~**0.93×** — [PERF.md](PERF.md) | baseline |

## Smoke checklist (gcry)

Run before claiming app readiness:

- [ ] `crystal spec` green on Crystal `1.21.0` and `latest`
- [ ] `crystal build -Dgc_none samples/hello.cr` runs
- [ ] Alloc churn: `samples/alloc.cr` / `samples/stress.cr` under `-Dgc_none`
- [ ] Fibers that allocate survive without forced `GC.collect` every iteration
- [ ] `WeakRef` / finalizers behave on a small fixture if the app uses them
- [ ] RSS / pause acceptable vs Boehm on a representative workload (`bench/churn.cr` for library-heap; app bench for process GC)
- [ ] Prefer `fork`+`exec`, or rely on gcry atfork reinit for single-threaded children
- [ ] No GC calls from signal handlers
- [ ] Do **not** resize ExecutionContext for parallelism / add parallel contexts
- [ ] Avoid deprecated `-Dpreview_mt`

## When to stay on Boehm

- Need parallel ExecutionContexts / multi-thread STW
- Need `Process.fork` under ExecutionContext (Crystal itself forbids it; use `LibC.fork` + atfork or Boehm)
- Need battle-tested production defaults across OS targets
- Hard dependency on Boehm-specific `prof_stats` fields

## When gcry is a fit

- Want a Crystal-native collector to read, hack, and dogfood
- Default Crystal 1.21 runtime (ExecutionContext, parallelism 1) on Linux
- Willing to tune `GCRY_*` and accept conservative false retention
- Care about **RSS** on alloc-churn HTTP (Kemal post-GC RSS ≈ Boehm) more than last ~5–7% of Boehm thr
- Evaluating nursery / incremental mark without patching Crystal

## Phase 12 scope

Shard-only gcry can approach **Boehm-class RSS** on Kemal by returning empty chunks and tightening mark filters. Closing remaining conservative false retention on dense live heaps (e.g. acikturkiye ~3× post-GC RSS) needs better root precision or barriers — outside a pure shard. Layout tables, root-only `type_id` gating, and STW SP clamp were measured and do not close that gap.
