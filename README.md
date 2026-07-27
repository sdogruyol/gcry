<p align="center">
  <img src="assets/logo.svg" alt="gcry" width="200"/>
</p>

# gcry

**Crystal's GC, written in Crystal. Ship it with `require "gcry"` + `-Dgc_none`.**

[![Stars](https://img.shields.io/github/stars/sdogruyol/gcry)](https://github.com/sdogruyol/gcry)
[![Crystal](https://img.shields.io/badge/Crystal-%3E%3D1.21-000)](https://crystal-lang.org)
[![Platform](https://img.shields.io/badge/Linux-macOS-blue)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()
[![Benchmark](https://img.shields.io/badge/Kemal%20%2Fjson-~89%25%20of%20Boehm-orange)](https://github.com/sdogruyol/gcry)

Boehm is fine. gcry is yours to read, change, and ship — a real mark-sweep collector
as a **shard**, not a C dependency you hope never breaks.

One flag (`-Dgc_none`) and the process runs on gcry. Linux + macOS, x86_64 + ARM64.

---

## Quick Start

**1.** Add to `shard.yml`:

```yaml
dependencies:
  gcry:
    github: sdogruyol/gcry
```

```sh
shards install
```

**2.** Require under the null GC:

```crystal
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

puts "hello from gcry"
```

**3.** Build with `-Dgc_none`:

```sh
crystal build -Dgc_none app.cr -o app
./app
```

No special malloc API. gcry reopens Crystal's `GC` module. Without `-Dgc_none`,
Boehm stays in charge.

> Darwin note: Crystal **≥ 1.21** on macOS (Fiber::ExecutionContext / Monitor contract).
> Older toolchains hang under HTTP STW.

---

## Why gcry, not Boehm?

| | gcry | Boehm |
|--|------|-------|
| Language | **Crystal** | C |
| Integration | Shard (`-Dgc_none`) | Built-in C library |
| Read & debug | Stack traces in Crystal | C frames |
| Modify & ship | `shards update` | Recompile C, patch Crystal |
| Metrics | HDR histograms, Prometheus, `/gc-stats` | Nothing built-in |
| Ownership | Crystal community owns it | Upstream C project |

---

## Performance

One number that matters: **gcry req/s ÷ Boehm req/s** on the same host.
Absolute wrk is host noise; **% of Boehm** is the score.
Prefer `/json` (alloc-heavy) — idle `/` is sanity.

### Linux (v0.13.0, scrub default-on)

| Workload | gcry vs Boehm |
|----------|--------------:|
| Kemal `/json` thr | **~89%** (~95% with `GCRY_KEEP_CHUNKS=1`) |
| Kemal `/json` post-GC RSS | **~0.95×** |
| Kemal `/` thr | **~90%** |
| Fat app `/api/v1/` thr | **~93%** |
| Fat app `/api/v1/` RSS | **~2.65×** |

### macOS (v0.13.0, 256 KiB chunk default)

| Workload | gcry vs Boehm |
|----------|--------------:|
| Kemal `/json` thr | **~84%** |
| Kemal `/json` post-GC RSS | **~0.93×** |
| Kemal `/` thr | **~93%** |
| Fat app `/api/v1/` thr | **~78%** |

Methodology & full tables: [docs/PERF.md](docs/PERF.md) (Linux),
[docs/PERF-macos.md](docs/PERF-macos.md) (macOS).

---

## Roadmap

gcry aims to earn its place as Crystal's default GC. Four phase plan:

- **HERE** — Conservative mark-sweep, STW, Linux + macOS, observability
- **Phase 2** — Compiler stack maps, write barriers, Windows, `-Dgc_gcry` compiler flag
- **Phase 3** — Throughput parity, parallel mark, nursery default-on
- **Phase 4** — Default GC, concurrent collection, compaction

[Full roadmap →](./ROADMAP.md)

---

## What you get

| | |
|--|--|
| **Conservative mark-sweep** | Safe for today's Crystal ABI; scans for pointer-shaped words |
| **Stop-the-world** | Linux signals / Darwin Mach suspend; histogram via `Gcry.pause_stats` |
| **Non-moving** | Stable addresses — no compacting surprises |
| **Fiber roots** | Stacks + parked fibers; STW SP clamp on other threads |
| **Layout-precise scan** | Builtins + opt-in — fewer false keeps where registered |
| **Empty-chunk release** | Default-on munmap — Kemal post-GC RSS at Boehm parity |
| **macOS reclaim** | `mach_vm` punch-hole at host page size (16 KiB on Apple Silicon) |
| **Observability** | `Gcry.metrics`, `prometheus_text`, `Observability.json_stats` |
| **Fork path** | `pthread_atfork` reinit (default); see [POLICY](docs/POLICY.md) |

---

## Scope

gcry is **production-curious** on Linux and macOS process GC at parallelism 1.

| In scope today | Later / elsewhere |
|----------------|-------------------|
| **Linux + macOS** process GC (Crystal ≥ 1.21) | Windows process GC; soft-dirty on Darwin |
| Default ExecutionContext, **parallelism 1** | Parallel contexts: experimental (`GCRY_TLAB=1`; measure) |
| Kemal-class thr/RSS near Boehm | Ultra-dense conservative-live apps may keep more RSS until stack maps |
| `LibC.fork` + atfork reinit | `Process.fork` under ExecutionContext (Crystal forbids it) |

Full checklist: [docs/COMPARISON.md](docs/COMPARISON.md).

---

## Try it in 10 seconds

```sh
docker run --rm -v "$PWD:/app" crystallang/crystal:1.21.0 \
  sh -c "cd /app && shards install && crystal build -Dgc_none samples/hello.cr -o /tmp/hello && /tmp/hello"
```

---

## Docs

| Doc | |
|-----|--|
| [DESIGN.md](DESIGN.md) | Architecture & roadmap |
| [ROADMAP.md](./ROADMAP.md) | Public plan to become Crystal's default GC |
| [docs/PERF.md](docs/PERF.md) | Speed vs Boehm (Linux cut) |
| [docs/PERF-macos.md](docs/PERF-macos.md) | Speed vs Boehm (macOS cut) |
| [docs/COMPARISON.md](docs/COMPARISON.md) | gcry vs Boehm |
| [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md) | Fat-app dogfood (Linux) |
| [docs/ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md) | Fat-app dogfood (Darwin) |
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | Crystal `GC` wiring |
| [docs/HARDENING.md](docs/HARDENING.md) | Env knobs & stress |
| [docs/POLICY.md](docs/POLICY.md) | OOM, fork, signals |
| [docs/API.md](docs/API.md) | Public API + `/metrics` |
| [docs/ANNOUNCE.md](docs/ANNOUNCE.md) | Release blurb draft |
| [CHANGELOG.md](CHANGELOG.md) | Per-version history |

---

## Tuning (tl;dr)

Defaults are tuned for process GC. Escape hatches when you measure:

| Variable | Effect |
|----------|--------|
| `GCRY_THRESHOLD` | Bytes since last major before auto-collect (default 32 MiB) |
| `GCRY_KEEP_CHUNKS=1` | Keep empty chunks → ~95% `/json` thr, ~3x RSS |
| `GCRY_INCREMENTAL=1` | Sliced majors + dirty re-scan (measure first) |
| `GCRY_PARALLEL_MARK=N` | Experimental mark workers (default 1) |
| `GCRY_NURSERY=1` | Opt-in nursery (default off for process HTTP) |
| `GCRY_AUTO_LAYOUTS=1` | Whole-program precise layouts (~‑7pp `/json` thr on Linux) |
| `GCRY_STRESS=1` | Collect every N allocs (debug help) |

Full list: [docs/HARDENING.md](docs/HARDENING.md). Pauses: `Gcry.pause_stats`.

---

## Development

```sh
make spec             # unit specs under Boehm
make samples          # -Dgc_none samples → bin/
make bench            # library-heap churn
make bench-kemal-wrk  # Kemal + wrk on / and /json
make format-check
```

Heap unit tests exercise `Gcry::*` as a library allocator under Boehm.
Process-GC samples need `-Dgc_none`.

---

## Contributing

1. Fork → branch → commit → push → PR
2. Collector hot paths: **no** managed-heap allocation
3. Prefer small modules (`heap`, `mark`, `sweep`, `roots`)
4. Looking for a place to start? Check [good first issues](https://github.com/sdogruyol/gcry/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
   — Windows stubs, benchmark workloads, spec coverage.

---

## License

MIT — see [LICENSE](LICENSE).

## Contributors

- [Serdar Dogruyol](https://github.com/sdogruyol) — creator and maintainer