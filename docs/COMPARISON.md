# gcry vs Boehm

Both are **conservative mark–sweep**. gcry is Crystal-native, STW-by-default, shipped as a shard. Boehm is the C library Crystal ships with — broader platforms, more MT polish.

**Scope for this checklist:** Linux x86_64 + aarch64, macOS arm64 + x86_64, Windows x86_64 + ARM64 ([WINDOWS.md](WINDOWS.md)), Crystal ≥ 1.21, parallelism **1**, `require "gcry"` + `-Dgc_none`.

## Head-to-head

Snapshot of gcry **0.37.0** (`shard.yml`, 2026-10-18): sound defaults, parallel mark on by default, Boehm's `GC_*` C ABI, in-place large `realloc`, batched mark, and the fixes in `CHANGELOG.md`. Every number is quoted from the README, with its source.

| | gcry (0.37.0) | Boehm (Crystal default) |
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
| Platforms | **Linux, macOS, Windows** (x86_64 and arm64; soft-dirty Linux-only); other targets fail at compile time (`src/gcry/platform/os.cr`). Windows workloads measured on x86_64 in VMs only (a 12-vCPU QEMU VM, GitHub's `windows-latest` runner), ARM64 unmeasured ([WINDOWS.md](WINDOWS.md)); Linux arm64 measured on GitHub's `ubuntu-24.04-arm` runner, macOS x86_64 on `macos-15-intel` (`bench/log/{linux,macos}/2026-10-18-0.37-runners/`) | Broad |
| Boehm C ABI | The surface Crystal uses; differences in [INTEGRATION.md § Boehm parity](INTEGRATION.md#boehm-parity) | Full |
| Crystal `spec/std` | **18 054 / 18 054** pass (1.21.0, Linux x86_64) and 18 257 on 1.22.0 (CI run 38721725009), CI job `std-spec` (`ci/std-spec.sh`); not run on macOS or Windows | 18 054 / 18 054 |
| Kemal `/json`, Linux | **105.4%** thr (0.36.0, 2026-10-14 — `bench/log/linux/2026-10-14-0.36-integration-ab/`; 0.37.0 level with it on that host and on the 4-vCPU `ubuntu-latest` runner, where an earlier −2% to −7% was code placement — `bench/log/linux/2026-10-19-kemal-placement/`) at **1.21×** peak RSS (0.37.0; 0.36.0 1.31× in the same sessions — `bench/log/linux/2026-10-18-0.37-kemal/`); 0.88× after `GC.collect` (2026-10-06) | baseline |
| Kemal `/json`, Windows x86_64 (VM) | **106.5%** thr at 1.14× peak working set — `bench/log/windows/2026-10-06-vm-validation/` | baseline |
| crystal-metric, Windows x86_64 (`windows-latest`) | **94–108%** of Boehm's speed, peak working set 0.47–0.93× on 7 of 9 rows (JsonParsePure 1.08×, Knuckeotide 1.73×) (0.37.0, 2026-10-18; 0.36.0 in the same run: 94–108%, Knuckeotide 1.67×) — `bench/log/windows/2026-10-18-0.37-runners/` | baseline |
| Kemal `/json`, macOS arm64 (`macos-latest`) | **103.5%** [93.7, 115.4] and 107.1% [98.9, 111.3] thr in two runs at **1.39×** and 1.38× peak RSS (0.37.0, 2026-10-18; 0.36.0 in the same runs: 102.3% and 104.5%, 1.98× and 1.95×) — `bench/log/macos/2026-10-18-0.37-runners/`; peak *footprint* on the 2026-09-06 laptop cut: 1.50×, 0.99× post-GC | baseline |
| crystal-metric, macOS arm64 (`macos-latest`) | **98–105%** of Boehm's speed on 7 of 9 rows (Binarytrees 87%, Knuckeotide 92%), peak RSS 0.50–0.96× on 7 of 9 (JsonParsePure 1.07×, Knuckeotide 1.56×) (0.37.0, 2026-10-18) — same directory | baseline |
| Linux arm64 (`ubuntu-24.04-arm`) | crystal-metric **90–100%** of Boehm's speed on 7 of 9 rows (Binarytrees 80%, Knuckeotide 88%), peak RSS 0.55–0.93× on 7 of 9; Kemal `/json` **105.6%** [102.8, 108.8] at 1.32× (0.37.0, 2026-10-18) — `bench/log/linux/2026-10-18-0.37-runners/` | baseline |
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
- Your workload grows large buffers in a hot loop and wall time is the bar: gcry runs Revcomp at 92% of Boehm's speed on 12-CPU Linux x86_64 (0.36.0, `bench/log/linux/2026-10-14-0.36-integration-ab/`), 98% on Windows x86_64 and 100% on macOS arm64 (0.37.0, `bench/log/{windows,macos}/2026-10-18-0.37-runners/`); JsonParseSerializable, which used to trail too, is at 99–106% on those three since in-place `realloc` growth
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

Kemal `/json` on the headerless default sits at 1.21× Boehm's peak RSS on Linux (0.37.0, `bench/log/linux/2026-10-18-0.37-kemal/`) and 0.88× after `GC.collect` (2026-10-06), and 0.96× in the CI perf smoke; on macOS 0.37.0 sits at 1.39× peak resident size against a 15 MiB Boehm process on the `macos-latest` runner (0.36.0, on the 16 MiB Darwin threshold floor: 1.98×; `bench/log/macos/2026-10-18-0.37-runners/`), 1.50× peak footprint and 0.99× post-GC resident on the 2026-09-06 laptop cut (README Performance). On Windows, peak working set is not RSS: recommitted pages count again; on 0.37.0 the crystal-metric peaks above Boehm are JsonParsePure 1.08× and Knuckeotide 1.73× ([WINDOWS.md](WINDOWS.md)). The fat app was last cut on the header layout at 1.55× (0.24.0). Stack maps remain research-only for precise roots. Field notes: [ACIKTURKIYE.md](ACIKTURKIYE.md), [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).
