# gcry

**A garbage collector written in Crystal** — an alternative to the C [Boehm GC](https://github.com/ivmai/bdwgc) that Crystal normally uses.

> **v0.7** · Linux x86_64 · Crystal ≥ 1.21 · one OS thread (fibers OK)

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

- Parallel ExecutionContexts: experimental (`GCRY_TLAB=1`); stick to parallelism **1** for production
- Not a drop-in Boehm replacement on macOS / Windows yet
- Not as battle-tested as Boehm on every workload (Kemal `/json` thr ~**90%** of Boehm, post-GC RSS ~**0.93×**; see [docs/PERF.md](docs/PERF.md))

---

## Docs

| Doc | What it’s for |
|-----|----------------|
| [DESIGN.md](DESIGN.md) | Architecture & roadmap |
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | How it plugs into Crystal’s `GC` |
| [docs/HARDENING.md](docs/HARDENING.md) | Tuning & stress |
| [docs/POLICY.md](docs/POLICY.md) | OOM, fork, signals |
| [docs/COMPARISON.md](docs/COMPARISON.md) | gcry vs Boehm checklist |
| [docs/API.md](docs/API.md) | Public API + `/metrics` helpers |
| [docs/ANNOUNCE.md](docs/ANNOUNCE.md) | Release / forum announcement draft |
| [docs/PERF.md](docs/PERF.md) | Speed vs Boehm (%) |
| [CHANGELOG.md](CHANGELOG.md) | What changed per version |

## gcry or Boehm?

| Choose **gcry** when… | Stay on **Boehm** when… |
|----------------------|-------------------------|
| You want a Crystal-readable collector to hack / dogfood | You need macOS / Windows process GC today |
| Linux x86_64 or aarch64, Crystal ≥ 1.21, parallelism **1** | Parallel ExecutionContexts in production |
| Kemal-class HTTP thr ~90% of Boehm is acceptable | You need `Process.fork` under ExecutionContext |
| You’re OK with STW + conservative retention | You need Boehm’s battle-tested defaults everywhere |

See [docs/COMPARISON.md](docs/COMPARISON.md) for the full checklist.

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
| OS / arch | Linux x86_64 + aarch64 (process GC); macOS stubs only (no `-Dgc_none` yet) |
| Crystal | `>= 1.21.0` |
| Runtime | Default `Fiber::ExecutionContext`, **parallelism 1** |
| Fork / signals | See [docs/POLICY.md](docs/POLICY.md) |

### Tuning (optional)

| Variable | Effect |
|----------|--------|
| `GCRY_THRESHOLD` | Bytes since last major before auto-collect (process default **32 MiB**) |
| `GCRY_DISABLE_AUTO=1` | Disable major auto-collect |
| `GCRY_NURSERY` | Opt-in nursery (default **off**); soft-dirty works on WSL 6.18+ but HTTP heaps stay too dirty for a win |
| `GCRY_DISABLE_NURSERY=1` | Keep nursery disabled (process default) |
| `GCRY_SOFT_DIRTY_MAX` | Dirty-page scan only if dirty/total ≤ this % (default **25**) |
| `GCRY_DISABLE_SOFT_DIRTY=1` | Never use soft-dirty page scan |
| `GCRY_MPROTECT_BARRIER=1` | Force mprotect+SEGV barrier (process GC fallback) |
| `GCRY_DISABLE_MPROTECT=1` | Forbid mprotect barrier |
| `GCRY_DISABLE_INCREMENTAL=1` | Full STW major (process **default**) |
| `GCRY_INCREMENTAL=1` | Sliced majors + dirty-page re-scan when a barrier is armed |
| `GCRY_INCREMENTAL_WORK` | Mark work units per slice (default `1024`) |
| `GCRY_STRESS=1` | Torture: collect every N allocs (`GCRY_STRESS_EVERY`, default **16**) |
| `GCRY_TLAB=1` | Thread-local alloc buffers (parallel ExecutionContexts) |
| `GCRY_PARALLEL_MARK=N` | Mark workers 1–16 (process: STW-exempt pthreads steal grey work; library: Crystal::Thread) |
| `GCRY_DISABLE_BLACKLIST=1` | Do not blacklist pages of type_id-gate false roots (process default **on**) |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | Disable root-only type_id filter (process default **on**) |
| `GCRY_DISABLE_LAYOUT=1` | Disable layout-precise heap scan |
| `GCRY_DISABLE_SP_CLAMP=1` | Full pthread stack range on other threads (no RSP clamp) |
| `GCRY_DISABLE_MADVISE=1` | Skip `MADV_DONTNEED` helpers |
| `GCRY_AUTO_LAYOUTS=1` | Run `Gcry.register_layouts` at init (opt-in; measure thr first) |
| `GCRY_DISABLE_ATFORK=1` | Do not register `pthread_atfork`; post-fork GC raises |
| `GCRY_KEEP_CHUNKS=1` | Keep empty chunks mapped (escape; ~**95%** `/json` thr, ~**3×** RSS) |
| `GCRY_RELEASE_CHUNKS=1` | Force empty-chunk release on (process **default** already releases) |
| `GCRY_EMPTY_CHUNK_RETAIN` | Bytes of empty chunks to keep dormant (`MADV_DONTNEED`; default **0** = munmap all) |
| `GCRY_INTERIOR=1` | Allow interior pointers on ambient roots (default **base-pointer-only** on roots; heap marks always allow interiors for `Array#shift`) |
| `GCRY_PAGE_DONTNEED=1` | Sparse-chunk free-page `MADV_DONTNEED` (STW-heavy; opt-in) |
| `GCRY_LARGE_CACHE` | Free large-object bytes to retain after trim (default **8 MiB**) |
| `GCRY_CHUNK_BYTES` | Size-class chunk mmap size (default **262144** / 256 KiB; min 64 KiB, page-aligned) |

More: [docs/HARDENING.md](docs/HARDENING.md). Pauses: `Gcry.pause_stats` (`last_ns` / `p50_ns` / `p99_ns` / `max_ns` / `total_ns` / `count`).

## How fast is it?

Same machine, vs Boehm (`wrk -c 100 -d 30`). Higher % = closer to Boehm. Prefer **`/json`**.

| Workload | gcry vs Boehm |
|----------|-------------:|
| Alloc-heavy JSON (`/json`) thr | **~89%** (median of 3) |
| Idle `/` thr | **~91%** |
| `/json` post-GC RSS | **~0.93×** |
| `/json` + `GCRY_KEEP_CHUNKS=1` | ~**95%** thr @ ~**3×** RSS |

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
