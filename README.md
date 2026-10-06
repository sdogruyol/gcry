<p align="center">
  <img src="assets/logo.svg" alt="gcry" width="240"/>
</p>

<h1 align="center">gcry</h1>

<p align="center">
  <b>The garbage collector Crystal deserves — written in Crystal.</b><br>
  <i>Conservative mark–sweep. Ship as a shard. One flag replaces Boehm.</i>
</p>

<p align="center">
  <b>gcry beats Boehm on throughput — ~113% on Kemal <code>/json</code> — at ~1.07× its peak RSS (Linux, headerless default).</b>
</p>

<p align="center">
  <a href="https://github.com/sdogruyol/gcry/stargazers"><img src="https://img.shields.io/github/stars/sdogruyol/gcry?style=flat-square&logo=github" alt="Stars"></a>
  <a href="https://github.com/sdogruyol/gcry/releases"><img src="https://img.shields.io/github/v/release/sdogruyol/gcry?style=flat-square&logo=github&label=version" alt="Version"></a>
  <a href="https://crystal-lang.org"><img src="https://img.shields.io/badge/Crystal-%3E%3D1.21-000?style=flat-square&logo=crystal" alt="Crystal"></a>
  <a href="https://github.com/sdogruyol/gcry/actions"><img src="https://img.shields.io/github/actions/workflow/status/sdogruyol/gcry/ci.yml?branch=master&style=flat-square&logo=githubactions&label=CI" alt="CI"></a>
  <img src="https://img.shields.io/badge/platforms-Linux%20%7C%20macOS%20%7C%20Windows-4a90d9?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/license-MIT-3da639?style=flat-square" alt="License">
</p>

<br>

---

## In one line

```crystal
{% if flag?(:gc_none) %} require "gcry" {% end %}
```

```sh
crystal build -Dgc_none app.cr -o app
```

String, Array, Hash — everything allocates on gcry. No API changes. One line
to swap Boehm out, one line to swap it back.

**Boehm-parity throughput: ~105% [99, 111] on Kemal `/json` at ~1.3× peak RSS (Linux, 0.24.0); ~102% at ~2.0× peak on macOS.**

---

## Who is this for?

- **You use Crystal in production** and want to understand how memory works.
- **You've hit a Boehm limitation** and want a collector you can debug.
- **You contribute to Crystal** and want the language to own its runtime.
- **You're curious** — one `crystal build -Dgc_none` and you'll see.

Crystal >= 1.21. Linux (x86_64 + aarch64), macOS (arm64 + x86_64), and
[Windows x86_64 + ARM64](docs/WINDOWS.md).

Crystal's own standard-library suite passes under gcry: all 18 054 examples
of `spec/std` (Crystal 1.21.0), held in CI by the `std-spec` job
([`ci/std-spec.sh`](ci/std-spec.sh)).

The Crystal compiler, built with gcry, also builds itself and passes
`compiler_spec`: 13 640 examples, 0 failures, 18 pending
([CI run 37437660646](https://github.com/sdogruyol/gcry/actions/runs/37437660646)).
`crystal i` runs in it too, because gcry exports Boehm's `GC_*` C ABI. CI
holds both in the `compiler-gcry` job ([`ci/compiler-spec.sh`](ci/compiler-spec.sh)). A
program that links libgc as well builds with `-Dgcry_no_boehm_abi`, which
leaves those exports out
([docs/INTEGRATION.md § Boehm's C ABI](docs/INTEGRATION.md#boehms-c-abi)).

On any other target — another OS, Android, or a 32-bit CPU — `-Dgc_none` +
`require "gcry"` stops the build with a compile-time error instead of
producing a binary ([`src/gcry/platform/os.cr`](src/gcry/platform/os.cr)).

---

## A GC you can actually own

Boehm works. Nobody is denying that. But Crystal's most intimate runtime
component is a C library — one you can't read, can't debug, can't change.

| | Boehm | gcry |
|--|-------|------|
| Language | C | **Crystal** |
| Integration | Built-in C library | **Shard** (`shards update`) |
| Debug | C stack frames | **Crystal stack traces** |
| Modify | Recompile C + patch Crystal | **Commit to shard** |
| Metrics | Nothing built-in | **HDR histograms + Prometheus** |
| Ownership | Upstream C project | **Your community** |

Readable. Debuggable. Changeable. Yours.

---

## How it works

```
┌──────────────────────────────────────────────────────────────┐
│                       Crystal runtime                        │
│            (GC.malloc → GC.realloc → GC.free → …)            │
└───────────────────────────────┬──────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────┐
│                    require "gcry" (shard)                    │
│                                                              │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐     │
│   │   Heap   │  │   Mark   │  │  Sweep   │  │  Roots   │     │
│   │   mmap   │  │   STW    │  │   free   │  │  fiber   │     │
│   │ size-cls │  │   mark   │  │ release  │  │  stack   │     │
│   └──────────┘  └──────────┘  └──────────┘  └──────────┘     │
│                                                              │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                   │
│   │ Metrics  │  │  Layout  │  │ Platform │                   │
│   │Prometheus│  │ precise  │  │  Linux   │                   │
│   │HDR pause │  │ type_id  │  │  Darwin  │                   │
│   └──────────┘  └──────────┘  └──────────┘                   │
└──────────────────────────────────────────────────────────────┘
```

Build with `-Dgc_none` → Crystal skips libgc → gcry reopens `module GC`.
No compiler patch. No linker tricks. One flag.

---

## How to use it

```yaml
# shard.yml
dependencies:
  gcry:
    github: sdogruyol/gcry
```

```sh
shards install
```

```crystal
# src/app.cr
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

puts "hello from gcry"
```

```sh
crystal build -Dgc_none app.cr -o app && ./app
```

10 seconds. Or try without even cloning:

```sh
docker run --rm crystallang/crystal:1.21.0 sh -c '
  mkdir -p /tmp/demo/src && cd /tmp/demo
  cat > shard.yml <<EOF
dependencies:
  gcry:
    github: sdogruyol/gcry
EOF
  cat > src/demo.cr <<EOF
{% if flag?(:gc_none) %} require "gcry" {% end %}
puts "hello from gcry"
EOF
  shards install
  crystal build -Dgc_none src/demo.cr -o /tmp/demo-app && /tmp/demo-app
'
```

No clone. No install. Just Docker.

**You only need the normal Crystal install (1.21+).** Install the shard,
build with `-Dgc_none`, done. You do **not** need a special Crystal build.

(There is an optional research mode that can use extra compiler data for
more precise GC. It is off unless you turn it on, and almost nobody needs
it. Details: [docs/STACK_MAPS.md](docs/STACK_MAPS.md).)

---

## Why a second option alongside Boehm?

Because a language's garbage collector is its most intimate runtime component.
You shouldn't have to trust that to a C library you can't touch.

Boehm is a 30-year-old, battle-tested, broad-platform C library. gcry is
Crystal-native, shard-delivered, and yours to debug, change, and fork.

Both use the same contract (conservative, non-moving mark-sweep). Both
reopen the same `GC` module. The difference: one you can read and understand,
the other you can't.

---

## Performance — numbers don't lie

**% of Boehm** is the only score that matters. Same host, same load, same wrk.
Absolute req/s is host noise; the ratio is truth. Prefer `/json` (alloc-heavy).
Full methodology: [docs/PERF.md](docs/PERF.md). Release by release, as CI's own
perf smoke saw it: [bench/leaderboard.md](bench/leaderboard.md).

### Linux

| Workload | gcry vs Boehm (headerless default)* |
|----------|------------------------------------:|
| Kemal `/json` throughput | **102.0%** *(this tree, 2026-10-06; 0.34.0: 102.9% in the same session)* |
| Kemal `/json` peak RSS | **1.43×** *(22.3 vs 15.6 MiB)* |
| Kemal `/json` post-`/gc-collect` RSS | **0.88×** *(13.8 vs 15.6 MiB)* |
| Kemal `/` throughput | **86.8%** *(0.34.0: 94.6% in the same session; not GC-bound — the same code moved by NOP padding alone reads 91–98% of 0.34.0)* |
| Fat app `/api/v1/` throughput | **90.8%** *(header layout, 0.24.0; freelist: 80.7%)* |
| Fat app `/api/v1/` RSS | **1.55×** *(header layout, 0.24.0; freelist: 1.47×)* |

\*Kemal rows: `bench/log/linux/2026-10-06-pr-benchmarks/` (QEMU x86-64, 12 vCPUs, 11 interleaved trials, server on 3 CPUs, `wrk -c50`). The paragraph below is the 2026-09-06 paired A/B on 0.24.x, kept for the layout comparisons it carries.

\*Kemal: `bench/log/linux/2026-09-06-bitmap-default-ab/` — five paired arms, 20 rotated rounds, identical-binary null control at 97.5% [93.0, 102.0] (Ryzen AI 9 465). The headerless default is **151.7%** of the old freelist default at **0.57×** its peak RSS, 1.1 minor faults per 1 000 requests against 1 671, 21% less CPU per request than Boehm, p99 2.2 ms against 6.4; the header layout's bitmap allocator (the 0.24.x default, `-Dgcry_block_headers`) is 141.9% at 0.69× on the same run. `GCRY_THRESHOLD_FACTOR` scaling and the fat app were measured on the header layout: `GCRY_THRESHOLD_FACTOR` scaling and the fat app: `…/2026-09-06-threshold-factor-ab/` (acik: 8 paired trials; factor 50 puts Kemal on the product bar but costs the fat app 12 pp, so 100 stays). Post-collect RSS from the 0.24.0 changelog (CI runner). Pre-0.24.0 freelist history (v0.16 headline ~87% @ ~0.80× post-GC, `GCRY_TIGHT_GROW`, 9950X bands) — [PERF.md](docs/PERF.md), [ACIKTURKIYE.md](docs/ACIKTURKIYE.md). Parallel opt-in (EC>1 + TLAB off + lazy): ~**79%** `/json` — not the default. Stack maps dormant.

Allocation storms, crystal-metric (process-fresh, 11 interleaved trials, 12 CPUs, Crystal 1.21.0, 2026-10-06 — `bench/log/linux/2026-10-06-pr-benchmarks/`; rows marked † re-measured on 4 CPUs after the `realloc` page move went opt-in — `bench/log/linux/2026-10-06-heap-review/`):

| Bench | gcry speed vs Boehm | peak RSS × Boehm |
|-------|--------------------:|-----------------:|
| Primes | **100%** | 0.94× |
| JsonParsePure | **99%** | 0.80× |
| JsonParseSerializable † | 93% | 0.92× |
| JsonGenerate † | **113%** | 0.66× |
| Binarytrees | 94% | 0.75× |
| Revcomp † | 89% | 0.64× |
| RegexDna | 102% | 0.53× |

### macOS (Apple Silicon)

| Workload | gcry vs Boehm (headerless default)* |
|----------|------------------------------------:|
| Kemal `/json` throughput | **101.9%** [100.9, 103.0] *(header layout: 101.8%; its freelist: 85.5%)* |
| Kemal `/json` peak footprint | **1.50×** *(post-GC resident 0.99×; header layout 1.97× / 1.20×; freelist 1.78× / 1.07×)* |
| Kemal `/` throughput | **110.3%** [100.0–136.4] *(CI perf smoke, v0.34.0 window, 32 runs — [leaderboard](bench/leaderboard.md); hosted-runner wrk, not a paired A/B)* |
| Fat app `/api/v1/` throughput | **~98%** *(carry 2026-08-14 freelist re-cut)* |
| Fat app `/api/v1/` RSS | **~0.97×** *(carry 2026-08-14 freelist re-cut)* |

\*Kemal: `bench/log/macos/2026-09-06-bitmap-default-ab/` (Apple M2 Pro, five paired arms, 20 rotated rounds, null at 100.9% [99.1, 102.6]); 0.4 faults per 1 000 requests against the freelist's 344, 10% less CPU per request than Boehm, p99 2.9 against 5.2 ms. Every gcry arm sits at the 16 MiB Darwin threshold floor, so the warm-chunk budget is most of the RSS difference between the header layout and the freelist — the reverse of the Linux ordering; the headerless layout's 0.47× cut in peak footprint against the header layout comes on top of it. Fat app: `…/2026-08-14-acik-recut/`, n=9 per arm, 0 Non-2xx in 18 trials, on the freelist — [PERF-macos.md](docs/PERF-macos.md), [ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md).

Detailed tables: [PERF.md](docs/PERF.md) · [PERF-macos.md](docs/PERF-macos.md) · [ACIKTURKIYE.md](docs/ACIKTURKIYE.md)

Freelist-era history (pre-0.24.0, `GCRY_BITMAP_ALLOC=0`; `GCRY_TIGHT_GROW` is freelist-only): Linux tip fat-app RSS was ~**1–1.6x** Boehm after finalizer + retain=0 (i3 headline ~**1.63x**; residual is mapped freelist). Opt-in `GCRY_TIGHT_GROW=1` brings acik to ~**0.92x**. The v0.17 i3 cut was ~**3.43x**. Darwin tip fat-app is ~**98%** thr @ ~**0.97x** RSS at n=9 (2026-08-14 re-cut; was ~**18x** at v0.17). The ~**0.63x** this line used to carry does not reproduce — gcry's post-GC RSS is within 0.6% of that cut, and what fell 35% between the two sessions is Boehm's arm. Stack maps remain research-only for precise roots — product path is tip without `PRECISE_STACK`.

### What the default heuristics cost

**Since 2026-10-05 the process defaults are root-complete** — the sound
column below. The last two default knobs that could decline a live pointer,
the 256 KiB multi-mutator STW stack and pthread lags, now default to 0 (the
whole touched stack; `src/gcry/collect_scan.cr`,
`process_spec/regression/14_sound_defaults_spec.cr`); the static-root
`type_id` gate went on 2026-09-29, after it was found to sweep a class
variable's raw buffer of references. The Kemal and fat-app numbers above were
measured before that, with the lags armed; the tables below are what the
change costs. To restore the bounded scan:

```sh
GCRY_STW_STACK_LAG=262144 GCRY_STW_PTHREAD_LAG=262144 ./your-app
```

`GCRY_SOUND=1` still forces the whole sound profile, ahead of any individual
knob. In the tables, "tuned" is the old lagged default and "sound" is today's.

Re-cut on the 0.24.x bitmap default, `bench/log/linux/2026-09-08-heuristics-ab/`
(Ryzen AI 9 465, 20 rotated rounds × 15 s, identical-binary null control at
100.0% [96.5, 103.5]):

| Kemal `/json`, EC1 | % of Boehm [95% CI] | % of tuned | peak RSS × | pause p50 / p99 |
|--------------------|--------------------:|-----------:|-----------:|----------------:|
| tuned (process defaults until 2026-10-05) | 110.5% [105.5, 115.6] | 100% | 1.29× | 0.78 / 1.58 ms |
| **sound roots** (`GCRY_SOUND=1`; the default's root profile since 2026-10-05) | **117.0%** [111.3, 122.6] | 106.5% [100.6, 112.5] | **1.29×** | **0.76 / 1.20 ms** |
| sound + fully conservative bodies | 112.8% [108.0, 117.6] | 102.7% [97.4, 108.0] | 1.28× | 0.76 / 1.29 ms |

**On one mutator thread, sound roots are free.** RSS is identical across the
three (all sit at the warm-chunk budget), pause is identical, and throughput
is at or slightly above tuned — the heuristics cost per-candidate work in the
mark (type-id gate, blacklist) and buy nothing on this heap. The 2026-08-06
session read the same thing through a noisier harness and called it
"throughput-neutral, under ~1%"; the harness biases it found and fixed
(monotonic timing, rotated order, null arm) are what this cut runs on —
[SOUND-DEFAULTS.md](docs/SOUND-DEFAULTS.md).

**With more threads, sound roots cost about a quarter to a half of a small
pause, and nothing else measurable.** Paired per round on the CI runners
(2026-09-26, `6ed9fc9`, 10 rounds,
[`bench/sound_matrix.py`](bench/sound_matrix.py)); sound ÷ tuned:

| Kemal `/json` | Linux req/s | Linux pause | macOS req/s | macOS pause |
|---------------|------------:|------------:|------------:|------------:|
| EC1 | 1.01 | 0.99× | 0.90 (noisy) | 1.01× |
| EC1 + one thread of the app's own | 0.97 | 1.45× | 1.08 | 1.22× |
| EC4 | 1.01 | 1.45× | 1.02 | 1.25× |

On Linux the complete scan now costs about half again a small pause (EC4
3.07 → 4.55 ms) and nothing measurable in throughput or RSS. In August it was
8× (12.6 → 97.1 ms, half the throughput). The low-water skip on the default
path and 0.28.0's SYSMON fix took that out: before 0.28.0 the collector read
the monitor thread's whole 8 MiB stack every multi-threaded collection, which
also defeated the skip on it
([findings](bench/log/linux/2026-09-26-sysmon-guard-scan/FINDINGS.md)).
macOS paid 5.8× until the same day: its page query costs ~275 ns per page,
and proving a parked fiber's untouched 8 MiB took 141 µs per fiber per
collection. It now reads the VM object's resident count instead (18 µs)
([findings](bench/log/linux/2026-09-26-sound-matrix/FINDINGS.md)).
The fat app (~72 MiB heap: 10.7 → 18.2 ms on the freelist cut) was not
re-measured.

Parked-fiber scrub was in the heuristic list through v0.18 and is **opt-in**
since (`GCRY_SCRUB_FIBERS=1`); the per-collection trace showed it moving
~0.013% of wall time for no measured retention.

### Pause distribution (Kemal `/json`, Linux)

Tuned (pre-2026-10-05) defaults, EC1, medians of 20 trials' `/gc-stats` from the session above
(`pause_p50_ns` / `pause_p99_ns` / `pause_max_ns`; 589 collections per 15 s):

```
p50:  0.78 ms  ██████████████████
p99:  1.58 ms  ████████████████████████████████████
max:  2.82 ms  ████████████████████████████████████████████████████████████████
```

HDR histogram built in via `Gcry.pause_stats` — no external tools needed.
Prometheus `/metrics` exposes pause percentiles as gauges.

---

## Feature set

| Feature | Description |
|---------|-------------|
| **Conservative mark-sweep** | Safe for today's Crystal ABI; scans for pointer-shaped words |
| **Stop-the-world** | Linux signals / Darwin Mach suspend / Windows SuspendThread; HDR histogram via `Gcry.pause_stats` |
| **Non-moving** | Stable addresses — no compaction surprises |
| **Fiber roots** | Stacks + parked fibers; STW SP clamp on other threads |
| **Conservative bodies** | Every non-atomic block is word-scanned; no type map narrows a scan since 2026-10-04 (a union buffer's first tag reads as a type id — `docs/SOUND-DEFAULTS.md`) |
| **Headerless layout** | Compile default — no 16-byte per-object header; small blocks are carved back-to-back and size, kind, marks and occupancy live in the chunk. Kemal `/json` ~**113%** of Boehm at **1.07×** its peak RSS (Linux). `-Dgcry_block_headers` restores the header layout |
| **Bitmap allocator** | Process default since 0.24.0 and forced on by the headerless layout — `occ` bitmaps, streaming `occ &= mark` sweep, per-thread cursors. `GCRY_BITMAP_ALLOC=0` is the freelist escape, on `-Dgcry_block_headers` only |
| **Warm-chunk budget** | Emptied chunks stay mapped up to live × `GCRY_THRESHOLD_FACTOR`; an explicit `GC.collect`, the idle collector and the collection before an `OutOfMemoryError` release them, so post-collect RSS is the live footprint (~**1.2×** Boehm on Kemal). Multi-threaded programs too since 0.30.0: Kemal at 4 workers reads 20 MB after `GC.collect`, 85 MB before |
| **macOS reclaim** | `MADV_FREE_REUSABLE` at host page size (16 KiB on Apple Silicon), with `MADV_FREE_REUSE` before reuse, so released pages leave `phys_footprint` at once |
| **Observability** | `Gcry.metrics`, `prometheus_text`, `Observability.json_stats` |
| **Fork** | `pthread_atfork` reinit (default); see [POLICY](docs/POLICY.md) |

---

## Scope (honest)

gcry is **production-curious** on Linux and macOS process GC at parallelism 1.
Windows x86_64 + ARM64 have native unit, process-GC, and release-sample CI coverage, plus the Linux race and root gates that hold there.
Windows workload performance has not been benchmarked; see [support details](docs/WINDOWS.md).

| Today | Later / elsewhere |
|-------|-------------------|
| **Linux + macOS + Windows x86_64 + ARM64** process GC (Crystal >= 1.21) | Windows workload benchmarks |
| Default ExecutionContext, **parallelism 1** (PERF headline) | Parallel **supported opt-in:** EC>1 + TLAB off + lazy (~79% `/json`); TLAB-on still experimental |
| Kemal-class thr/RSS near Boehm | Ultra-dense conservative-live apps may keep more RSS until stack maps |
| `LibC.fork` + atfork reinit | `Process.fork` under ExecutionContext (Crystal forbids it anyway) |

**A hang in a Parallel context may not be the collector.** Crystal 1.21's
Parallel scheduler can deadlock two workers, each waiting in `Scheduler#resume`
for the fiber the other is running. It reproduces under Boehm with no GC calls,
0.5–3% of runs of a two-worker channel ping-pong. If a stuck process shows two
threads spinning in `parallel/scheduler.cr` and no collector frame, that is the
likely cause. Reproducer, measurement and an upstream patch (72 stalls in 2500
runs → 0):
[`bench/log/linux/2026-09-25-parallel-scheduler-deadlock/`](bench/log/linux/2026-09-25-parallel-scheduler-deadlock/FINDINGS.md).
Upstream: [crystal-lang/crystal#17486](https://github.com/crystal-lang/crystal/issues/17486), fix in [#17491](https://github.com/crystal-lang/crystal/pull/17491).

---

## Roadmap

```
  Phase 1  DONE  Conservative mark-sweep, STW, Linux + macOS     ✓
  Phase 2  NOW   Stack maps, barriers, -Dgc_gcry                 ○
  Phase 3  NEXT  Performance parity, parallel mark, nursery def.  ◐
  Phase 4  GOAL  Crystal's default GC                             △
```

[Full plan →](./ROADMAP.md)

---

## Tuning (quick reference)

Defaults tuned for process GC. Change after you measure:

| Variable | Effect |
|----------|--------|
| `GCRY_SOUND=1` | Force the whole root-complete profile ahead of any individual knob. The defaults have been that profile since 2026-10-05 ([SOUND-DEFAULTS.md](docs/SOUND-DEFAULTS.md)) |
| `GCRY_STW_STACK_LAG` / `GCRY_STW_PTHREAD_LAG` | Bytes; default 0 (whole touched stack). A non-zero lag bounds the multi-mutator stack scan and its pause, and can miss a live pointer deeper than the lag. At 0, Linux CI EC4 pause is 4.55 against 3.07 ms at 256 KiB, req/s unchanged (2026-09-26) |
| `GCRY_BITMAP_ALLOC=0` | Freelist allocator, the pre-0.24.0 default (Kemal `/json` ~75% of Boehm at 1.87× peak RSS on Linux; ~85% on macOS). Needs `-Dgcry_block_headers`; on the headerless default it warns and is ignored. Not the RSS escape it used to be — the default layout is the lowest-RSS of the three |
| `GCRY_THRESHOLD_FACTOR` | Warm-chunk budget and adaptive threshold, % of live (default 100). 50 → Kemal 0.95× peak RSS at unchanged throughput, but −12 pp on the fat app |
| `GCRY_KEEP_CHUNKS=1` | Keep empty chunks (freelist-era knob: ~95% `/json` thr, ~3x RSS on the freelist) |
| `GCRY_THRESHOLD` | Fixed bytes before auto-major. Unset, the threshold adapts: live bytes after each major × `GCRY_THRESHOLD_FACTOR`% (default 100), floored at 8 MiB, capped at 64 MiB (`GCRY_THRESHOLD_MAX`) or a third of the bytes the mark scanned, and paced up to 3× while collections take more than a tenth of the mutator time (`GCRY_THRESHOLD_PACE`) |
| `GCRY_THRESHOLD_PACE` | Most the adaptive threshold is paced up, % (default 300; 100 = off). Collection-bound phases get fewer majors (crystal-metric Primes −25%, JsonParsePure −22%, Binarytrees −9% wall, RSS under Boehm's); Kemal `/json` is not collection-bound and is unchanged |
| `GCRY_AUTO_LAYOUTS=1` | Whole-program layout registration; no effect on the mark since 2026-10-04 |
| `GCRY_NURSERY=1` | Opt-in nursery (off by default for process) |
| `GCRY_PARALLEL_MARK=N` | Mark workers (default `max(min(2, CPUs − 1), min(CPUs / 4 + 1, CPUs − 1, 8))` — two up to 7 CPUs, four at 12 — serial below 32 MiB live; `1` = serial) |
| `GCRY_STRESS=1` | Collect every N allocs (debug) |

Full list: [docs/HARDENING.md](docs/HARDENING.md). Pauses: `Gcry.pause_stats`.

---

## Docs

| Doc | What |
|-----|------|
| [DESIGN.md](DESIGN.md) | Architecture & design decisions |
| [ROADMAP.md](./ROADMAP.md) | Public roadmap to becoming Crystal's default GC |
| [docs/PERF.md](docs/PERF.md) | Linux performance numbers |
| [docs/PERF-macos.md](docs/PERF-macos.md) | macOS performance numbers |
| [docs/COMPARISON.md](docs/COMPARISON.md) | gcry vs Boehm head-to-head |
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | Crystal `GC` wiring |
| [docs/RFC-GC-BACKEND.md](docs/RFC-GC-BACKEND.md) | Upstream proposal: `-Dgc_gcry` backend + runtime hooks |
| [docs/HARDENING.md](docs/HARDENING.md) | All env knobs |
| [docs/SOUND-DEFAULTS.md](docs/SOUND-DEFAULTS.md) | Root-complete defaults (2026-10-05) and what the heuristics they replaced cost |
| [docs/STACK_MAPS.md](docs/STACK_MAPS.md) | Compiler stack maps (research; default off) |
| [docs/API.md](docs/API.md) | Public API + `/metrics` |
| [docs/POLICY.md](docs/POLICY.md) | OOM, fork, signals |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

---

## Contributing

1. Fork -> branch -> commit -> push -> PR
2. Collector hot paths: **no managed-heap allocation**
3. Prefer small modules (`heap`, `mark`, `sweep`, `roots`)
4. Stuck? [good first issues](https://github.com/sdogruyol/gcry/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)

---

## Development

```sh
make spec             # unit specs under Boehm
make samples          # -Dgc_none samples -> bin/
make bench            # library-heap churn
make bench-kemal-wrk  # Kemal + wrk on / and /json
make format-check
```

---

## License

MIT — see [LICENSE](LICENSE).

## Contributors

[Serdar Dogruyol](https://github.com/sdogruyol) — creator and maintainer

<br>

---

**Tried it? Star it. Loved it? Share it. Hated it? Open an issue.**  
gcry is yours — use it, break it, fix it, fork it. That's the point.
