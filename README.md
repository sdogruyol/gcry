<p align="center">
  <img src="assets/logo.svg" alt="gcry" width="400"/>
</p>

# gcry

**Crystal’s GC, written in Crystal.**

Boehm is fine. gcry is yours to read, change, and ship — a real mark–sweep collector as a **shard**, not a C dependency you hope never breaks. One flag (`-Dgc_none`) and the process runs on gcry.

> **v0.9** · Linux **x86_64 + aarch64** · Crystal ≥ 1.21 · fibers on one OS thread

Same-host Kemal vs Boehm (`wrk -c 100 -d 30`, median of 3): **`/json` ~92% thr**, post-GC RSS **~0.97×**. Not a toy. See [docs/PERF.md](docs/PERF.md).

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

| Workload | gcry vs Boehm (v0.9.0) |
|----------|----------------------:|
| Alloc-heavy JSON (`/json`) thr | **~92%** |
| Idle `/` thr | **~89%** |
| `/json` post-GC RSS | **~0.97×** |
| `/json` + `GCRY_KEEP_CHUNKS=1` | ~**95%** thr @ ~**3×** RSS |

Details & methodology: [docs/PERF.md](docs/PERF.md). Re-run: `make bench-kemal-wrk` or `./bench/median_kemal_boehm.sh`.

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

## What you get

| | |
|--|--|
| **Conservative mark–sweep** | Safe for today’s Crystal ABI; scans for pointer-shaped words |
| **Stop-the-world** | Clear pauses; histogram via `Gcry.pause_stats` / Prometheus |
| **Non-moving** | Stable addresses — no compacting surprises |
| **Fiber roots** | Stacks + parked fibers; STW SP clamp on other threads |
| **Layout-precise scan** | Opt-in / builtins — fewer false keeps where registered |
| **Empty-chunk release** | Default-on munmap — Kemal post-GC RSS at Boehm parity |
| **Observability** | `Gcry.metrics`, `prometheus_text`, `Observability.json_stats` |
| **Fork path** | `pthread_atfork` reinit (default); see [POLICY](docs/POLICY.md) |

Same family as Boehm. Roadmap beyond this (precise maps, concurrent mark, always-on nursery) is explicit — not papered over.

## Scope (honest, not shy)

gcry is **production-curious on Linux process GC** at parallelism **1**. It is not trying to be every platform tomorrow.

| In scope today | Later / elsewhere |
|----------------|-------------------|
| Linux x86_64 + aarch64 process GC | macOS / Windows process GC (stubs only for now) |
| Default ExecutionContext, **parallelism 1** | Parallel contexts: experimental (`GCRY_TLAB=1`; measure) |
| Kemal-class thr/RSS near Boehm | Ultra-dense conservative-live apps may keep more RSS until stack maps |
| `LibC.fork` + atfork reinit | `Process.fork` under ExecutionContext (Crystal forbids it) |

Full checklist: [docs/COMPARISON.md](docs/COMPARISON.md).

## Docs

| Doc | |
|-----|--|
| [DESIGN.md](DESIGN.md) | Architecture & roadmap |
| [docs/PERF.md](docs/PERF.md) | Speed vs Boehm |
| [docs/COMPARISON.md](docs/COMPARISON.md) | gcry vs Boehm |
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | Crystal `GC` wiring |
| [docs/HARDENING.md](docs/HARDENING.md) | Env knobs & stress |
| [docs/POLICY.md](docs/POLICY.md) | OOM, fork, signals |
| [docs/API.md](docs/API.md) | Public API + `/metrics` |
| [docs/ANNOUNCE.md](docs/ANNOUNCE.md) | Release blurb draft |
| [CHANGELOG.md](CHANGELOG.md) | Per-version history |

## Platforms

| | |
|--|--|
| OS / arch | Linux x86_64 + aarch64 (process GC); macOS type-check stubs |
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
| `GCRY_DISABLE_TYPE_ID_GATE=1` | Disable root type_id filter |
| `GCRY_DISABLE_LAYOUT=1` | Disable layout-precise heap scan |
| `GCRY_DISABLE_SP_CLAMP=1` | No RSP clamp on other-thread stacks |
| `GCRY_DISABLE_MADVISE=1` | Skip `MADV_DONTNEED` helpers |
| `GCRY_AUTO_LAYOUTS=1` | `Gcry.register_layouts` at init (measure thr) |
| `GCRY_DISABLE_ATFORK=1` | No `pthread_atfork`; post-fork GC raises |
| `GCRY_KEEP_CHUNKS=1` | Keep empty chunks mapped (~**95%** `/json` thr, ~**3×** RSS) |
| `GCRY_RELEASE_CHUNKS=1` | Force empty-chunk release (already default-on) |
| `GCRY_EMPTY_CHUNK_RETAIN` | Empty-chunk retain budget (`MADV_DONTNEED`; default **0**) |
| `GCRY_INTERIOR=1` | Interior pointers on ambient roots (heap marks always allow for `Array#shift`) |
| `GCRY_PAGE_DONTNEED=1` | Sparse free-page `MADV_DONTNEED` (STW-heavy) |
| `GCRY_LARGE_CACHE` | Large-object cache retain (default **8 MiB**) |
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
