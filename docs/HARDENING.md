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
```

## Defaults that matter (process GC)

- Majors at **32 MiB**, **full STW**, nursery **off**
- Empty chunks **released** (`GCRY_KEEP_CHUNKS=1` to retain)
- Base-pointer-only ambient roots; root **type_id** gate **on**; layout scan **on**; **SP clamp** **on**; page **blacklist** **on**
- Auto-collect suppressed while finalizers run

Pauses: `Gcry.pause_stats`. HTTP: `GET /gc-stats`, `GET /gc-collect`, `GET /metrics` under `-Dgc_none`.

Raising `GCRY_THRESHOLD` cuts major count but grows pause p50 — measure on the real app before changing the default.

## Env reference

| Variable | Effect |
|----------|--------|
| `GCRY_THRESHOLD` | Bytes since last major (default **32 MiB**) |
| `GCRY_DISABLE_AUTO=1` | No auto-collect |
| `GCRY_NURSERY` | Opt-in nursery (HTTP usually too dirty) |
| `GCRY_DISABLE_NURSERY=1` | Force nursery off |
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
| `GCRY_EMPTY_CHUNK_RETAIN` | Dormant empty bytes via `MADV_DONTNEED` (default **0**) |
| `GCRY_INTERIOR=1` | Interior pointers on ambient roots |
| `GCRY_PAGE_DONTNEED=1` | Sparse free-page DONTNEED |
| `GCRY_LARGE_CACHE` | Large freelist retain (default **8 MiB**) |
| `GCRY_CHUNK_BYTES` | Chunk mmap size (default **256 KiB**) |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | Disable root type_id filter |
| `GCRY_DISABLE_LAYOUT=1` | Disable layout-precise scan |
| `GCRY_AUTO_LAYOUTS=1` | `register_layouts` at init (measure thr) |
| `GCRY_DISABLE_SP_CLAMP=1` | Full pthread range on other threads |
| `GCRY_DISABLE_BLACKLIST=1` | No page blacklist |
| `GCRY_TLAB=1` | Thread-local freelists (parallel contexts) |
| `GCRY_CLEAR_STACK=1` | Unused-stack wipe on alloc (RSS experiment; every **16**) |
| `GCRY_CLEAR_STACK_BYTES` | Wipe size (default **4096**) |
| `GCRY_CLEAR_STACK_EVERY` | Wipe every N allocs |
| `GCRY_SCRUB_FIBERS=1` | Capped parked-fiber wipe before mark |
| `GCRY_PARALLEL_MARK=N` | **Experimental** mark workers — HTTP thr often **regresses** |
| `GCRY_DISABLE_MADVISE=1` | Skip `MADV_DONTNEED` |
| `GCRY_DISABLE_ATFORK=1` | No atfork; post-fork GC raises |

OOM / fork / signals: [POLICY.md](POLICY.md).

## False retention

Conservative GC keeps any aligned word that **looks** like a heap pointer.

Common sources: stale stack slots, integer bit patterns, broad static scans.

Mitigations already on by default: empty-chunk release, base-ptr roots, type_id gate, layout, SP clamp, blacklist. Opt-in scrub (`GCRY_CLEAR_STACK` / `GCRY_SCRUB_FIBERS`) wipes **unused** stack only — not stack maps. Closing dense-live RSS on fat apps needs the compiler.

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
