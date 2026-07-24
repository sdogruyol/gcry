# gcry vs Boehm

Both are **conservative mark–sweep**. gcry is Crystal-native, STW-by-default, shipped as a shard. Boehm is the C library Crystal ships with — broader platforms, more MT polish.

**Scope for this checklist:** Linux x86_64 + aarch64 and macOS arm64 + x86_64, Crystal ≥ 1.21, parallelism **1**, `require "gcry"` + `-Dgc_none`.

## Head-to-head

| | gcry (0.9.0) | Boehm (Crystal default) |
|--|--------------|-------------------------|
| Integration | Shard reopen under `-Dgc_none` | Built-in `gc/boehm` |
| Core language | **Crystal** | C |
| Model | Conservative STW (nursery / incremental opt-in) | Conservative BDW |
| Fibers | STW + fiber / stack roots + SP clamp | LibGC + thread bottoms |
| Parallel OS threads | Experimental (measure — HTTP thr can drop) | Yes |
| Fork | atfork reinit (default) | `GC_set_handle_fork` |
| Finalizers / WeakRef | Yes (same-thread after collect) | Yes |
| Empty-chunk RSS | Release **default-on** | LibGC reclaim |
| Root filters | Base-ptr + type_id gate + layout + SP clamp | Interior-friendly |
| Precise / moving | No (needs compiler) | No |
| Platforms | Linux + macOS (soft-dirty Linux-only) | Broad |
| Kemal `/json` | thr ~**92%**, post-GC RSS ~**0.97×** — [PERF.md](PERF.md) | baseline |

## Pick gcry when

- You want a collector you can **read and change** in Crystal
- Linux + default ExecutionContext (parallelism 1)
- Kemal-class thr/RSS near Boehm is the bar — and you’re hitting it
- You’re OK tuning `GCRY_*` and naming conservative retention honestly

## Stay on Boehm when

- Parallel ExecutionContexts in production
- Windows process GC today; Darwin soft-dirty / nursery parity
- You need `Process.fork` under ExecutionContext (Crystal forbids it either way)
- You want zero-experiment production defaults across OS targets

## Smoke before you claim readiness

- [ ] `crystal spec` green
- [ ] `crystal build -Dgc_none samples/hello.cr` runs
- [ ] `samples/stress.cr` under `-Dgc_none`
- [ ] Fibers allocate without forced collect every loop
- [ ] WeakRef / finalizers OK if the app uses them
- [ ] Same-host wrk vs Boehm on a real path ([PERF.md](PERF.md))
- [ ] No GC from signal handlers; prefer fork+exec
- [ ] Do not resize ExecutionContext for parallelism without measuring

## The RSS ceiling

Shard-only gcry reaches **Boehm-class RSS on Kemal**. Dense live heaps (e.g. acikturkiye ~**2.8×** post-GC RSS) stay thicker — layout, type_id gate, and SP clamp were measured; they don’t close that gap. Next lever is **compiler stack maps**, not another env flag. Field notes: [ACIKTURKIYE.md](ACIKTURKIYE.md).
