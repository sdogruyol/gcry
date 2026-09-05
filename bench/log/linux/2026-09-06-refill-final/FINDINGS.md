# Final refill implementation confirmation

These trials include both corrections found during review: stopped-world index lookup and publication of capacity freed behind an exhausted cursor. The generation uses release/acquire ordering so publication covers occupancy and ownership on weakly ordered CPUs.

Baseline is the medium-cursor allocator (`78f5ac7`). The candidate starts from the refill-only commit (`eca9fa4`) and applies `variant.patch`; it excludes the independent atomic enqueue optimization. Both use the same release/headerless `alloc_ns.cr`.

| Workload | Base ns/alloc | Final ns/alloc | Final/base cost, 95% CI | Null/base, 95% CI |
|---|---:|---:|---:|---:|
| growth-96mb | 67.6 | 62.5 | 92.57% [89.86, 95.27] | 99.11% [96.94, 101.27] |
| growth-960mb | 724.5 | 88.6 | 12.22% [10.41, 14.04] | 99.36% [97.29, 101.42] |
| 8k-atomic-mt | 7257.8 | 1939.4 | 26.78% [26.12, 27.44] | 101.03% [97.92, 104.15] |
| small-48 | 33.4 | 32.2 | 96.34% [95.82, 96.86] | 100.56% [100.12, 101.00] |

20 rotated paired rounds per case, fresh processes and a same-binary null. The
96/960 MB growth arms use four threads and `GCRY_DISABLE_AUTO=1`, and every
sample records zero collections. Final allocation cost falls by **87.8%**
[86.0, 89.6] at 960 MB, by **73.2%** [72.6, 73.9] on four-thread 8 KiB atomic
churn, and by **3.7%** [3.1, 4.2] on the one-thread 48-byte guard.

## Retirement correction

A free can restore a bit in a bitmap word that its owner's cursor already
passed. A second thread can then search the pool, exclude that still-owned
chunk, and cache absence. The old exhausted retirement did not invalidate that
cache, so subsequent allocations unnecessarily mapped fresh capacity.

The new two-thread regression reproduced this missed reuse. Retirement now
clears ownership and checks the retiring chunk for reusable capacity before
deciding whether to invalidate the class index. The check visits that chunk,
not the entire heap. All six refill regressions pass in both representations.
The full suites, process suites, ASan, STW properties/index race, fork and Darwin
type-check pass on the final code.

These results supersede the initial index prototype's numbers for the delivered
implementation. The original trials remain under `2026-09-06-refill-index`.
The final full headerless application comparison (including atomic enqueue
skipping) is recorded in `kemal/`; microbenchmarks alone do not
establish an HTTP throughput gain.

An existing background soak remained active on another checkout. No new
compilation or stress ran during the paired timings. Binary hashes, arguments,
environment and all samples are committed. Full stdout remains under
`/tmp/gcry-performance-raw/2026-09-06-refill-final`. Use the PR commit mapping
in `docs/PERFORMANCE_PR34_PROVENANCE.md` to resolve local measurement IDs.


## Final application result

20 paired rotated rounds, five seconds measured after one second warmup,
fresh headerless Kemal process per trial; base is the medium-cursor allocator,
null is its identical binary, candidate includes the completed refill index
and atomic enqueue check. All **60 trials completed without request errors**.
The recorded candidate collector/server source hashes match the final tree.

| Arm | Mean req/s | Throughput/base, 95% CI | Peak RSS/base | Faults/1k | CPU ms/10k requests |
|---|---:|---:|---:|---:|---:|
| base | 49,282 | 100% | 1.00 | 7.1 | 204.4 |
| null | 49,819 | 102.0% [95.3, 108.7] | 0.99 | 8.5 | 202.3 |
| final | 51,676 | 105.5% [99.4, 111.6] | 1.01 | 7.9 | 195.2 |

The final HTTP throughput result is **inconclusive**: +5.5%, CI −0.6 to +11.6.
The null also has a wide interval. Do not call this parity or an established
application throughput win. The strong allocation/graph improvements remain
workload-specific results. Peak RSS and fault rates show no large observed
shift in this session; this is not an equivalence test.

`kemal/` contains the full trial set, source/build/environment manifest, exact
dependency lock, runner snapshot, latency/GC supplement and analyzer output.
Raw server/wrk/GC files and binaries remain in `/tmp/gcry-final-refill-kemal`.
Use longer windows on an exclusive host for a narrower application conclusion.
