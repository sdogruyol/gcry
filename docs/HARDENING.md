# Hardening & knobs

Stress the collector. Tune process GC. Know where false retention comes from.

## Stress

| Suite | Mode |
|-------|------|
| `crystal spec` (+ `spec/stress_spec.cr`) | Library `Gcry::Heap` under Boehm |
| `samples/stress.cr` | Process GC (`-Dgc_none`) |

```sh
crystal spec
crystal build -Dgc_none samples/stress.cr -o bin/stress && ./bin/stress 300
# optional: side mark bitmap (higher RSS on Linux HTTP) — crystal build -Dgc_none -Dgcry_side_bitmap …
```

## Defaults that matter (process GC)

- Marks live in the **BlockHeader** (`MARK` flag). Side `MarkBitmap` mmap is **opt-in** (`-Dgcry_side_bitmap`) — Linux HTTP A/B: ~9× Kemal RSS vs ~1× header marks
- Majors: Linux **32 MiB**, Darwin **16 MiB**; **full STW**; nursery / incremental **off** (opt in `GCRY_NURSERY=1` / `GCRY_INCREMENTAL=1`)
- **Adaptive nursery threshold** when nursery is on (target survival 50%, clamped [64 KiB, 8 MiB]). Disable with `GCRY_DISABLE_ADAPTIVE_NURSERY=1`
- Empty chunks **released** (`GCRY_KEEP_CHUNKS=1` to retain); dormant retain budget: Linux **16 MiB**, Darwin **512 KiB**
- Base-pointer-only ambient roots; root **type_id** gate **on**; layout scan **on**; **SP clamp** **on**; page **blacklist** **on** (Linux + Darwin; `GCRY_DISABLE_BLACKLIST=1` to opt out)
- Fiber stack scrub **on** (Linux + Darwin; `GCRY_DISABLE_SCRUB_FIBERS=1` to opt out)
- Size-class chunk: library/Linux **128 KiB**; Darwin process **256 KiB** (`GCRY_CHUNK_BYTES` to override)
- Large-object freelist retain: Linux process **4 MiB**, Darwin **1 MiB** (`GCRY_LARGE_CACHE`; adaptive up to 32 MiB)
- Free-page physical release: Darwin **on** (`MADV_FREE_REUSABLE`); Linux HOLED **opt-in** (`GCRY_PAGE_DONTNEED=1` — measured thr+RSS regression as default). Escape: `GCRY_DISABLE_PAGE_RELEASE=1` / `GCRY_DISABLE_MADVISE=1`
- Auto-collect suppressed while finalizers run

Pauses: `Gcry.pause_stats`. HTTP: `GET /gc-stats`, `GET /gc-collect`, `GET /metrics` under `-Dgc_none`.

Raising `GCRY_THRESHOLD` cuts major count but grows pause p50 — measure on the real app before changing the default.

## Env reference

| Variable | Effect |
|----------|--------|
| `GCRY_THRESHOLD` | Bytes since last major (Linux default **32 MiB**; Darwin process **16 MiB**) |
| `GCRY_DISABLE_AUTO=1` | No auto-collect |
| `GCRY_NURSERY` | Opt-in nursery (bytes; default threshold **512 KiB** when enabled). Process GC default **off** |
| `GCRY_DISABLE_NURSERY=1` | Force nursery off |
| `GCRY_DISABLE_ADAPTIVE_NURSERY=1` | Use fixed nursery threshold (no auto-tuning) |
| `GCRY_SOFT_DIRTY_MAX` | Dirty/total % cap for soft-dirty scan (default **25**) |
| `GCRY_DISABLE_SOFT_DIRTY=1` | No soft-dirty |
| `GCRY_MPROTECT_BARRIER=1` | Force mprotect+SEGV barrier |
| `GCRY_DISABLE_MPROTECT=1` | Forbid mprotect |
| `GCRY_INCREMENTAL=1` | Sliced majors (+ dirty re-scan if barrier armed) |
| `GCRY_DISABLE_INCREMENTAL=1` | Full STW (process default) |
| `GCRY_INCREMENTAL_WORK` | Objects per slice (default **1024**) |
| `GCRY_STRESS=1` | Collect every N allocs (`GCRY_STRESS_EVERY`, default **16**) |
| `GCRY_KEEP_CHUNKS=1` | Retain empty chunks (higher thr / RSS) |
| `GCRY_RELEASE_CHUNKS=1` | Force empty release (already default-on) |
| `GCRY_EMPTY_CHUNK_RETAIN` | Dormant empty-byte budget (process: Linux **16 MiB**, Darwin **512 KiB**; library **0**) |
| `GCRY_PARALLEL_DORMANT=1` | Parallel: DONTNEED empties within retain (keeps post-STW lazy sweep) |
| `GCRY_PARALLEL_DORMANT_ALL=1` | Parallel: DONTNEED every empty (legacy; thr↓) |
| `GCRY_PARALLEL_RELEASE=1` | Parallel: munmap excess empties (forces in-STW sweep; can hang) |
| `GCRY_INTERIOR=1` | Interior pointers on ambient roots |
| `GCRY_PAGE_DONTNEED=1` | Sparse free-page release (Linux opt-in; Darwin process default-on) |
| `GCRY_DISABLE_PAGE_RELEASE=1` | Disable free-page reclaim (Darwin default-on; Linux if forced on) |
| `GCRY_LARGE_CACHE` | Large freelist retain (Linux process **4 MiB**; Darwin **1 MiB**; adaptive) |
| `GCRY_CHUNK_BYTES` | Chunk mmap size (library/Linux default **128 KiB**; Darwin process **256 KiB**) |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | Disable root type_id filter |
| `GCRY_DISABLE_LAYOUT=1` | Disable layout-precise scan |
| `GCRY_SCAN_CAPS=1` | Register `instance_sizeof` scan caps for all References (clips size-class padding; fat-app live set often unchanged) |
| `GCRY_DISABLE_AUTO_LAYOUTS=1` | When auto-layouts opted in: keep builtins only |
| `GCRY_AUTO_LAYOUTS=1` | Opt-in whole-program precise layouts (Linux Kemal `/json` thr cost ~7pp) |
| `GCRY_DISABLE_SP_CLAMP=1` | Full pthread range on other threads |
| `GCRY_STW_STACK_LAG` | Multi-mutator parked-fiber scan depth below `stack_top` (bytes; default **256 KiB**; `0` = full guard→bottom) |
| `GCRY_STW_PTHREAD_LAG` | Multi-mutator pthread scan from stack high when SP is on a fiber (bytes; default **256 KiB**; `0` = full map) |
| `GCRY_DISABLE_LAZY_SWEEP` | Force in-STW sweep (default: Parallel reclaim-off / TLAB-off sweeps after `start_world`) |
| `GCRY_BLACKLIST=1` | Force page blacklist on (already process default) |
| `GCRY_DISABLE_BLACKLIST=1` | No page blacklist |
| `GCRY_DISABLE_STATIC_ROOTS=1` | Skip dyld/ELF static root scan (debug; unsafe) |
| `GCRY_TLAB=1` | Thread-local freelists (parallel contexts) |
| `GCRY_ALLOC_BATCH=N` | TLAB-off: claim N (1..64) freelist nodes per lock; USED stash (lazy-safe) |
| `GCRY_CLEAR_STACK=1` | Unused-stack wipe on alloc (RSS experiment; every **16**) |
| `GCRY_CLEAR_STACK_BYTES` | Wipe size (default **4096**) |
| `GCRY_CLEAR_STACK_EVERY` | Wipe every N allocs |
| `GCRY_SCRUB_FIBERS=1` | Force fiber scrub on (already process default) |
| `GCRY_DISABLE_SCRUB_FIBERS=1` | Disable parked-fiber scrub |
| `GCRY_PARALLEL_MARK=N` | **Experimental** mark workers — HTTP thr often **regresses** |
| `GCRY_DISABLE_MADVISE=1` | Skip free-page physical release helpers |
| `GCRY_DISABLE_ATFORK=1` | No atfork; post-fork GC raises |
| `GCRY_DEBUG_INVARIANTS=1` | Runtime heap invariant checks |
| `GCRY_TRACE=1` | NDJSON GC event log (stderr or `GCRY_TRACE_FILE`) |
| `GCRY_TRACE_FILE` | Trace output path |
| `GCRY_TRACE_ALLOC_SAMPLE` | Log 1/N alloc/free lines (default **1000**; `0` = off) |

OOM / fork / signals: [POLICY.md](POLICY.md). Trace / heap dump: [API.md](API.md), `make trace-smoke`. Mutation scoring: [MUTATION.md](MUTATION.md).

## False retention

Conservative GC keeps any aligned word that **looks** like a heap pointer.

Common sources: stale stack slots, integer bit patterns, broad static scans.

Mitigations already on by default: empty-chunk release, base-ptr roots, type_id gate, layout builtins, SP clamp, blacklist, fiber scrub. Linux HOLED page release is opt-in (`GCRY_PAGE_DONTNEED=1`). Opt-in `GCRY_CLEAR_STACK=1` wipes **unused** stack on alloc — not stack maps. Closing dense-live RSS on fat apps needs the compiler.

### Diagnosing via `/gc-stats`

Per-source root reject counters tell you where false roots come from:

| Field | Source | When to act |
|-------|--------|-------------|
| `type_id_stack_rejects` | Fiber/mutator stacks | Stale slot; consider `GCRY_CLEAR_STACK=1` |
| `type_id_static_rejects` | BSS/data segments | Library has wide globals; no good fix at GC level |
| `type_id_thread_rejects` | Thread TLS | Worker stack slack; review thread count |
| `type_id_root_false_negatives` | Rejected roots later proved valid | **UAF risk**: gate is too strict, raise `1_000_000` upper bound |

`stack_rejects + static_rejects + thread_rejects == type_id_root_rejects`. Any non-zero `false_negatives` is a production alarm.

### Nursery survival metrics

| Field | Meaning | Tuning |
|-------|---------|--------|
| `nursery_survival_bytes` | Surviving payload from the last minor | High → grow threshold; low → shrink |
| `nursery_alloc_before_minor` | Nursery alloc bytes at the start of the last minor | Compare with survival_bytes for rate |
| `nursery_survival_rate_pct` | Moving-average survival rate (last 10 minors) | Target is 50%; >80% → threshold grows; <25% → shrinks |
| `adaptive_nursery` | Whether adaptive auto-tuning is active | Set via heap property or `GCRY_DISABLE_ADAPTIVE_NURSERY` |

```crystal
before = GC.stats.heap_size
# drop refs…
GC.collect
after = GC.stats.heap_size
```

Watch `unmapped_bytes` / RSS. Large objects (&gt;32 KiB) stay on a freelist through STW; excess trimmed after (`GCRY_LARGE_CACHE`).

## Process GC (HTTP)

ExecutionContext does not call `set_stackbottom` on swap — gcry refreshes from `Fiber.current` at collect. STW suspends other OS threads (Monitor included); without it, HTTP heaps corrupt under load.

Static roots: main executable RW (+ adjacent BSS); skip `.so` data and large RELRO. Fiber stacks scanned once per collect.

Parallel contexts: STW covers Crystal threads; `GCRY_TLAB=1` helps alloc; `GCRY_PARALLEL_MARK` is research — see [POLICY.md](POLICY.md).

## CI

Format, specs, `-Dgc_none` samples, env smoke, `bench/churn` on Linux x86_64 (Crystal 1.21 + latest). aarch64 native and `macos-latest` for STW/fork samples. See `.github/workflows/ci.yml`.
