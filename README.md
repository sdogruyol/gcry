# gcry

A garbage collector written in Crystal, intended as an alternative to [bdwgc](https://github.com/ivmai/bdwgc) (Boehm GC).

Ships as a **shard**: reopen Crystal’s `GC` module under `-Dgc_none` — no Crystal compiler or stdlib patch required.

> **Status:** v0.4 — STW-default majors (sound), empty-chunk release opt-in, fork poison API. Phases 0–7 complete.
>
> - [DESIGN.md](DESIGN.md) — architecture, frozen API, roadmap
> - [docs/INTEGRATION.md](docs/INTEGRATION.md) — Crystal `GC` / fiber notes
> - [docs/HARDENING.md](docs/HARDENING.md) — stress, tuning, false retention
> - [docs/POLICY.md](docs/POLICY.md) — OOM, fork, signal safety
> - [docs/COMPARISON.md](docs/COMPARISON.md) — bdwgc comparison checklist
> - [docs/PERF.md](docs/PERF.md) — Kemal wrk version-over-version log
> - [CHANGELOG.md](CHANGELOG.md) — notable changes

## Why

Crystal ships with Boehm today (`boehm` backend) and also supports `gc_none`. **gcry** replaces the `gc_none` stubs at require-time with a conservative mark–sweep collector implemented in Crystal — no Crystal compiler/stdlib patch required.

## Goals

- Match Crystal’s `GC` API (`malloc`, `malloc_atomic`, `collect`, fiber roots, finalizers, stats, …)
- Conservative stop-the-world mark–sweep on Linux x86_64 under Crystal 1.21+ `Fiber::ExecutionContext` (parallelism 1)
- Nursery + incremental mark slices (no write barriers / no parallel contexts yet)
- Allocation-free collector core (no managed-heap allocations during collect)
- Activate via `require "gcry"` + `-Dgc_none`

Details, non-goals, and phased roadmap live in [DESIGN.md](DESIGN.md).

## Supported platforms (v0.4)

| | |
|--|--|
| OS / arch | Linux x86_64 (primary); aarch64 cross-build experimental in CI |
| Crystal | `>= 1.21.0` |
| Runtime | Default `Fiber::ExecutionContext` (parallelism 1) — **not** parallel contexts / deprecated `-Dpreview_mt` |
| Fork / signals | See [docs/POLICY.md](docs/POLICY.md) |

## Requirements

- Crystal `>= 1.21.0`

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  gcry:
    github: sdogruyol/gcry
```

```sh
shards install
```

## Usage

Require gcry early when building with the null GC, then compile with `-Dgc_none`:

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

Without `-Dgc_none`, Crystal links Boehm; do not install gcry as the process GC in that mode.

There is no separate application-level allocator API for normal programs: allocations go through Crystal’s runtime (`GC.malloc` / language allocations). The shard overrides `GC` underneath.

### Tuning

| Variable | Effect |
|----------|--------|
| `GCRY_THRESHOLD` | Bytes since last major before auto-collect (process default **64 MiB**) |
| `GCRY_DISABLE_AUTO=1` | Disable major auto-collect |
| `GCRY_NURSERY` | Opt-in nursery; young bytes before minor (default off in process GC) |
| `GCRY_DISABLE_NURSERY=1` | Keep nursery disabled (process default) |
| `GCRY_DISABLE_INCREMENTAL=1` | Full STW major on threshold (process **default** since v0.4) |
| `GCRY_INCREMENTAL=1` | Experimental sliced auto-majors (unsafe without write barriers) |
| `GCRY_INCREMENTAL_WORK` | Mark work units per `collect_a_little` slice (default `1024`) |
| `GCRY_RELEASE_CHUNKS=1` | Munmap fully free size-class chunks after major |

More detail: [docs/HARDENING.md](docs/HARDENING.md), [docs/POLICY.md](docs/POLICY.md). Pause times: `Gcry.pause_stats` (`last_ns` / `max_ns` / `total_ns` / `count`).

## Performance (v0.4)

Version-over-version Kemal wrk log: **[docs/PERF.md](docs/PERF.md)** (canonical). Measures **`/`** and **`/json`** (`wrk -c 100 -d 30`, fresh process per path).

Same-host A/B **0.3.0 → 0.4.0** (Crystal 1.21.0, WSL2 x86_64, 2026-07-23):

| Path | 0.3.0 req/s | 0.4.0 req/s | Δ req/s | Δ lat.avg |
|------|------------:|------------:|--------:|----------:|
| `/` | 78360 | **76254** | **−2.7%** | **+0.5%** |
| `/json` | 32331 | **32141** | **−0.6%** | **−0.4%** |

0.4.0 is throughput-neutral vs 0.3.0; defaults to **full STW** majors (incremental opt-in) for correctness under JSON/Hash mutation.

What moved the needle (process GC defaults):

- Nursery **off** by default (opt-in via `GCRY_NURSERY`) — minors without write barriers were scanning all old objects
- Major threshold **64 MiB** (`PROCESS_GC_THRESHOLD`; override with `GCRY_THRESHOLD`)
- **Incremental auto-majors** (v0.3) — threshold hits run `collect_a_little` slices instead of one long STW
- Cached `/proc/self/maps` static-root ranges; skip bulky `libcrypto` / `libssl` / `libpcre` segments
- O(log n) chunk index for mark pointer lookup

Library-heap microbench: `make bench` → `./bin/churn`. Process-GC load test: `make bench-kemal-wrk` (runs `/` and `/json`). Record a release: `make bench-kemal-record PREV=v0.3.0 LABEL=0.4.0`.

Still not a drop-in Boehm replacement for the tightest latency SLOs — majors remain stop-the-world — but HTTP dogfooding throughput is in the same ballpark.

## Development

```sh
make spec          # unit specs under Boehm
make samples       # build -Dgc_none samples into bin/
make bench         # library-heap churn bench
make bench-kemal-wrk  # Kemal + wrk on / and /json (-c 100 -d 30)
make bench-kemal-record PREV=v0.3.0 LABEL=0.4.0  # A/B both paths → PERF.md rows
make format-check
```

Or directly:

```sh
crystal spec
crystal build -Dgc_none samples/stress.cr -o bin/stress && ./bin/stress 300
crystal build bench/churn.cr -o bin/churn && ./bin/churn 2000
cd bench/kemal && shards install
crystal build -Dgc_none --release src/server.cr -o ../../bin/kemal-gcry
PORT=3001 ../../bin/kemal-gcry
# then: wrk -c 100 -d 30 http://127.0.0.1:3001/
#       wrk -c 100 -d 30 http://127.0.0.1:3001/json
```

Heap unit tests run under the default (Boehm) GC while `Gcry::*` is exercised as a standalone allocator. Process-GC samples need `-Dgc_none`.

Roadmap phases 0–7 are complete — see [DESIGN.md](DESIGN.md). Policies and comparison notes: [docs/POLICY.md](docs/POLICY.md), [docs/COMPARISON.md](docs/COMPARISON.md).

## Contributing

1. Fork the repo
2. Create your branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push the branch (`git push origin my-new-feature`)
5. Open a Pull Request

Please keep collector hot paths free of managed-heap allocations, and prefer small, testable modules (`heap`, `mark`, `sweep`, `roots`).

## License

MIT — see [LICENSE](LICENSE).

## Contributors

- [Serdar Dogruyol](https://github.com/sdogruyol) — creator and maintainer
