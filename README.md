<p align="center">
  <img src="assets/logo.svg" alt="gcry" width="400"/>
</p>

# gcry

**Crystal’s GC, written in Crystal.**

Boehm is fine. gcry is yours to read, change, and ship — a real mark–sweep collector as a **shard**, not a C dependency you hope never breaks. One flag (`-Dgc_none`) and the process runs on gcry.

> **v0.11.0** · **Linux + macOS** · Crystal ≥ 1.21 · fibers on one OS thread

### macOS is real (v0.10)

Process GC on Darwin is no longer a stub. Mach STW, dyld roots, 16 KiB host-page reclaim — `require "gcry"` + `-Dgc_none` on Apple Silicon / Intel Macs (Crystal **≥ 1.21**).

Same-host Kemal on **macOS aarch64** (`wrk -c 100 -d 30`, median of 3): **`/json` ~90% thr**, post-GC RSS **~0.97×** Boehm. Details: [docs/PERF-macos.md](docs/PERF-macos.md).

**Linux** (last cut **v0.9.0**, still the Linux headline): **`/json` ~92% thr**, post-GC RSS **~0.97×** — [docs/PERF.md](docs/PERF.md). Do not mix Darwin wrk into Linux tables.

---

## Why this exists

Crystal ships Boehm and a stub (`gc_none`). The stub is a dead end for anyone who wants to **own** the collector. gcry fills that hole:

- **Shard, not a compiler fork** — `require "gcry"` + `-Dgc_none`
- **Crystal end-to-end** — heap, mark, sweep, STW, roots, metrics you can grep
- **Boehm-class model** — conservative, non-moving mark–sweep (the shape Crystal already assumes)
- **Dogfood-ready** — Kemal-class HTTP near Boehm on thr and RSS; fat apps under active measurement

If you care how your language reclaims memory, this is the repo.

## How fast?

Prefer **`/json`**. Absolute wrk is host-noisy; **% of Boehm** is the number that matters.

### Linux (version-cut headline — v0.9.0)

| Workload | gcry vs Boehm (v0.9.0, Linux) |
|----------|-----------------------------:|
| Alloc-heavy JSON (`/json`) thr | **~92%** |
| Idle `/` thr | **~89%** |
| `/json` post-GC RSS | **~0.97×** |
| `/json` + `GCRY_KEEP_CHUNKS=1` | ~**95%** thr @ ~**3×** RSS |

### macOS (v0.11.0 — side mark bitmap + retain 64 MiB)

| Workload | gcry vs Boehm (v0.11.0, macOS aarch64) |
|----------|---------------------------------------:|
| Alloc-heavy JSON (`/json`) thr | **~94%** |
| Idle `/` thr | **~100%** |
| `/json` p50 latency | **2.3 ms** (Boehm 1.8 ms) |
| `/json` post-GC RSS | **~10×** (bitmap pages; see [PERF-macos.md](docs/PERF-macos.md)) |

Details & methodology: [docs/PERF.md](docs/PERF.md) (Linux), [docs/PERF-macos.md](docs/PERF-macos.md) (Darwin). Re-run: `make bench-kemal-wrk` or `./bench/median_kemal_boehm.sh`.

## Drop in

**1.** `shard.yml`:

```yaml
dependencies:
  gcry:
    github: sdogruyol/gcry
```

```sh
shards install
```

**2.** Require under the null GC, build with `-Dgc_none`:

```crystal
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

puts "hello"
```

```sh
crystal build -Dgc_none app.cr -o app
./app
```

No special malloc API — `String`, `Array`, … allocate as usual. gcry reopens Crystal’s `GC` module. Without `-Dgc_none`, Boehm stays in charge.

**Crystal ≥ 1.21** on macOS (ExecutionContext / Monitor contract). Older toolchains hang under HTTP STW.

## What you get

| | |
|--|--|
| **Conservative mark–sweep** | Safe for today’s Crystal ABI; scans for pointer-shaped words |
| **Stop-the-world** | Linux signals / Darwin Mach suspend; histogram via `Gcry.pause_stats` |
| **Non-moving** | Stable addresses — no compacting surprises |
| **Fiber roots** | Stacks + parked fibers; STW SP clamp on other threads |
| **Layout-precise scan** | Builtins + opt-in — fewer false keeps where registered |
| **Empty-chunk release** | Default-on munmap — Kemal post-GC RSS at Boehm parity |
| **macOS reclaim** | `mach_vm` punch-hole at host page size (16 KiB on Apple Silicon) |
| **Observability** | `Gcry.metrics`, `prometheus_text`, `Observability.json_stats` |
| **Fork path** | `pthread_atfork` reinit (default); see [POLICY](docs/POLICY.md) |

Same family as Boehm. Roadmap beyond this (precise maps, concurrent mark, always-on nursery) is explicit — not papered over.

## Scope (honest, not shy)

gcry is **production-curious** on Linux and macOS process GC at parallelism **1**. It is not trying to be every platform tomorrow.

| In scope today | Later / elsewhere |
|----------------|-------------------|
| **Linux + macOS** process GC (Crystal ≥ 1.21) | Windows process GC; soft-dirty on Darwin |
| Default ExecutionContext, **parallelism 1** | Parallel contexts: experimental (`GCRY_TLAB=1`; measure) |
| Kemal-class thr/RSS near Boehm | Ultra-dense conservative-live apps may keep more RSS until stack maps |
| `LibC.fork` + atfork reinit | `Process.fork` under ExecutionContext (Crystal forbids it) |

Full checklist: [docs/COMPARISON.md](docs/COMPARISON.md).

## Docs

| Doc | |
|-----|--|
| [DESIGN.md](DESIGN.md) | Architecture & roadmap |
| [docs/PERF.md](docs/PERF.md) | Speed vs Boehm (**Linux** cut) |
| [docs/PERF-macos.md](docs/PERF-macos.md) | Speed vs Boehm (**macOS** / v0.10) |
| [docs/COMPARISON.md](docs/COMPARISON.md) | gcry vs Boehm |
| [docs/ACIKTURKIYE.md](docs/ACIKTURKIYE.md) | Fat-app dogfood (Linux) |
| [docs/ACIKTURKIYE-macos.md](docs/ACIKTURKIYE-macos.md) | Fat-app dogfood (Darwin) |
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | Crystal `GC` wiring |
| [docs/HARDENING.md](docs/HARDENING.md) | Env knobs & stress |
| [docs/POLICY.md](docs/POLICY.md) | OOM, fork, signals |
| [docs/API.md](docs/API.md) | Public API + `/metrics` |
| [docs/ANNOUNCE.md](docs/ANNOUNCE.md) | Release blurb draft |
| [CHANGELOG.md](CHANGELOG.md) | Per-version history |

## Platforms

| | |
|--|--|
| OS / arch | **Linux** x86_64 + aarch64; **macOS** arm64 + x86_64 (process GC since **v0.10**) |
| Crystal | `>= 1.21.0` |
| Runtime | Default `Fiber::ExecutionContext`, **parallelism 1** |
| Fork / signals | [docs/POLICY.md](docs/POLICY.md) |

## Tuning (optional)

Defaults are tuned for process GC. Escape hatches when you measure:

| Variable | Effect |
|----------|--------|
| `GCRY_THRESHOLD` | Bytes since last major before auto-collect (process default **32 MiB**) |
| `GCRY_DISABLE_AUTO=1` | Disable major auto-collect |
| `GCRY_NURSERY` | Opt-in nursery (default **off** for process HTTP) |
| `GCRY_DISABLE_NURSERY=1` | Keep nursery off (process default) |
| `GCRY_SOFT_DIRTY_MAX` | Dirty-page scan only if dirty/total ≤ this % (default **25**) |
| `GCRY_DISABLE_SOFT_DIRTY=1` | Never use soft-dirty page scan |
| `GCRY_MPROTECT_BARRIER=1` | Force mprotect+SEGV barrier |
| `GCRY_DISABLE_MPROTECT=1` | Forbid mprotect barrier |
| `GCRY_DISABLE_INCREMENTAL=1` | Full STW major (process **default**) |
| `GCRY_INCREMENTAL=1` | Sliced majors + dirty re-scan when a barrier is armed |
| `GCRY_INCREMENTAL_WORK` | Mark work units per slice (default `1024`) |
| `GCRY_STRESS=1` | Collect every N allocs (`GCRY_STRESS_EVERY`, default **16**) |
| `GCRY_TLAB=1` | Thread-local alloc buffers (parallel contexts) |
| `GCRY_CLEAR_STACK=1` | Unused-stack wipe below SP (RSS experiment; every 16 allocs) |
| `GCRY_SCRUB_FIBERS=1` | Capped parked-fiber wipe before mark (RSS experiment) |
| `GCRY_PARALLEL_MARK=N` | **Experimental** mark workers (default **1**). Measure first — HTTP thr often regresses |
| `GCRY_DISABLE_BLACKLIST=1` | Skip page blacklist of type_id false roots |
| `GCRY_BLACKLIST=1` | Opt-in blacklist (Darwin process default is off) |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | Disable root type_id filter |
| `GCRY_DISABLE_LAYOUT=1` | Disable layout-precise heap scan |
| `GCRY_SCAN_CAPS=1` | Register `instance_sizeof` scan caps for all References |
| `GCRY_DISABLE_SP_CLAMP=1` | No RSP clamp on other-thread stacks |
| `GCRY_DISABLE_MADVISE=1` | Skip free-page physical release helpers |
| `GCRY_DISABLE_PAGE_RELEASE=1` | Darwin: disable default `mach_vm` free-page release |
| `GCRY_AUTO_LAYOUTS=1` | `Gcry.register_layouts` at init (measure thr) |
| `GCRY_DISABLE_ATFORK=1` | No `pthread_atfork`; post-fork GC raises |
| `GCRY_KEEP_CHUNKS=1` | Keep empty chunks mapped (~**95%** `/json` thr, ~**3×** RSS) |
| `GCRY_RELEASE_CHUNKS=1` | Force empty-chunk release (already default-on) |
| `GCRY_EMPTY_CHUNK_RETAIN` | Empty-chunk retain budget (`MADV_DONTNEED`; default **0**) |
| `GCRY_INTERIOR=1` | Interior pointers on ambient roots (heap marks always allow for `Array#shift`) |
| `GCRY_PAGE_DONTNEED=1` | Sparse free-page release (Linux opt-in; Darwin default-on @ host page size) |
| `GCRY_LARGE_CACHE` | Large-object cache retain (default **8 MiB**; Darwin process default **0**) |
| `GCRY_CHUNK_BYTES` | Size-class chunk mmap (default **256 KiB**) |

Full list: [docs/HARDENING.md](docs/HARDENING.md). Pauses: `Gcry.pause_stats`.

## Development

```sh
make spec             # unit specs under Boehm
make samples          # -Dgc_none samples → bin/
make bench            # library-heap churn
make bench-kemal-wrk  # Kemal + wrk on / and /json
make format-check
```

Heap unit tests exercise `Gcry::*` as a library allocator under Boehm. Process-GC samples need `-Dgc_none`.

## Contributing

1. Fork → branch → commit → push → PR
2. Collector hot paths: **no** managed-heap allocation
3. Prefer small modules (`heap`, `mark`, `sweep`, `roots`)

## License

MIT — see [LICENSE](LICENSE).

## Contributors

- [Serdar Dogruyol](https://github.com/sdogruyol) — creator and maintainer
