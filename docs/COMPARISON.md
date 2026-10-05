# gcry vs Boehm

Both are **conservative mark–sweep**. gcry is Crystal-native, STW-by-default, shipped as a shard. Boehm is the C library Crystal ships with — broader platforms, more MT polish.

**Scope for this checklist:** Linux x86_64 + aarch64, macOS arm64 + x86_64, Windows x86_64 + ARM64 ([WINDOWS.md](WINDOWS.md)), Crystal ≥ 1.21, parallelism **1**, `require "gcry"` + `-Dgc_none`.

## Head-to-head

Snapshot of gcry **0.34.0** (`shard.yml`) plus the unreleased 2026-10-05 sound defaults. Every number is quoted from the README, with its source.

| | gcry (0.34.0) | Boehm (Crystal default) |
|--|---------------|-------------------------|
| Integration | Shard reopen under `-Dgc_none` | Built-in `gc/boehm` |
| Core language | **Crystal** | C |
| Model | Conservative STW, headerless layout (nursery / incremental opt-in, header layout only for the nursery) | Conservative BDW |
| Roots | Interior + misaligned ambient roots, static roots, whole touched fiber/thread stacks, SP clamp; **no root heuristic on by default** since 2026-10-05 ([SOUND-DEFAULTS.md](SOUND-DEFAULTS.md)) | Interior-friendly |
| Object bodies | Every non-atomic block word-scanned (layouts not read by the mark since 2026-10-04) | Conservative |
| Parallel OS threads | **Supported opt-in:** EC>1 + TLAB **off** + lazy sweep (~79% `/json`, [POLICY.md](POLICY.md)); TLAB-on / `PARALLEL_RELEASE` **unsupported** | Yes |
| Fork | atfork reinit (default) | `GC_set_handle_fork` |
| Finalizers / WeakRef | Yes (same-thread after collect) | Yes |
| Empty-chunk RSS | Released by default | LibGC reclaim |
| Precise / moving | No (needs compiler) | No |
| Platforms | **Linux, macOS, Windows** (x86_64 and arm64; soft-dirty Linux-only); other targets fail at compile time (`src/gcry/platform/os.cr`) | Broad |
| Crystal `spec/std` | **18 054 / 18 054** pass (1.21.0), CI job `std-spec` (`ci/std-spec.sh`) | 18 054 / 18 054 |
| Kemal `/json`, Linux | **112.6%** [106.6, 118.6] thr at **1.07×** peak RSS — `bench/log/linux/2026-09-06-bitmap-default-ab/` | baseline |
| Kemal `/json`, macOS | **101.9%** [100.9, 103.0] thr at **1.50×** peak footprint (0.99× post-GC) — `bench/log/macos/2026-09-06-bitmap-default-ab/` | baseline |
| Kemal, CI perf smoke (v0.34.0) | Linux `/json` 104.8%, `/` 100.8%, peak RSS 0.96×; macOS `/json` 106.4%, 1.13× — medians, [leaderboard](../bench/leaderboard.md) | baseline |
| Fat app `/api/v1/`, Linux | 90.8% thr at 1.55× RSS (header layout, 0.24.0) — [ACIKTURKIYE.md](ACIKTURKIYE.md) | baseline |
| Cost of the sound defaults | EC4 Linux pause 3.07 → 4.55 ms, req/s unchanged; EC1 unchanged; macOS pause ~1.22–1.25× (CI, 2026-09-26, `bench/sound_matrix.py`) | — |

The Kemal and fat-app rows were measured while the 256 KiB STW stack lags were still the default; the last row is what removing them costs.

## Pick gcry when

- You want a collector you can **read and change** in Crystal
- Linux, macOS or Windows + default ExecutionContext (parallelism 1)
- Kemal-class throughput and RSS near Boehm is the bar
- You're OK tuning `GCRY_*` and naming conservative retention honestly

## Stay on Boehm when

- You need Parallel EC **with TLAB** or empty-chunk munmap under EC>1 (unsupported in gcry)
- You target anything outside Linux, macOS and Windows on x86_64 / aarch64
- Your workload is an allocation storm with a large pointer heap, and wall time is the bar: gcry runs Primes at 77% and JsonParsePure at 79% of Boehm's speed on a 12-CPU Linux host (`bench/log/linux/2026-10-05-alloc-storm-mark/`)
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

Kemal `/json` on the headerless default sits at 1.07× Boehm's peak RSS on Linux and 0.96× in the CI perf smoke; on macOS every gcry arm sits at the 16 MiB Darwin threshold floor, 1.50× peak footprint and 0.99× post-GC resident (README Performance). The fat app was last cut on the header layout at 1.55× (0.24.0). Stack maps remain research-only for precise roots. Field notes: [ACIKTURKIYE.md](ACIKTURKIYE.md), [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).
