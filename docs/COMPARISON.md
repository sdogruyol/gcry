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
| Platforms | **Linux, macOS, Windows** (x86_64 and arm64; soft-dirty Linux-only); other targets fail at compile time (`src/gcry/platform/os.cr`). Windows workloads measured on x86_64 in VMs only (a 12-vCPU QEMU VM, GitHub's `windows-latest` runner), ARM64 unmeasured ([WINDOWS.md](WINDOWS.md)); Linux arm64 measured on GitHub's `ubuntu-24.04-arm` runner, macOS x86_64 on `macos-15-intel` (`bench/log/{linux,macos}/2026-11-05-0.40-runners/`) | Broad |
| Boehm C ABI | The surface Crystal uses; differences in [INTEGRATION.md § Boehm parity](INTEGRATION.md#boehm-parity) | Full |
| Crystal `spec/std` | **18 054 / 18 054** pass (1.21.0, Linux x86_64) and 18 257 on 1.22.0 (CI run 38721725009), CI job `std-spec` (`ci/std-spec.sh`); not run on macOS or Windows | 18 054 / 18 054 |
| Kemal `/json`, Linux | **103.6%** thr at **1.24×** peak RSS (0.40.0, 2026-11-03, one quiet session; 0.39.0 in the same session 105.6%, 1.24×, paired −1.8% [−2.0, −0.9]: code placement, 0.40.0's 16- and 64-byte pad arms read 103.3–104.3% against 0.39.0's 102.2–104.9% in a second session — `bench/log/linux/2026-11-05-0.40-linux-host/`; on the 4-vCPU `ubuntu-latest` runner 0.40.0 is at 106.6% [105.9, 108.8], paired −1.7% [−3.5, +0.5] against 0.39.0 — `bench/log/linux/2026-11-05-0.40-runners/`); 0.88× after `GC.collect` (2026-10-06) | baseline |
| Kemal `/json`, Windows x86_64 (VM) | **106.5%** thr at 1.14× peak working set — `bench/log/windows/2026-10-06-vm-validation/` | baseline |
| crystal-metric, Windows x86_64 (`windows-latest`) | **95–119%** of Boehm's speed, peak working set 0.43–0.93× on 7 of 9 rows (JsonParsePure 1.07×, Knuckeotide 1.58× [1.19, 1.64]) (0.40.0, 2026-11-03; 0.39.0 in the same run: 95–119%, Knuckeotide 1.63×; six rows 0.7–6.1% slower in wall time, Revcomp the largest: four code placement, a 0.40.0 pad arm inside 0.39.0's band and the two releases level at each of the four 16-byte code phases — `bench/log/windows/2026-11-02-0.40-win-rows/`; JsonParsePure +3.0% and Binarytrees +0.7%, placement at four phases a side on the same source (JsonParsePure 0.6–2.1% faster in wall time at the same phase, six sessions on three CPUs; Binarytrees +0.4–0.8%, the inline word advance on the runner's EPYC 7763) — `bench/log/windows/2026-11-06-win-phases/`; JsonParseSerializable and JsonParsePull peaks +4%, the growth-priced pace) — `bench/log/windows/2026-11-05-0.40-runners/` | baseline |
| Kemal `/json`, macOS arm64 (`macos-latest`) | **101.4%** [94.9, 107.2] thr at **1.37×** peak RSS (0.40.0, 2026-11-03; 0.39.0 in the same run: 102.0%, 1.40×, paired −1.3% [−4.5, +2.4]); `/` 100.8% [94.4, 112.2], paired +4.1% [−1.4, +15.8] — `bench/log/macos/2026-11-05-0.40-runners/`; peak *footprint* on the 2026-09-06 laptop cut: 1.50×, 0.99× post-GC | baseline |
| crystal-metric, macOS arm64 (`macos-latest`) | **98–108%** of Boehm's speed on 8 of 9 rows (Knuckeotide 89%), peak RSS 0.43–0.94× on 7 of 9 (JsonGenerate 0.64×, from 0.74×; JsonParsePure 1.06×, from 0.93×, a register pin in crystal-metric's `Benchmark::run`, `bench/log/macos/2026-11-06-m1-peak/`; Knuckeotide 1.32×) (0.40.0, 2026-11-03; none slower than 0.39.0 beyond the spread) — same directory | baseline |
| Linux arm64 (`ubuntu-24.04-arm`) | crystal-metric **93–105%** of Boehm's speed on all 9 rows (JsonParsePure 94%; Knuckeotide 93%), peak RSS 0.42–0.94× on 7 of 9 (JsonParsePure 1.07×, Knuckeotide 1.14×); none slower than 0.39.0 beyond the spread, JsonGenerate at 13 collections against 0.39.0's 14; Kemal `/json` **104.8%** [103.9, 108.6] at 1.06× (0.40.0, 2026-11-03; 0.39.0 in the same run: 107.1%, paired +0.1% [−5.9, +3.6]) — `bench/log/linux/2026-11-05-0.40-runners/` | baseline |
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
- Your workload grows large buffers in a hot loop and wall time is the bar: gcry runs Revcomp at 98% of Boehm's speed on 12-CPU Linux x86_64 (0.40.0, `bench/log/linux/2026-11-05-0.40-linux-host/`; below Boehm by where the allocation entry lands in the binary, which moves Revcomp by several percent whichever release is built — 0.39.0 ran at 97% in the same session — `bench/log/linux/2026-10-31-revcomp-host-placement/`), 96% on Windows x86_64 (6.1% slower than 0.39.0 there, where `Revcomp#revcomp` lands, a 16–19% band both releases share — `bench/log/windows/2026-11-02-0.40-win-rows/`) and 98% on macOS arm64 (0.40.0, `bench/log/{windows,macos}/2026-11-05-0.40-runners/`); JsonParseSerializable, which used to trail too, is at 101–107% on those three since in-place `realloc` growth
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

Kemal `/json` on the headerless default sits at 1.24× Boehm's peak RSS on Linux (0.40.0, `bench/log/linux/2026-11-05-0.40-linux-host/`) and 0.88× after `GC.collect` (2026-10-06), and 0.96× in the CI perf smoke; on macOS 0.40.0 sits at 1.37× peak resident size against a 14.9 MiB Boehm process on the `macos-latest` runner (0.39.0 in the same run: 1.40×; `bench/log/macos/2026-11-05-0.40-runners/`), 1.50× peak footprint and 0.99× post-GC resident on the 2026-09-06 laptop cut (README Performance). On Windows, peak working set is not RSS: recommitted pages count again; on 0.40.0 the crystal-metric peaks above Boehm are JsonParsePure 1.07× and Knuckeotide 1.58× [1.19, 1.64] ([WINDOWS.md](WINDOWS.md)). The fat app was last cut on the header layout at 1.55× (0.24.0). Stack maps remain research-only for precise roots. Field notes: [ACIKTURKIYE.md](ACIKTURKIYE.md), [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).
