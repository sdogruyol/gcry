<p align="center">
  <img src="assets/logo.svg" alt="gcry" width="240"/>
</p>

<h1 align="center">gcry</h1>

<p align="center">
  <b>The garbage collector Crystal deserves — written in Crystal.</b><br>
  <i>Conservative mark–sweep. Ship as a shard. One flag replaces Boehm.</i>
</p>

<p align="center">
  <b>gcry runs at ~87% of Boehm's throughput with ~0.80x the RSS (Linux).</b>
</p>

<p align="center">
  <a href="https://github.com/sdogruyol/gcry/stargazers"><img src="https://img.shields.io/github/stars/sdogruyol/gcry?style=flat-square&logo=github" alt="Stars"></a>
  <a href="https://github.com/sdogruyol/gcry/releases"><img src="https://img.shields.io/github/v/release/sdogruyol/gcry?style=flat-square&logo=github&label=version" alt="Version"></a>
  <a href="https://crystal-lang.org"><img src="https://img.shields.io/badge/Crystal-%3E%3D1.21-000?style=flat-square&logo=crystal" alt="Crystal"></a>
  <a href="https://github.com/sdogruyol/gcry/actions"><img src="https://img.shields.io/github/actions/workflow/status/sdogruyol/gcry/ci.yml?branch=master&style=flat-square&logo=githubactions&label=CI" alt="CI"></a>
  <img src="https://img.shields.io/badge/Linux-macOS-4a90d9?style=flat-square" alt="Platform">
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

**Near-Boehm performance: ~87% throughput at ~0.80x RSS (Linux).**

---

## Who is this for?

- **You use Crystal in production** and want to understand how memory works.
- **You've hit a Boehm limitation** and want a collector you can debug.
- **You contribute to Crystal** and want the language to own its runtime.
- **You're curious** — one `crystal build -Dgc_none` and you'll see.

Crystal >= 1.21. Linux (x86_64 + aarch64) and macOS (arm64 + x86_64).

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

| Workload | gcry vs Boehm (v0.19.0)* |
|----------|------------------------:|
| Kemal `/json` throughput | **~87%** *(carry v0.16)* (~95% with `GCRY_KEEP_CHUNKS=1`, escape) |
| Kemal `/json` post-GC RSS | **~0.80x** *(carry v0.16)* |
| Kemal `/` throughput | **~82%** *(carry v0.16)* |
| Fat app `/api/v1/` throughput | **~90–96%** |
| Fat app `/api/v1/` RSS | **~1–1.6x** / **~0.92x** *(`GCRY_TIGHT_GROW=1`)* / **~3.43x** *(v0.17 i3 cut)* |

\*Kemal: carry v0.16 `bench/log/linux/2026-08-01-093130/` (median-of-3, scrub on; `/` from `slash-recut/`). Quiet tip / post-tag 9950X smokes ~**80%** `/json` @ ~**0.74×** — headline stays the v0.16 cut. Fat app: finalizer + Linux retain=0 — i3 **~96%** @ **~1.63×** (`…/2026-08-04-acik-i3-retain0-med3/`); 9950X band **~1.0–1.8×** (post-tag **~102%** @ **~1.76×**, `…/2026-08-05-091820/`). Opt-in `GCRY_TIGHT_GROW=1` → acik **~103%** @ **~0.92×** (Kemal thr soft; not default) — [PERF.md](docs/PERF.md), [ACIKTURKIYE.md](docs/ACIKTURKIYE.md). Parallel opt-in (EC>1 + TLAB off + lazy): ~**79%** `/json` — not the default. Stack maps dormant — not this release’s win. Linux numbers are unchanged in v0.19.0; nothing here was re-measured.

### macOS (Apple Silicon)

| Workload | gcry vs Boehm (tip)* |
|----------|--------------------:|
| Kemal `/json` throughput | **~84%** |
| Kemal `/json` post-GC RSS | **~1.01x** |
| Kemal `/` throughput | **~91%** |
| Fat app `/api/v1/` throughput | **~98%** |
| Fat app `/api/v1/` RSS | **~0.97x** |

\*Kemal: `bench/log/macos/2026-08-04-172842/` (median-of-3, scrub on). Fat app: `…/2026-08-14-acik-recut/` tip base, n=9 per arm, 0 Non-2xx in 18 trials — [PERF-macos.md](docs/PERF-macos.md), [ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md). Tagged v0.17 carry was Kemal ~84% @ ~0.93× / acik ~71% @ ~18×.

Detailed tables: [PERF.md](docs/PERF.md) · [PERF-macos.md](docs/PERF-macos.md) · [ACIKTURKIYE.md](docs/ACIKTURKIYE.md)

Linux tip fat-app RSS is ~**1–1.6x** Boehm after finalizer + retain=0 (i3 headline ~**1.63x**; residual is mapped freelist). Opt-in `GCRY_TIGHT_GROW=1` brings acik to ~**0.92x**. The v0.17 i3 cut was ~**3.43x**. Darwin tip fat-app is ~**98%** thr @ ~**0.97x** RSS at n=9 (2026-08-14 re-cut; was ~**18x** at v0.17). The ~**0.63x** this line used to carry does not reproduce — gcry's post-GC RSS is within 0.6% of that cut, and what fell 35% between the two sessions is Boehm's arm. Stack maps remain research-only for precise roots — product path is tip without `PRECISE_STACK`.

### What the default heuristics cost

Every number above is measured with gcry's **root-completeness heuristics
armed** — base-pointer-only ambient roots, the static-root `type_id` gate,
256 KiB STW stack lags. Each can decline to mark a pointer that is genuinely
live, so those numbers price a collector that is allowed to guess.
(Parked-fiber scrub was in this list through v0.18; it is **opt-in** since
tip — nothing measured kept its default alive.) `GCRY_SOUND=1` turns the
whole class off:

```sh
GCRY_SOUND=1 ./your-app
```

| Kemal `/json` (i3, 9 rounds × 30 s) | % of Boehm | RSS × |
|-------------------------------------|-----------:|------:|
| tuned (process defaults) | 81.8% | 0.75× |
| **sound roots** (`GCRY_SOUND=1`) | **83.0%** | **0.76×** |
| sound + fully conservative bodies | 83.6% | 0.74× |

**RSS is flat across all three** — that much reproduces across two sessions.
The throughput column did not, and the reason turned out to be the harness:
**WSL2 steps `CLOCK_REALTIME` backwards ~1.6 s every ~32 s**, and wrk derives
its duration from that clock, so a pass containing a step reports ~19% high.
Which config gets hit is random, so it biased rather than merely widened — that
is how `sound` came out *ahead* of `tuned` despite doing strictly more work.

That was one of four biases in the harness — the others were blocked execution
(config order confounded with time, worth ~2–3%) and a fixed config order
within each round (whichever ran first came out ~2% slow). All four were bias,
not variance, so no run count ever helped. Fixed: monotonic timing, round-robin
interleaving, order rotated each round.

With the confounds out (`bench/log/linux/2026-08-06-140037-sound-profile/`,
9 rounds × 30 s, paired):

| Config | vs tuned | rounds won | σ |
|--------|---------:|-----------:|--:|
| `GCRY_DISABLE_SCRUB_FIBERS=1` | +1.29% *(retracted)* | 8/9 | 3.2 |
| `GCRY_SOUND=1` | +0.82% | 8/9 | 1.7 |
| `GCRY_DISABLE_BLACKLIST=1` | +0.73% | 7/9 | 1.2 |

**The whole class is throughput-neutral on this workload** — under ~1% either
way, not distinguishable from zero.

The `scrub_fibers` row was once read as the exception, the one knob with a real
signal. **That is retracted:** a second session on the same host and harness
measured **−1.22%** — sign flipped, significance gone. The arithmetic says why
and says no run count would have helped. `roots + scrub + stacks` is 223 µs of
each of 131 collections per 20 s, i.e. **0.146% of wall time**, and the knob
moves ~9% of that — **~0.013%**. Both readings are ~100× the largest effect the
mechanism can produce. Throughput cannot resolve this knob on this workload, in
either direction.

What settled it was the per-collection trace plus the fact that nothing else
supported the default: the fat-app RSS it was turned on for does not reproduce,
Kemal RSS is flat, and the wipe writes into another fiber's stack below an
*estimated* SP. It is **opt-in** on tip (`GCRY_SCRUB_FIBERS=1`), and
turning it back on costs 11.2% more root work and 5.9% more pause for no
measured retention — [PERF.md](docs/PERF.md) § "Tip default-path re-cut".

Pause cost *is* resolved, measured per collection off the GC trace:

| Cut | tuned | `GCRY_SOUND=1` |
|-----|------:|---------------:|
| Kemal `/json`, EC1 | 398 µs | 398 µs (+0.1%) |
| Kemal `/json`, **EC4** | **3.60 ms** | 16.39 ms (+356%) |
| acik `/api/v1/`, EC1, heap ~72 MiB | **10.7 ms** | 18.2 ms (+70%) |

Both tuned figures moved this session, and downward: the low-water skip used to
apply only when `lag = 0`, so the default was faulting in a fixed 256 KiB window
per parked fiber that nothing had ever written. It now starts at
`max(stack_top − lag, low_water)` — **Kemal EC4 pause 8.06 → 3.60 ms**, RSS flat.
The fat-app row read 17 ms → 213 ms two sessions ago, then briefly had
`GCRY_SOUND=1` *ahead* of the default; the skip on the default path reversed
that back. [SOUND-DEFAULTS.md](docs/SOUND-DEFAULTS.md)

In all three the whole cost is the two STW lag knobs — the other five
heuristics are within ±6%.

The EC4 arrow is a fix, not a re-measurement. `lag = 0` was scanning each parked
fiber's entire 8 MiB of reserved stack, **0.05% of which has ever been written**;
the scan now starts at the stack's low-water mark. That is not a precision trade
— a page with neither the present nor the swapped bit in `/proc/self/pagemap` has
never been faulted, so both ranges see identical words. EC4 pause 147 ms → 13 ms
in the same run, RSS unchanged. Method, per-knob decomposition, known limits of
the label, and the fat-app cut: [docs/SOUND-DEFAULTS.md](docs/SOUND-DEFAULTS.md).

### Pause distribution (Kemal `/json`, Linux)

Illustrative histogram from an earlier cut (not the v0.16.0 median session). Prefer `Gcry.pause_stats` / `/gc-stats` on your host.

```
p50:  2.1 ms  ████████████████████████████████▌
p90:  4.8 ms  ████████████████████████████████████████████
p99:  9.3 ms  ███████████████████████████████████████████████████▌
max: 48.0 ms  ████████████████████████████████████████████████████████████████
```

HDR histogram built in via `Gcry.pause_stats` — no external tools needed.
Prometheus `/metrics` exposes pause percentiles as gauges.

---

## Feature set

| Feature | Description |
|---------|-------------|
| **Conservative mark-sweep** | Safe for today's Crystal ABI; scans for pointer-shaped words |
| **Stop-the-world** | Linux signals / Darwin Mach suspend; HDR histogram via `Gcry.pause_stats` |
| **Non-moving** | Stable addresses — no compaction surprises |
| **Fiber roots** | Stacks + parked fibers; STW SP clamp on other threads |
| **Layout-precise scan** | Builtins + opt-in — fewer false keeps where registered |
| **Empty-chunk release** | On by default — Kemal post-GC RSS ~**0.80×** Boehm (Linux v0.16.0) |
| **macOS reclaim** | `mach_vm` punch-hole at host page size (16 KiB on Apple Silicon) |
| **Observability** | `Gcry.metrics`, `prometheus_text`, `Observability.json_stats` |
| **Fork** | `pthread_atfork` reinit (default); see [POLICY](docs/POLICY.md) |

---

## Scope (honest)

gcry is **production-curious** on Linux and macOS process GC at parallelism 1.
Windows is coming.

| Today | Later / elsewhere |
|-------|-------------------|
| **Linux + macOS** process GC (Crystal >= 1.21) | Windows process GC |
| Default ExecutionContext, **parallelism 1** (PERF headline) | Parallel **supported opt-in:** EC>1 + TLAB off + lazy (~79% `/json`); TLAB-on still experimental |
| Kemal-class thr/RSS near Boehm | Ultra-dense conservative-live apps may keep more RSS until stack maps |
| `LibC.fork` + atfork reinit | `Process.fork` under ExecutionContext (Crystal forbids it anyway) |

---

## Roadmap

```
  Phase 1  DONE  Conservative mark-sweep, STW, Linux + macOS     ✓
  Phase 2  NOW   Stack maps, barriers, Windows, -Dgc_gcry        ○
  Phase 3  NEXT  Performance parity, parallel mark, nursery def.  ◐
  Phase 4  GOAL  Crystal's default GC                             △
```

[Full plan →](./ROADMAP.md)

---

## Tuning (quick reference)

Defaults tuned for process GC. Change after you measure:

| Variable | Effect |
|----------|--------|
| `GCRY_SOUND=1` | Turn off every root-completeness heuristic (RSS-neutral; thr cost unresolved; **large pause cost where the root scan is big** — EC4 or a big heap) |
| `GCRY_KEEP_CHUNKS=1` | Keep empty chunks -> ~95% `/json` thr, ~3x RSS |
| `GCRY_THRESHOLD` | Bytes before auto-major (default 32 MiB) |
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
