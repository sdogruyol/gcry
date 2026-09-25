# The Darwin low-water skip: EC4 pause 9.05 → 3.06 ms, and 27% less RSS

**Date:** 2026-09-25 · host: GitHub `macos-latest`, Apple M1 (Virtual), 3 vCPU,
16 KiB pages · tree `6b7b45b` · Crystal 1.21.0, `--release`,
`-Dpreview_mt -Dexecution_context`, **EC parallelism 4** (6 server threads).
Kemal `/json`, `wrk -c100 -d20`, 9 reps per config, interleaved and rotated.
CI run `36186838737`, job "darwin EC4 root-phase cut"
(`darwin_root_phase_reps=9`).

This prices the skip that `src/gcry/platform/darwin_low_water.cr` brought to
macOS the same day, the same way `../../linux/2026-08-09-104417-root-phase/`
priced it on Linux: `tuned` is the default, `tuned-nolw` is
`GCRY_STACK_LOW_WATER=0`.

## Result

| config | n | roots µs | stacks µs | mark µs | sweep µs | pause ms | Δ pause | post-GC RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `tuned` | 1251 | 2302 | 124 | 313 | 181 | **3.06** | — | **92.9 MB** |
| `tuned-nolw` | 1311 | 8028 | 278 | 321 | 371 | 9.05 | **+196%** | 126.5 MB (+36%) |

IQR 14.8% and 16.9%, both inside the harness's 50% comparability bound.

The skip engaged, and only where it was meant to: every `tuned` rep reports
`low_water_skips` 11 and `low_water_skipped_bytes` 2 678 320; every
`tuned-nolw` rep reports 0 and 0.

## Reading

**Pause.** Root work falls 8306 → 2426 µs and `mark` is unchanged (313 / 321),
which is the shape a root-scan change should have. It is the Linux result
again: 8.06 → 3.60 ms there, 9.05 → 3.06 ms here.

**RSS: this part is new.** On Linux the same A/B was flat (+0.2%). Here the
control is 33.6 MB larger, and the heap accounts for only 10 MB of that:
`small_mapped_bytes` 99.9 → 109.8 MB with `size_class_live_bytes` equal
(6.86 MB in both). That leaves about **23 MB outside the heap**.
`[INFERENCE]` It is fiber-stack pages the scan faulted in. On Linux, reading an
untouched anonymous page maps the shared zero page and costs no RSS. The
ROADMAP's Darwin note — "macOS still faults the whole lag window per parked
fiber" — says that is not true here. This run has no page-level count to prove
it: no residency reading of the fiber stacks before and after a scan.

## What this does not say

- **Nothing about EC1.** At EC1 the lag branch cannot run (`thread count > 2`
  gates it), as on Linux.
- **Nothing about throughput.** This measures per-collection pause
  composition and post-GC RSS; the collection count differs by rep with load.
- **One runner, one day.** `macos-latest` is a 3-vCPU VM, and its
  perf-smoke spread is wide (sd 18 pp on `/json` throughput). The pause
  ratio is far outside that spread. The RSS arms do not overlap at all: the
  largest `tuned` rep (117 536 KiB) is below the smallest `tuned-nolw` rep
  (117 728 KiB).

Re-run: dispatch CI with `darwin_root_phase_reps=N` (`soak_duration=0`).
