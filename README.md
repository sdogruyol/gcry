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
Full methodology: [docs/PERF.md](docs/PERF.md).

### Linux

| Workload | gcry vs Boehm (headerless default)* |
|----------|------------------------------------:|
| Kemal `/json` throughput | **112.6%** [106.6, 118.6] *(header layout `-Dgcry_block_headers`: 105.3%; its freelist `GCRY_BITMAP_ALLOC=0`: 74.9%)* |
| Kemal `/json` peak RSS | **1.07×** *(header layout: 1.30×; 0.95× at 105.1% with `GCRY_THRESHOLD_FACTOR=50` there)* |
| Kemal `/json` post-`/gc-collect` RSS | **~1.07×** *(31.2 vs 29.3 MB, peak = post-GC; header layout ~1.2× on the CI runner, 15.2 vs 12.9 MB)* |
| Kemal `/` throughput | **~82%** *(carry v0.16; not re-measured since)* |
| Fat app `/api/v1/` throughput | **90.8%** *(header layout, 0.24.0; freelist: 80.7%)* |
| Fat app `/api/v1/` RSS | **1.55×** *(header layout, 0.24.0; freelist: 1.47×)* |

\*Kemal: `bench/log/linux/2026-09-06-bitmap-default-ab/` — five paired arms, 20 rotated rounds, identical-binary null control at 97.5% [93.0, 102.0] (Ryzen AI 9 465). The headerless default is **151.7%** of the old freelist default at **0.57×** its peak RSS, 1.1 minor faults per 1 000 requests against 1 671, 21% less CPU per request than Boehm, p99 2.2 ms against 6.4; the header layout's bitmap allocator (the 0.24.x default, `-Dgcry_block_headers`) is 141.9% at 0.69× on the same run. `GCRY_THRESHOLD_FACTOR` scaling and the fat app were measured on the header layout: `GCRY_THRESHOLD_FACTOR` scaling and the fat app: `…/2026-09-06-threshold-factor-ab/` (acik: 8 paired trials; factor 50 puts Kemal on the product bar but costs the fat app 12 pp, so 100 stays). Post-collect RSS from the 0.24.0 changelog (CI runner). Pre-0.24.0 freelist history (v0.16 headline ~87% @ ~0.80× post-GC, `GCRY_TIGHT_GROW`, 9950X bands) — [PERF.md](docs/PERF.md), [ACIKTURKIYE.md](docs/ACIKTURKIYE.md). Parallel opt-in (EC>1 + TLAB off + lazy): ~**79%** `/json` — not the default. Stack maps dormant.

### macOS (Apple Silicon)

| Workload | gcry vs Boehm (headerless default)* |
|----------|------------------------------------:|
| Kemal `/json` throughput | **101.9%** [100.9, 103.0] *(header layout: 101.8%; its freelist: 85.5%)* |
| Kemal `/json` peak footprint | **1.50×** *(post-GC resident 0.99×; header layout 1.97× / 1.20×; freelist 1.78× / 1.07×)* |
| Kemal `/` throughput | **~91%** *(carry 2026-08-04; not re-measured on 0.24.0)* |
| Fat app `/api/v1/` throughput | **~98%** *(carry 2026-08-14 freelist re-cut)* |
| Fat app `/api/v1/` RSS | **~0.97×** *(carry 2026-08-14 freelist re-cut)* |

\*Kemal: `bench/log/macos/2026-09-06-bitmap-default-ab/` (Apple M2 Pro, five paired arms, 20 rotated rounds, null at 100.9% [99.1, 102.6]); 0.4 faults per 1 000 requests against the freelist's 344, 10% less CPU per request than Boehm, p99 2.9 against 5.2 ms. Every gcry arm sits at the 16 MiB Darwin threshold floor, so the warm-chunk budget is most of the RSS difference between the header layout and the freelist — the reverse of the Linux ordering; the headerless layout's 0.47× cut in peak footprint against the header layout comes on top of it. Fat app: `…/2026-08-14-acik-recut/`, n=9 per arm, 0 Non-2xx in 18 trials, on the freelist — [PERF-macos.md](docs/PERF-macos.md), [ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md).

Detailed tables: [PERF.md](docs/PERF.md) · [PERF-macos.md](docs/PERF-macos.md) · [ACIKTURKIYE.md](docs/ACIKTURKIYE.md)

Freelist-era history (pre-0.24.0, `GCRY_BITMAP_ALLOC=0`; `GCRY_TIGHT_GROW` is freelist-only): Linux tip fat-app RSS was ~**1–1.6x** Boehm after finalizer + retain=0 (i3 headline ~**1.63x**; residual is mapped freelist). Opt-in `GCRY_TIGHT_GROW=1` brings acik to ~**0.92x**. The v0.17 i3 cut was ~**3.43x**. Darwin tip fat-app is ~**98%** thr @ ~**0.97x** RSS at n=9 (2026-08-14 re-cut; was ~**18x** at v0.17). The ~**0.63x** this line used to carry does not reproduce — gcry's post-GC RSS is within 0.6% of that cut, and what fell 35% between the two sessions is Boehm's arm. Stack maps remain research-only for precise roots — product path is tip without `PRECISE_STACK`.

### What the default heuristics cost

Every number above is measured with gcry's **root-completeness heuristics
armed** — base-pointer-only ambient roots, the static-root `type_id` gate,
256 KiB STW stack lags. Each can decline to mark a pointer that is genuinely
live, so those numbers price a collector that is allowed to guess.
`GCRY_SOUND=1` turns the whole class off:

```sh
GCRY_SOUND=1 ./your-app
```

Re-cut on the 0.24.x bitmap default, `bench/log/linux/2026-09-08-heuristics-ab/`
(Ryzen AI 9 465, 20 rotated rounds × 15 s, identical-binary null control at
100.0% [96.5, 103.5]):

| Kemal `/json`, EC1 | % of Boehm [95% CI] | % of tuned | peak RSS × | pause p50 / p99 |
|--------------------|--------------------:|-----------:|-----------:|----------------:|
| tuned (process defaults) | 110.5% [105.5, 115.6] | 100% | 1.29× | 0.78 / 1.58 ms |
| **sound roots** (`GCRY_SOUND=1`) | **117.0%** [111.3, 122.6] | 106.5% [100.6, 112.5] | **1.29×** | **0.76 / 1.20 ms** |
| sound + fully conservative bodies | 112.8% [108.0, 117.6] | 102.7% [97.4, 108.0] | 1.28× | 0.76 / 1.29 ms |

**On one mutator thread, sound roots are free.** RSS is identical across the
three (all sit at the warm-chunk budget), pause is identical, and throughput
is at or slightly above tuned — the heuristics cost per-candidate work in the
mark (type-id gate, blacklist) and buy nothing on this heap. The 2026-08-06
session read the same thing through a noisier harness and called it
"throughput-neutral, under ~1%"; the harness biases it found and fixed
(monotonic timing, rotated order, null arm) are what this cut runs on —
[SOUND-DEFAULTS.md](docs/SOUND-DEFAULTS.md).

**With more mutator threads, sound roots cost the pause**, and through it the
throughput. Same session, `EC_PARALLELISM=4`:

| Kemal `/json`, EC4 | vs tuned EC4 [95% CI] | pause p50 | root phase | collections / 15 s |
|--------------------|----------------------:|----------:|-----------:|-------------------:|
| tuned | 100% | **12.6 ms** | 12.3 ms | 270 |
| `GCRY_SOUND=1` | **50.2%** [46.7, 53.7] | **97.1 ms** | 112 ms | 151 |

The whole gap is the root phase — the two STW lag knobs scanning every parked
fiber's stack from the top instead of from its low-water mark — and each
collection holds the world eight times longer. The 2026-08-09 reading had the
same shape at 3.60 → 16.39 ms; the tuned EC4 pause has since grown to 12.6 ms
with 12.3 ms in roots. Attributed (`…/2026-09-08-ec4-root-phase/`): 98% of
it is the parked-fiber scan — under multi-mutator STW every parked fiber is
scanned `GCRY_STW_STACK_LAG` (256 KiB) below its saved SP because a fiber in
transit between threads may report a stale SP, and the pagemap low-water skip
cannot see through pages a previous tenant of the pooled stack already
faulted in. ~8 MB of stack words per collection at ~100 connections, growing
with uptime. The fix is scheduler-side: scan a fully parked fiber from its SP
and reserve the lag for fibers in transit (ROADMAP Phase 2). Fat-app pause (acik, ~72 MiB heap: 10.7 → 18.2
ms on the freelist cut) was not re-measured.

Parked-fiber scrub was in the heuristic list through v0.18 and is **opt-in**
since (`GCRY_SCRUB_FIBERS=1`); the per-collection trace showed it moving
~0.013% of wall time for no measured retention.

### Pause distribution (Kemal `/json`, Linux)

Tuned defaults, EC1, medians of 20 trials' `/gc-stats` from the session above
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
| **Layout-precise scan** | Builtins + opt-in — fewer false keeps where registered |
| **Headerless layout** | Compile default — no 16-byte per-object header; small blocks are carved back-to-back and size, kind, marks and occupancy live in the chunk. Kemal `/json` ~**113%** of Boehm at **1.07×** its peak RSS (Linux). `-Dgcry_block_headers` restores the header layout |
| **Bitmap allocator** | Process default since 0.24.0 and forced on by the headerless layout — `occ` bitmaps, streaming `occ &= mark` sweep, per-thread cursors. `GCRY_BITMAP_ALLOC=0` is the freelist escape, on `-Dgcry_block_headers` only |
| **Warm-chunk budget** | Emptied chunks stay mapped up to live × `GCRY_THRESHOLD_FACTOR`; an explicit `GC.collect` releases them, so post-collect RSS is the live footprint (~**1.2×** Boehm on Kemal) |
| **macOS reclaim** | `mach_vm` punch-hole at host page size (16 KiB on Apple Silicon) |
| **Observability** | `Gcry.metrics`, `prometheus_text`, `Observability.json_stats` |
| **Fork** | `pthread_atfork` reinit (default); see [POLICY](docs/POLICY.md) |

---

## Scope (honest)

gcry is **production-curious** on Linux and macOS process GC at parallelism 1.
Windows x86_64 + ARM64 have native unit, process-GC, and release-sample CI coverage.
Windows workload performance has not been benchmarked; see [support details](docs/WINDOWS.md).

| Today | Later / elsewhere |
|-------|-------------------|
| **Linux + macOS + Windows x86_64 + ARM64** process GC (Crystal >= 1.21) | Windows workload benchmarks |
| Default ExecutionContext, **parallelism 1** (PERF headline) | Parallel **supported opt-in:** EC>1 + TLAB off + lazy (~79% `/json`); TLAB-on still experimental |
| Kemal-class thr/RSS near Boehm | Ultra-dense conservative-live apps may keep more RSS until stack maps |
| `LibC.fork` + atfork reinit | `Process.fork` under ExecutionContext (Crystal forbids it anyway) |

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
| `GCRY_SOUND=1` | Turn off every root-completeness heuristic. Free on one mutator thread (RSS, pause and throughput at parity, 2026-09-08); **halves throughput under EC4** through an 8× pause, and costs pause on any big root scan |
| `GCRY_BITMAP_ALLOC=0` | Freelist allocator, the pre-0.24.0 default (Kemal `/json` ~75% of Boehm at 1.87× peak RSS on Linux; ~85% on macOS). Needs `-Dgcry_block_headers`; on the headerless default it warns and is ignored. Not the RSS escape it used to be — the default layout is the lowest-RSS of the three |
| `GCRY_THRESHOLD_FACTOR` | Warm-chunk budget and adaptive threshold, % of live (default 100). 50 → Kemal 0.95× peak RSS at unchanged throughput, but −12 pp on the fat app |
| `GCRY_KEEP_CHUNKS=1` | Keep empty chunks (freelist-era knob: ~95% `/json` thr, ~3x RSS on the freelist) |
| `GCRY_THRESHOLD` | Fixed bytes before auto-major. Unset, the threshold adapts: live bytes after each major × `GCRY_THRESHOLD_FACTOR`% (default 100), clamped 8–64 MiB |
| `GCRY_AUTO_LAYOUTS=1` | Whole-program precise layouts (~-7pp thr) |
| `GCRY_NURSERY=1` | Opt-in nursery (off by default for process) |
| `GCRY_PARALLEL_MARK=N` | Experimental parallel mark workers (default 1) |
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
| [docs/HARDENING.md](docs/HARDENING.md) | All env knobs |
| [docs/SOUND-DEFAULTS.md](docs/SOUND-DEFAULTS.md) | `GCRY_SOUND=1` — what gcry costs with no root heuristics |
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
