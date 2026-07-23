# Hardening notes (Phase 5)

## Stress coverage

| Suite | Mode | What it exercises |
|-------|------|-------------------|
| `spec/stress_spec.cr` | Library `Gcry::Heap` under Boehm | Alloc storms, pointer graphs, finalizer alloc, weak links, many `push_stack` ranges |
| `samples/stress.cr` | Process GC (`-Dgc_none`) | String churn, fibers, periodic `GC.collect` |

```sh
crystal spec
crystal build -Dgc_none samples/stress.cr -o bin/stress && ./bin/stress 300
```

## Process GC tuning

| Variable | Effect |
|----------|--------|
| `GCRY_THRESHOLD` | Bytes allocated since last major GC before auto-collect (default `4194304`) |
| `GCRY_DISABLE_AUTO=1` | Disables auto-collect (`threshold = UInt64::MAX`) |
| `GCRY_NURSERY` | Young bytes before minor collect (default `524288` under process GC) |
| `GCRY_DISABLE_NURSERY=1` | Disables nursery allocation / minor collections |

Process GC enables a **nursery** by default. Library `Gcry::Heap` leaves the nursery threshold at `UInt64::MAX` unless you set it. Call `GC.collect_a_little` explicitly for incremental major slices; auto-collect still runs a full major when the threshold hits.

`collect_a_little` under process GC pays a full static-root (`/proc/self/maps`) scan at the start of each incremental cycle — prefer library-heap benches (`bench/churn.cr`) for pause comparisons.

Example:

```sh
GCRY_THRESHOLD=1048576 crystal build -Dgc_none samples/alloc.cr -o alloc && ./alloc
GCRY_DISABLE_AUTO=1 crystal run -Dgc_none samples/hello.cr
GCRY_NURSERY=262144 ./bin/alloc 1000
GCRY_DISABLE_NURSERY=1 ./bin/stress 200
```

Auto-collect is suppressed while finalizers run (avoids nested collect).

OOM / fork / signals: [docs/POLICY.md](POLICY.md). Comparison checklist: [docs/COMPARISON.md](COMPARISON.md).

## False retention

gcry is **conservative**: any aligned word that looks like a heap pointer keeps that object alive.

Typical sources of extra retention:

- Stale pointers on the C stack (locals not overwritten)
- Integer / float bit patterns that alias pointers
- `/proc/self/maps` RW scans of libraries (broader than ideal; skips the managed heap)

Mitigations: nursery (young objects die faster), tighter static-root filters, precise stack maps (compiler work).

Rough check in process mode:

```crystal
before = GC.stats.heap_size
# drop references…
GC.collect
after = GC.stats.heap_size
```

`heap_size` may not shrink for small objects (chunks are retained); prefer `Gcry.default_heap.live_objects` in library tests or watch RSS over longer runs.

## Process GC notes (HTTP / fibers)

Crystal’s default **ExecutionContext** does not call `GC.set_stackbottom` on fiber swap. gcry refreshes the running fiber’s stack bottom at collect time from `Fiber.current.@stack.bottom`.

Static roots scan **file-backed** RW segments only (binary / `.so` data). Large anonymous maps (fiber stacks, arenas) are covered by `push_stack` / the mutator stack scan.

## Sanitizers

Crystal + ASan/Valgrind on a custom mmap GC is limited (false positives on intentional freelist reuse).

Practical checks:

```sh
crystal spec --error-trace
crystal build -Dgc_none --debug samples/stress.cr -o bin/stress
./bin/stress 200
```

CI runs format check, specs, `-Dgc_none` samples, env-knob smoke, and `bench/churn` on Linux x86_64 for Crystal `1.21.0` and `latest` (see `.github/workflows/ci.yml`).
