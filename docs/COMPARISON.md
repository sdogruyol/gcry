# Comparison checklist — gcry vs bdwgc

Scope: **Linux x86_64**, Crystal `>= 1.21`, single-threaded + fibers (no `preview_mt`).
Use this when evaluating gcry as a process GC (`require "gcry"` + `-Dgc_none`).

| Area | gcry (v0.1) | bdwgc (Crystal default) |
|------|-------------|-------------------------|
| Integration | Shard reopen of `GC` under `-Dgc_none` | Built-in `gc/boehm` |
| Language of core | Crystal | C |
| Collection model | Conservative mark–sweep + nursery + incremental mark slices | Conservative (BDW) |
| Fibers | `before_collect` → `push_gc_roots` / `push_stack` | Yes |
| Multi-thread (`preview_mt`) | No | Yes |
| Fork safety | **Unsupported** (documented) | `GC_set_handle_fork` |
| Finalizers | Same-thread, after collect | LibGC finalizers |
| Weak / disappearing links | Yes | Yes |
| Auto-collect knobs | `GCRY_THRESHOLD`, `GCRY_DISABLE_AUTO`, `GCRY_NURSERY`, `GCRY_DISABLE_NURSERY` | LibGC env / APIs |
| Incremental | `collect_a_little` (work-budget mark) | Yes (BDW) |
| Generational | Nursery without write barriers | Optional BDW modes |
| Compacting / moving | No | Mostly no (conservative) |
| Precise roots | No (needs compiler) | No |
| Platforms | Linux x86_64 first | Broad |
| Unit-test mode | `Gcry::Heap` under Boehm | N/A |

## Smoke checklist (gcry)

Run before claiming app readiness:

- [ ] `crystal spec` green on Crystal `1.21.0` and `latest`
- [ ] `crystal build -Dgc_none samples/hello.cr` runs
- [ ] Alloc churn: `samples/alloc.cr` / `samples/stress.cr` under `-Dgc_none`
- [ ] Fibers that allocate survive without forced `GC.collect` every iteration
- [ ] `WeakRef` / finalizers behave on a small fixture if the app uses them
- [ ] RSS / pause acceptable vs Boehm on a representative workload (`bench/churn.cr` for library-heap; app bench for process GC)
- [ ] No `fork` without `exec` after boot
- [ ] No GC calls from signal handlers
- [ ] Confirm `-Dpreview_mt` is **not** enabled

## When to stay on Boehm

- Need `preview_mt` / multi-thread STW
- Process forks and continues running Crystal in the child
- Need battle-tested production defaults across OS targets
- Hard dependency on Boehm-specific `prof_stats` fields

## When gcry is a fit

- Want a Crystal-native collector to read, hack, and dogfood
- Single-threaded (or fiber-only) Linux services
- Willing to tune `GCRY_*` and accept conservative false retention
- Evaluating nursery / incremental mark without patching Crystal
