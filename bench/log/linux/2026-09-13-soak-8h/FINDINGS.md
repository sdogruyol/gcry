# Eight hours, flat: the soak's RSS envelope and pause distribution

Date: 2026-09-13/14 (overnight, 8 h) · host: AMD Ryzen AI 9 465, Linux 7.2.4 ·
tree: `730e774` · `make soak` with `SOAK_DURATION=28800`, telemetry
`/tmp/gcry-soak.log`

Result: **PASS**. 28 743 collections, 28 646 010 allocations, 287 459 fibers,
2 870 315 finalizable objects, **0 queue faults**, start RSS 7 024 kB, end RSS
**7 800 kB**.

## The envelope

| hour | RSS kB | live objects | collections | pause p50 | pause p99 | p99 max |
|---|---|---|---|---|---|---|
| 0 | 7940 | 3026 | 3587 | 1801.90 ms | 2953.07 ms | 9473.52 ms |
| 1 | 7952 | 2906 | 3593 | 1818.41 ms | 2748.74 ms | 4309.05 ms |
| 2 | 7956 | 2885 | 3593 | 1771.53 ms | 2765.67 ms | 3578.04 ms |
| 3 | 7956 | 2919 | 3593 | 1809.34 ms | 2749.39 ms | 3579.57 ms |
| 4 | 7956 | 2880 | 3593 | 1778.22 ms | 2732.88 ms | 4062.41 ms |
| 5 | 7956 | 2910 | 3593 | 1769.51 ms | 2795.11 ms | 3214.10 ms |
| 6 | 7956 | 2921 | 3593 | 1759.49 ms | 2733.89 ms | 4976.38 ms |
| 7 | 7956 | 2898 | 3593 | 1733.70 ms | 2759.04 ms | 3674.63 ms |
| 8 | 7956 | 3492 | 5 | 1699.19 ms | 2921.02 ms | 2921.02 ms |

RSS reaches 7 956 kB in hour 2 and **does not move again** — every sample from
hour 2 to hour 7 reads 7 956, and the drain at the end gives 156 kB back. The
+932 kB from start to plateau is warm-up, not a slope: an average of 127 kB/h
across the run describes a curve that is flat for six of its eight hours.

The pause does not grow with uptime either: p50 1.80 ms in hour 0 and 1.76 ms in
hour 6, p99 between 2.73 and 2.95 ms throughout. The only outlier is hour 0's
9.47 ms p99 maximum, which is warm-up — every later hour's maximum is 3.2 to
5.0 ms. Live objects hold at ~2 900 and collections at 3 593/hour, so this is a
steady state rather than a workload that wound down.

## What this does and does not say

It says the collector holds an 8-hour steady state on this workload with no RSS
slope, no pause drift and no queue corruption — the three things the soak
exists to catch. `queue_faults` staying 0 across 287 459 fibers is the
`ec_queue_audit` question answered for this arm.

It does not speak for the EC4 pause item: that one is about Kemal `-c100` with
many parked fibers, where 8.4 ms of a 9.2 ms p50 is the fiber-stack scan. This
workload's p50 is 1.8 ms and its parked-fiber population is small, which is why
the lag measurement tonight needed its own harness
(`bench/log/linux/2026-09-13-fiber-lag-cost/FINDINGS.md`).

Nor does it speak for the chunk-release window found the same night: the sweep
queues empties only on its single-mutator path, and this soak is
multi-threaded throughout (`bench/log/linux/2026-09-14-occupied-release/`).
