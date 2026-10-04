# Revcomp: large buffers grow by mapping, faulting and copying

crystal-metric Revcomp is 73% of Boehm's speed on the Linux CI runner and
~88% locally, the one benchmark below 85% on Linux besides Primes,
JsonParsePure and Binarytrees (`../2026-10-03-crystal-metric-cross-platform/`).
Its peak RSS is 0.63–0.68× Boehm's.

## Measured (Linux x64, local, 5 runs, medians)

| arm | time | minor faults | peak RSS |
|---|---:|---:|---:|
| Boehm | 0.672 s | 225 789 | 884 MiB |
| gcry | 0.765 s | 388 453 | 559 MiB |
| gcry, `GCRY_LARGE_CACHE=64 MiB` | 0.752 s | 387 966 | 560 MiB |
| gcry, `GCRY_LARGE_CACHE=256 MiB` | 0.754 s | 386 940 | 560 MiB |
| gcry, `GCRY_KEEP_CHUNKS=1` (3 runs) | 0.737 s | 372 026 | 561 MiB |
| gcry, `GCRY_DISABLE_MADVISE=1` (3 runs) | 0.800 s | 388 453 | 559 MiB |

The extra ~160 000 faults are large objects. `GCRY_TRACE_LARGE=1`
(`trace-large.txt`): 49 large mappings, 1 390 MiB in all — three doubling
sequences from 64 KiB to 126 MiB, the `IO::Memory` / `String::Builder` growth
of the benchmark's buffers. Every step is a `GC.realloc` that maps a fresh
chunk, faults it in and copies the old contents; the old chunk is freed at the
next sweep. Neither cache size moves the count: no two steps share a mapped
size, and `take_large_free` reuses only an exact match (by design: a larger
cached mapping would pin its excess for the object's life).

## Why it is not a one-line change

Growing in place (`mremap` without `MREMAP_MAYMOVE`) keeps the address, so
the old pointer stays valid, but it needs free address space above the chunk,
and Linux places mappings top-down, so that space is usually an older
mapping. Moving (`MREMAP_MAYMOVE`) unmaps the old address at once, which
`realloc_owned` forbids for a reason it spells out: Crystal stores the result
only after `realloc` returns, and until then the owner's field still holds
the old pointer. It would also have to move the chunk's index, radix and
chunk-list registration under the collector's feet. A reservation of address
space past each large chunk would make in-place growth succeed; that is a
mapping-policy change with its own VA and fragmentation questions.

## Why a bigger cache does not help either

With `GCRY_LARGE_CACHE=268435456` the run maps 38 chunks instead of 49 and
takes the same faults (`trace-large-cache256.txt`). The trace says why: each
doubling chain runs inside one collection epoch (`coll=8`: 4, 8, 16, 32 MiB
back to back). The block a step outgrows is garbage at once, but the cache
only receives it at the next sweep, so no step of a chain can reuse the one
before it; only a later chain can, and only at a size that matches exactly.

Boehm's `GC_realloc` frees the old object on the spot (`GC_free` after the
copy, `mallocx.c`), which is what lets its next step reuse the block. gcry
does not, on purpose: `realloc_owned` documents a Parallel-EC SEGV from
exactly that — the owner's field still held the old pointer until `realloc`
returned, and a peer reused the block in between. So the reuse route is
closed by a safety rule, and growth in place is the route that keeps the old
pointer valid.

## Doubling the request on large growth: −3%, not worth it

`realloc` passing `allocate` twice the size for a large block (a local
experiment, not committed) lets every other doubling step take the
`new_size <= old_size` return. Three runs each, with a campaign on the
host: 2.75-2.77 → 2.65-2.68 s, minor faults 388 458 → 339 862 (−12%), peak RSS
572-586 → 520-650 MB. It closes 48 000 of the ~160 000 extra faults, and it
does so by recording twice the size in the large header, which every
live-bytes count and threshold then reads. Not pursued.

Open in ROADMAP.md.
