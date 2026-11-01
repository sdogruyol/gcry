# gcry vs Boehm

Both are **conservative mark–sweep**. gcry is Crystal-native, STW-by-default, shipped as a shard. Boehm is the C library Crystal ships with — broader platforms, more MT polish.

**Scope for this checklist:** Linux x86_64 + aarch64, macOS arm64 + x86_64, Windows x86_64 + ARM64 ([WINDOWS.md](WINDOWS.md)), Crystal ≥ 1.21, parallelism **1**, `require "gcry"` + `-Dgc_none`.

## Head-to-head

Snapshot of gcry **0.39.0** (`shard.yml`, 2026-10-27): sound defaults, parallel mark on by default, Boehm's `GC_*` C ABI, in-place large `realloc`, batched mark with small objects scanned in the batch loop, the occupancy claim, the slow-path stack wipe, and the fixes in `CHANGELOG.md`. Every number is quoted from the README, with its source.

| | gcry (0.39.0) | Boehm (Crystal default) |
|--|---------------|-------------------------|
| Integration | Shard reopen under `-Dgc_none` | Built-in `gc/boehm` |
| Core language | **Crystal** | C |
| Model | Conservative STW, headerless layout, parallel mark above 32 MiB live (nursery / incremental opt-in, header layout only for the nursery) | Conservative BDW, parallel mark |
| Roots | Interior + misaligned ambient roots, static roots, whole touched fiber/thread stacks, SP clamp; **no root heuristic on by default** since 2026-10-05 ([SOUND-DEFAULTS.md](SOUND-DEFAULTS.md)) | Interior-friendly |
| Object bodies | Every non-atomic block word-scanned; no type map (`Gcry::Layout` removed in 0.36.0) | Conservative |
| Parallel OS threads | **Supported opt-in:** EC>1 + TLAB **off** + lazy sweep (~79% `/json`, [POLICY.md](POLICY.md)); TLAB-on **unsupported** | Yes |
| Fork | atfork reinit (default) | `GC_set_handle_fork` |
| Finalizers / WeakRef | Yes (same-thread after collect) | Yes |
| Empty-chunk RSS | Released by default | LibGC reclaim |
| Precise / moving | No (needs compiler) | No |
| Platforms | **Linux, macOS, Windows** (x86_64 and arm64; soft-dirty Linux-only); other targets fail at compile time (`src/gcry/platform/os.cr`). Windows workloads measured on x86_64 in VMs only (a 12-vCPU QEMU VM, GitHub's `windows-latest` runner), ARM64 unmeasured ([WINDOWS.md](WINDOWS.md)); Linux arm64 measured on GitHub's `ubuntu-24.04-arm` runner, macOS x86_64 on `macos-15-intel` (`bench/log/{linux,macos}/2026-11-01-0.40-runners/`) | Broad |
| Boehm C ABI | The surface Crystal uses; differences in [INTEGRATION.md § Boehm parity](INTEGRATION.md#boehm-parity) | Full |
| Crystal `spec/std` | **18 054 / 18 054** pass (1.21.0, Linux x86_64) and 18 257 on 1.22.0 (CI run 38721725009), CI job `std-spec` (`ci/std-spec.sh`); not run on macOS or Windows | 18 054 / 18 054 |
| Kemal `/json`, Linux | **106.8%** thr at **1.24×** peak RSS (0.40.0, 2026-11-01, one quiet session; 0.39.0 in the same session 104.4%, 1.24× — `bench/log/linux/2026-11-01-0.40-linux-host/`; on the 4-vCPU `ubuntu-latest` runner 0.40.0 is at 103.8% [100.1, 106.6], paired −1.3% [−4.0, +0.9] against 0.39.0 — `bench/log/linux/2026-11-01-0.40-runners/`); 0.88× after `GC.collect` (2026-10-06) | baseline |
| Kemal `/json`, Windows x86_64 (VM) | **106.5%** thr at 1.14× peak working set — `bench/log/windows/2026-10-06-vm-validation/` | baseline |
| crystal-metric, Windows x86_64 (`windows-latest`) | **95–120%** of Boehm's speed, peak working set 0.43–0.93× on 7 of 9 rows (JsonParsePure 1.07×, Knuckeotide 1.19× [1.18, 1.66]) (0.40.0, 2026-11-01; 0.39.0 in the same run: 96–119%, Knuckeotide 1.57×; seven rows 1.4–7.3% slower in wall time, Revcomp the largest, all code placement: 0.39.0 at each of 0.40.0's four 16-byte code phases reads its time in one session — `bench/log/windows/2026-11-02-0.40-win-rows/`) — `bench/log/windows/2026-11-01-0.40-runners/` | baseline |
| Kemal `/json`, macOS arm64 (`macos-latest`) | **105.2%** [96.9, 110.6] thr at **1.38×** peak RSS (0.40.0, 2026-11-01; 0.39.0 in the same run: 100.2%, 1.40×, paired +3.9% [−8.8, +9.3]); `/` 104.0% [92.2, 114.7], paired +1.9% [−5.2, +7.7] — `bench/log/macos/2026-11-01-0.40-runners/`; peak *footprint* on the 2026-09-06 laptop cut: 1.50×, 0.99× post-GC | baseline |
| crystal-metric, macOS arm64 (`macos-latest`) | **98–109%** of Boehm's speed on 7 of 9 rows (Binarytrees 93%, Knuckeotide 91%), peak RSS 0.43–0.94× on 8 of 9 (JsonGenerate 0.64×, from 0.74×; Knuckeotide 1.32×) (0.40.0, 2026-11-01; none slower than 0.39.0 beyond the spread) — same directory | baseline |
| Linux arm64 (`ubuntu-24.04-arm`) | crystal-metric **90–102%** of Boehm's speed on all 9 rows (JsonParsePure 93%; Binarytrees 96%; Knuckeotide 90%), peak RSS 0.42–0.93× on 7 of 9 (JsonParsePure 1.07×, Knuckeotide 1.13×); JsonGenerate +1.1% wall against 0.39.0, a fifteenth collection (`bench/log/linux/2026-11-01-0.40-keep-rule/` §4); Kemal `/json` **107.4%** [105.1, 109.7] at 1.32× (0.40.0, 2026-11-01; 0.39.0 in the same run: 103.0%, paired +7.3% [+0.2, +8.0]) — `bench/log/linux/2026-11-01-0.40-runners/` | baseline |
| Kemal, CI perf smoke (v0.34.0) | Linux `/json` 104.8%, `/` 100.8%, peak RSS 0.96×; macOS `/json` 106.4%, 1.13× — medians, [leaderboard](../bench/leaderboard.md) | baseline |
| Fat app `/api/v1/`, Linux | 90.8% thr at 1.55× RSS (header layout, 0.24.0) — [ACIKTURKIYE.md](ACIKTURKIYE.md) | baseline |
| Cost of the sound defaults | EC4 Linux pause 3.07 → 4.55 ms, req/s unchanged; EC1 unchanged; macOS pause ~1.22–1.25× (CI, 2026-09-26, `bench/sound_matrix.py`) | — |

The fat-app rows were measured while the 256 KiB STW stack lags were still the default; the last row is what removing them costs.

## Pick gcry when

- You want a collector you can **read and change** in Crystal
- Linux, macOS or Windows + default ExecutionContext (parallelism 1)
- Kemal-class throughput and RSS near Boehm is the bar
- You're OK tuning `GCRY_*` and naming conservative retention honestly

## Stay on Boehm when

- You need Parallel EC **with TLAB** or empty-chunk munmap under EC>1 (unsupported in gcry)
- You target anything outside Linux, macOS and Windows on x86_64 / aarch64
- Your workload grows large buffers in a hot loop and wall time is the bar: gcry runs Revcomp at 97% of Boehm's speed on 12-CPU Linux x86_64 (0.40.0, `bench/log/linux/2026-11-01-0.40-linux-host/`; below Boehm by where the allocation entry lands in the binary, at the same address as in 0.39.0, which ran at 96% — `bench/log/linux/2026-10-31-revcomp-host-placement/`), 95% on Windows x86_64 (7.3% slower than 0.39.0 there, where `Revcomp#revcomp` lands, a 16–19% band both releases share — `bench/log/windows/2026-11-02-0.40-win-rows/`) and 99% on macOS arm64 (0.40.0, `bench/log/{windows,macos}/2026-11-01-0.40-runners/`); JsonParseSerializable, which used to trail too, is at 101–106% on those three since in-place `realloc` growth
- You need `Process.fork` under ExecutionContext (Crystal forbids it either way)

Secondary CLI shapes (tree/JSON/channel): vendored crystal-metric GC subset —
[PERF.md](PERF.md) "Secondary suite"; not a Boehm replacement claim.

## Smoke before you claim readiness

- [ ] `crystal spec` green
- [ ] `crystal build -Dgc_none samples/hello.cr` runs
- [ ] `samples/stress.cr` under `-Dgc_none`
- [ ] Fibers allocate without forced collect every loop
- [ ] WeakRef / finalizers OK if the app uses them
- [ ] Same-host wrk vs Boehm on a real path ([PERF.md](PERF.md) Linux; [PERF-macos.md](PERF-macos.md) Darwin)
- [ ] No GC from signal handlers; prefer fork+exec
- [ ] Parallel: resize EC only with TLAB **off**; measure vs Boehm ([PERF.md](PERF.md) Parallel opt-in)

## The RSS ceiling

Kemal `/json` on the headerless default sits at 1.24× Boehm's peak RSS on Linux (0.40.0, `bench/log/linux/2026-11-01-0.40-linux-host/`) and 0.88× after `GC.collect` (2026-10-06), and 0.96× in the CI perf smoke; on macOS 0.40.0 sits at 1.38× peak resident size against a 14.8 MiB Boehm process on the `macos-latest` runner (0.39.0 in the same run: 1.40×; `bench/log/macos/2026-11-01-0.40-runners/`), 1.50× peak footprint and 0.99× post-GC resident on the 2026-09-06 laptop cut (README Performance). On Windows, peak working set is not RSS: recommitted pages count again; on 0.40.0 the crystal-metric peaks above Boehm are JsonParsePure 1.07× and Knuckeotide 1.19× [1.18, 1.66] ([WINDOWS.md](WINDOWS.md)). The fat app was last cut on the header layout at 1.55× (0.24.0). Stack maps remain research-only for precise roots. Field notes: [ACIKTURKIYE.md](ACIKTURKIYE.md), [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).
