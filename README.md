# gcry

**A garbage collector written in Crystal** — an alternative to the C [Boehm GC](https://github.com/ivmai/bdwgc) that Crystal normally uses.

> **v0.6** · Linux x86_64 · Crystal ≥ 1.21 · one OS thread (fibers OK)

Install as a shard. No Crystal compiler patch. Flip one build flag and your program runs on gcry instead of Boehm.

---

## In plain English

Programs allocate memory (objects, strings, hashes…). Eventually some of that memory is unused. A **garbage collector** finds the unused bits and gives them back so the app doesn’t grow forever.

**gcry** does that job for Crystal apps — but the collector itself is written in Crystal, not in C.

### What kind of GC is this?

Think of it like a librarian who, every so often, **pauses the whole library**, walks the shelves looking for anything that *looks like* a book reference, keeps those books, and recycles the rest.

| Idea | Meaning for gcry |
|------|------------------|
| **Conservative** | It doesn’t get a perfect map of “this field is a pointer.” It scans memory for values that *might* be pointers. Safe for today’s Crystal; sometimes keeps a little extra memory. |
| **Mark–sweep** | First **mark** everything still in use, then **sweep** (free) the rest. |
| **Stop-the-world (STW)** | While collecting, your app pauses briefly. Default mode: full pause, then continue. |
| **Non-moving** | Objects stay at the same address. No compacting / reshuffling the heap. |

**Same family as Boehm** (conservative mark–sweep). **Not** (yet): precise GC, concurrent GC, or “always generational” GC.

### What it is *not* (yet)

- Not a drop-in for multi-threaded / parallel ExecutionContexts (stick to parallelism **1**)
- Not fork-safe like Boehm’s fork handling
- Not as battle-tested as Boehm on every workload (Kemal `/json` ~**100%** of Boehm on this host; see [docs/PERF.md](docs/PERF.md))

---

## Docs

| Doc | What it’s for |
|-----|----------------|
| [DESIGN.md](DESIGN.md) | Architecture & roadmap |
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | How it plugs into Crystal’s `GC` |
| [docs/HARDENING.md](docs/HARDENING.md) | Tuning & stress |
| [docs/POLICY.md](docs/POLICY.md) | OOM, fork, signals |
| [docs/COMPARISON.md](docs/COMPARISON.md) | gcry vs Boehm checklist |
| [docs/PERF.md](docs/PERF.md) | Speed vs Boehm (%) |
| [CHANGELOG.md](CHANGELOG.md) | What changed per version |

## Why gcry exists

Crystal ships with Boehm (`boehm` backend) and a stub (`gc_none`). **gcry** fills `gc_none`: you get a real collector you can read, change, and dogfood in Crystal — without forking the compiler.

## Quick start

**1.** Add to `shard.yml`:

```yaml
dependencies:
  gcry:
    github: sdogruyol/gcry
```

```sh
shards install
```

**2.** Require it when using the null GC, then build with `-Dgc_none`:

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

Without `-Dgc_none`, Crystal still uses Boehm — don’t expect gcry to be the process GC in that mode.

Your code keeps allocating normally (`String`, `Array`, …). gcry sits under Crystal’s `GC` module; there’s no separate “call gcry.malloc” API for everyday apps.

### Platforms

| | |
|--|--|
| OS / arch | Linux x86_64 (primary); aarch64 cross-compile smoke in CI |
| Crystal | `>= 1.21.0` |
| Runtime | Default `Fiber::ExecutionContext`, **parallelism 1** |
| Fork / signals | See [docs/POLICY.md](docs/POLICY.md) |

### Tuning (optional)

| Variable | Effect |
|----------|--------|
| `GCRY_THRESHOLD` | Bytes since last major before auto-collect (process default **64 MiB**) |
| `GCRY_DISABLE_AUTO=1` | Disable major auto-collect |
| `GCRY_NURSERY` | Opt-in nursery (default **off**); sound under HTTP but slow without soft-dirty |
| `GCRY_DISABLE_NURSERY=1` | Keep nursery disabled (process default) |
| `GCRY_DISABLE_INCREMENTAL=1` | Full STW major (process **default**) |
| `GCRY_INCREMENTAL=1` | Experimental sliced majors (unsafe without write barriers) |
| `GCRY_INCREMENTAL_WORK` | Mark work units per slice (default `1024`) |
| `GCRY_RELEASE_CHUNKS=1` | Return empty chunks to the OS (opt-in; ~92% of Boehm `/json`; little acikturkiye RSS win) |
| `GCRY_KEEP_CHUNKS=1` | Force chunks retained |
| `GCRY_LARGE_CACHE` | Free large-object bytes to retain after trim (default **32 MiB**) |
| `GCRY_CHUNK_BYTES` | Size-class chunk mmap size (default **262144** / 256 KiB; min 64 KiB, page-aligned) |

More: [docs/HARDENING.md](docs/HARDENING.md). Pauses: `Gcry.pause_stats` (`last_ns` / `p50_ns` / `p99_ns` / `max_ns` / `total_ns` / `count`).

## How fast is it?

Same machine, vs Boehm (`wrk -c 100 -d 30`). Higher % = closer to Boehm. Prefer **`/json`**.

| Workload | gcry vs Boehm |
|----------|-------------:|
| Idle HTTP (`/`) | **~105%** |
| Alloc-heavy JSON (`/json`) | **~100%** |
| `/json` + chunk release | **~92%** (still opt-in) |

Details: [docs/PERF.md](docs/PERF.md). Microbench: `make bench`. HTTP: `make bench-kemal-wrk`.

## Development

```sh
make spec          # unit specs under Boehm
make samples       # build -Dgc_none samples into bin/
make bench         # library-heap churn
make bench-kemal-wrk  # Kemal + wrk on / and /json
make format-check
```

Heap unit tests run under Boehm while `Gcry::*` is tested as a standalone allocator. Process-GC samples need `-Dgc_none`.

## Contributing

1. Fork → branch → commit → push → PR
2. Keep collector hot paths free of managed-heap allocations
3. Prefer small modules (`heap`, `mark`, `sweep`, `roots`)

## License

MIT — see [LICENSE](LICENSE).

## Contributors

- [Serdar Dogruyol](https://github.com/sdogruyol) — creator and maintainer
