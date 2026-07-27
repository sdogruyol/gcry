<p align="center">
  <img src="assets/logo.svg" alt="gcry" width="240"/>
</p>

<h1 align="center">gcry</h1>

<p align="center">
  <b>The garbage collector Crystal deserves — written in Crystal.</b><br>
  <i>Conservative mark–sweep. Ship as a shard. One flag replaces Boehm.</i>
</p>

<p align="center">
  <a href="https://github.com/sdogruyol/gcry/stargazers"><img src="https://img.shields.io/github/stars/sdogruyol/gcry?style=flat-square&logo=github" alt="Stars"></a>
  <a href="https://crystal-lang.org"><img src="https://img.shields.io/badge/Crystal-%3E%3D1.21-000?style=flat-square&logo=crystal" alt="Crystal"></a>
  <a href="https://github.com/sdogruyol/gcry/actions"><img src="https://img.shields.io/github/actions/workflow/status/sdogruyol/gcry/ci.yml?branch=main&style=flat-square&logo=githubactions&label=CI" alt="CI"></a>
  <a href="docs/PERF.md"><img src="https://img.shields.io/badge/Kemal%20%2Fjson-%E2%89%8889%25%20of%20Boehm-f5a623?style=flat-square" alt="Benchmark"></a>
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

**Kemal `/json`: ~89% of Boehm throughput, post-GC RSS ~0.95x.**  
**Fat app (acikturkiye): ~93% throughput, RSS ~2.65x.**

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

## The moment you missed this

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

10 seconds. Or faster with Docker:

```sh
docker run --rm -v "$PWD:/app" crystallang/crystal:1.21.0 \
  sh -c "cd /app && shards install && crystal build -Dgc_none samples/hello.cr -o /tmp/hello && /tmp/hello"
```

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

| Workload | gcry vs Boehm (v0.13.0) |
|----------|------------------------:|
| Kemal `/json` throughput | **~89%** (~95% with `GCRY_KEEP_CHUNKS=1`) |
| Kemal `/json` post-GC RSS | **~0.95x** |
| Kemal `/` throughput | **~90%** |
| Fat app `/api/v1/` throughput | **~93%** |
| Fat app `/api/v1/` RSS | **~2.65x** |

### macOS (Apple Silicon)

| Workload | gcry vs Boehm (v0.13.0) |
|----------|------------------------:|
| Kemal `/json` throughput | **~84%** |
| Kemal `/json` post-GC RSS | **~0.93x** |
| Kemal `/` throughput | **~93%** |
| Fat app `/api/v1/` throughput | **~78%** |

Detailed tables: [PERF.md](docs/PERF.md) · [PERF-macos.md](docs/PERF-macos.md) · [ACIKTURKIYE.md](docs/ACIKTURKIYE.md)

That fat-app RSS (2.65x) is an honest number. Stack maps will bring it to ~1.2x.
Until then, we live with this reality. We don't hide our numbers.

---

## Feature set

| Feature | Description |
|---------|-------------|
| **Conservative mark-sweep** | Safe for today's Crystal ABI; scans for pointer-shaped words |
| **Stop-the-world** | Linux signals / Darwin Mach suspend; HDR histogram via `Gcry.pause_stats` |
| **Non-moving** | Stable addresses — no compaction surprises |
| **Fiber roots** | Stacks + parked fibers; STW SP clamp on other threads |
| **Layout-precise scan** | Builtins + opt-in — fewer false keeps where registered |
| **Empty-chunk release** | On by default — Kemal post-GC RSS at Boehm parity |
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
| Default ExecutionContext, **parallelism 1** | Parallel contexts: experimental (`GCRY_TLAB=1`; measure) |
| Kemal-class thr/RSS near Boehm | Ultra-dense conservative-live apps may keep more RSS until stack maps |
| `LibC.fork` + atfork reinit | `Process.fork` under ExecutionContext (Crystal forbids it anyway) |

---

## Roadmap

```
┌─────────────────────────────────────────────────────────────┐
│ Phase 1  DONE: Conservative mark-sweep, STW, Linux+macOS   │ ✅
│ Phase 2  NOW: Stack maps, barriers, Windows, -Dgc_gcry     │ 🔄
│ Phase 3  NEXT: Performance parity with Boehm, parallel mark │ 📋
│ Phase 4  GOAL: Crystal's default GC                        │ 🎯
└─────────────────────────────────────────────────────────────┘
```

[Full plan →](./ROADMAP.md)

---

## Tuning (quick reference)

Defaults tuned for process GC. Change after you measure:

| Variable | Effect |
|----------|--------|
| `GCRY_KEEP_CHUNKS=1` | Keep empty chunks → ~95% `/json` thr, ~3x RSS |
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
| [docs/API.md](docs/API.md) | Public API + `/metrics` |
| [docs/POLICY.md](docs/POLICY.md) | OOM, fork, signals |
| [CHANGELOG.md](CHANGELOG.md) | Version history |

---

## Contributing

1. Fork → branch → commit → push → PR
2. Collector hot paths: **no managed-heap allocation**
3. Prefer small modules (`heap`, `mark`, `sweep`, `roots`)
4. Stuck? [good first issues](https://github.com/sdogruyol/gcry/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)

---

## Development

```sh
make spec             # unit specs under Boehm
make samples          # -Dgc_none samples → bin/
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

<sub>Tried it? Star it. Haven't tried it? Try it first, then star it.
No, really — one `crystal build -Dgc_none` and you'll understand.</sub>