# gcry vs Boehm

Both are **conservative mark–sweep**. gcry is Crystal-native, STW-by-default, shipped as a shard. Boehm is the C library Crystal ships with — broader platforms, more MT polish.

**Scope for this checklist:** Linux x86_64 + aarch64, macOS arm64 + x86_64, Windows x86_64 + ARM64 ([WINDOWS.md](WINDOWS.md)), Crystal ≥ 1.21, parallelism **1**, `require "gcry"` + `-Dgc_none`.

## Head-to-head

Snapshot of gcry **0.38.0** (`shard.yml`, 2026-10-21): sound defaults, parallel mark on by default, Boehm's `GC_*` C ABI, in-place large `realloc`, batched mark, the occupancy claim, and the fixes in `CHANGELOG.md`. Every number is quoted from the README, with its source.

| | gcry (0.38.0) | Boehm (Crystal default) |
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
| Platforms | **Linux, macOS, Windows** (x86_64 and arm64; soft-dirty Linux-only); other targets fail at compile time (`src/gcry/platform/os.cr`). Windows workloads measured on x86_64 in VMs only (a 12-vCPU QEMU VM, GitHub's `windows-latest` runner), ARM64 unmeasured ([WINDOWS.md](WINDOWS.md)); Linux arm64 measured on GitHub's `ubuntu-24.04-arm` runner, macOS x86_64 on `macos-15-intel` (`bench/log/{linux,macos}/2026-10-21-0.38-runners/`) | Broad |
| Boehm C ABI | The surface Crystal uses; differences in [INTEGRATION.md § Boehm parity](INTEGRATION.md#boehm-parity) | Full |
| Crystal `spec/std` | **18 054 / 18 054** pass (1.21.0, Linux x86_64) and 18 257 on 1.22.0 (CI run 38721725009), CI job `std-spec` (`ci/std-spec.sh`); not run on macOS or Windows | 18 054 / 18 054 |
| Kemal `/json`, Linux | **104.3–105.4%** thr in two sessions at **1.23×** peak RSS (0.38.0, 2026-10-21; 0.37.0 level with it in the same sessions, 1.23× — `bench/log/linux/2026-10-21-0.38-kemal/`; on the 4-vCPU `ubuntu-latest` runner an earlier −2% to −7% of 0.37.0 against 0.36.0 was code placement — `bench/log/linux/2026-10-19-kemal-placement/`); 0.88× after `GC.collect` (2026-10-06) | baseline |
| Kemal `/json`, Windows x86_64 (VM) | **106.5%** thr at 1.14× peak working set — `bench/log/windows/2026-10-06-vm-validation/` | baseline |
| crystal-metric, Windows x86_64 (`windows-latest`) | **94–122%** and 96–117% of Boehm's speed in two runs, peak working set 0.47–0.93× on 7 of 9 rows (JsonParsePure 1.07×, Knuckeotide 1.77× and 1.71×) (0.38.0, 2026-10-21; 0.37.0 in the same runs: 95–120%, Knuckeotide 1.64× and 1.55×, paired within the spread) — `bench/log/windows/2026-10-21-0.38-runners/` | baseline |
| Kemal `/json`, macOS arm64 (`macos-latest`) | **103.5%** [101.5, 105.3] thr at **1.39×** peak RSS (0.38.0, 2026-10-21; 0.37.0 in the same run: 103.9%, 1.40×) — `bench/log/macos/2026-10-21-0.38-runners/`; peak *footprint* on the 2026-09-06 laptop cut: 1.50×, 0.99× post-GC | baseline |
| crystal-metric, macOS arm64 (`macos-latest`) | **98–107%** of Boehm's speed on 7 of 9 rows (Binarytrees 92%, Knuckeotide 93%), peak RSS 0.43–0.94× on 8 of 9 (Knuckeotide 1.58×) (0.38.0, 2026-10-21) — same directory | baseline |
| Linux arm64 (`ubuntu-24.04-arm`) | crystal-metric **90–100%** of Boehm's speed on all 9 rows (Binarytrees 90%, from 77%; Knuckeotide 90%), peak RSS 0.54–0.93× on 7 of 9 (JsonParsePure 1.07×, Knuckeotide 1.35×, from 1.08×); Kemal `/json` **103.8%** [100.8, 106.8] at 1.32× (0.38.0, 2026-10-21; 0.37.0 in the same run: 102.0%) — `bench/log/linux/2026-10-21-0.38-runners/` | baseline |
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
- Your workload grows large buffers in a hot loop and wall time is the bar: gcry runs Revcomp at 97% of Boehm's speed on 12-CPU Linux x86_64 (`bench/log/linux/2026-10-21-0.38-crystal-metric/`), 96–97% on Windows x86_64 and 98% on macOS arm64 (0.38.0, `bench/log/{windows,macos}/2026-10-21-0.38-runners/`); JsonParseSerializable, which used to trail too, is at 99–106% on those three since in-place `realloc` growth
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

Kemal `/json` on the headerless default sits at 1.23× Boehm's peak RSS on Linux (0.38.0, `bench/log/linux/2026-10-21-0.38-kemal/`) and 0.88× after `GC.collect` (2026-10-06), and 0.96× in the CI perf smoke; on macOS 0.38.0 sits at 1.39× peak resident size against a 14.5 MiB Boehm process on the `macos-latest` runner (0.37.0 in the same run: 1.40×; `bench/log/macos/2026-10-21-0.38-runners/`), 1.50× peak footprint and 0.99× post-GC resident on the 2026-09-06 laptop cut (README Performance). On Windows, peak working set is not RSS: recommitted pages count again; on 0.38.0 the crystal-metric peaks above Boehm are JsonParsePure 1.07× and Knuckeotide 1.71–1.77× ([WINDOWS.md](WINDOWS.md)). The fat app was last cut on the header layout at 1.55× (0.24.0). Stack maps remain research-only for precise roots. Field notes: [ACIKTURKIYE.md](ACIKTURKIYE.md), [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).
