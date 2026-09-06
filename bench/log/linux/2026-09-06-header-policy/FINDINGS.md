# Header allocator: threshold × retention experiment

The benchmark applies policies to an existing header heap before work starts. All arms use the same release `-Dgc_none` binary, the main thread, a 64-slot ring of 8 KiB pointerful buffers, 5,000 warmup allocations, and 100,000 timed allocations. Each policy has 20 rotated paired rounds against the unchanged policy and an identical-binary/environment null.

| Policy | Candidate/base cost, 95% CI | Faults/1k allocations | Collections | Total pause, ms | Mapped heap after GC, MiB |
|---|---:|---:|---:|---:|---:|
| base | 100% | 1020.0 | 24 | 8.19 | 2.19 |
| warm | 101.13% [100.39, 101.86] | 1035.9 | 24 | 8.27 | 10.19 |
| adaptive | 121.18% [120.72, 121.64] | 1074.8 | 97 | 32.29 | 2.32 |
| coupled | 50.15% [49.75, 50.54] | 122.9 | 97 | 32.01 | 10.32 |

`warm` keeps the fixed 32 MiB threshold and enables a live-following warm budget.
`adaptive` enables only the live-following threshold (8 MiB here). `coupled`
enables both; base enables neither. The controls live in
`bench/performance/header_policy.cr`, required only by the benchmark programs.

The coupled policy halves total allocation cost (−49.9%, CI −50.3 to −49.5),
although it collects four times as often and spends about four times as long
in pauses. Refaults fall from about 1,020 to 123 per 1,000 allocations. Retention
alone does not improve refaults in this workload and costs +1.1% [0.4, 1.9]; the
smaller threshold alone costs +21.2% [20.7, 21.6]. The interaction is necessary.

The pause column does not isolate freelist relinking: it is an observed part of
the overall tradeoff, while elapsed allocation cost includes the post-STW work.
Mapped heap after collection is not RSS or peak RSS. The coupled policy holds
about 10.3 MiB here versus 2.2 MiB for base. Application peak and post-GC RSS,
CPU/request, latency and burst/drop behavior must decide default suitability.

## Default decision

No production header default is changed. The microbenchmark demonstrates a
promising coupled policy, not a portable application result. The maintained
Kemal factorial run follows separately; the plan additionally requires an
independent confirmation session and platform/workload gates before adopting a
default. Keep the simple live × factor rule; this experiment does not motivate
a more elaborate controller.

Reproduce by building `bench/micro/header_churn.cr` with
`crystal build --release -Dgc_none`, then running `micro_ab.py` with
`--base-env BENCH_HEADER_POLICY=base --candidate-env BENCH_HEADER_POLICY=<policy>`.
Use the per-case manifests for arguments and binary hashes. Samples and analyses
are committed; full stdout lives under `/tmp/gcry-performance-raw/2026-09-06-header-policy`.
The existing background soak remained running; no new stress/build load ran
during the paired measurements.


## Application follow-through

The [20-round Kemal factorial](../2026-09-06-kemal-policies/FINDINGS.md) confirms
lower peak RSS (−40.2%) and request p99 (−25.4%) for the coupled policy, with
far fewer refaults, but no established throughput change (CI −6.7 to +6.6%). Post-GC RSS rises 88.6%. Keep the production default decision deferred
until burst/drop/recovery and an independent session resolve this tradeoff.
