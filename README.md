# gcry

A garbage collector written in Crystal, intended as an alternative to [bdwgc](https://github.com/ivmai/bdwgc) (Boehm GC).

Ships as a **shard**: reopen Crystal’s `GC` module under `-Dgc_none` — no Crystal compiler or stdlib patch required.

> **Status:** Phase 7 complete — productized v0.1 (docs, policies, tuning, CI).
>
> - [DESIGN.md](DESIGN.md) — architecture, frozen API, roadmap
> - [docs/INTEGRATION.md](docs/INTEGRATION.md) — Crystal `GC` / fiber notes
> - [docs/HARDENING.md](docs/HARDENING.md) — stress, tuning, false retention
> - [docs/POLICY.md](docs/POLICY.md) — OOM, fork, signal safety
> - [docs/COMPARISON.md](docs/COMPARISON.md) — bdwgc comparison checklist
> - [CHANGELOG.md](CHANGELOG.md) — notable changes

## Why

Crystal ships with Boehm today (`boehm` backend) and also supports `gc_none`. **gcry** replaces the `gc_none` stubs at require-time with a conservative mark–sweep collector implemented in Crystal — no Crystal compiler/stdlib patch required.

## Goals

- Match Crystal’s `GC` API (`malloc`, `malloc_atomic`, `collect`, fiber `set_stackbottom`, finalizers, stats, …)
- Conservative stop-the-world mark–sweep on Linux x86_64 (single-threaded + fibers)
- Nursery + incremental mark slices (no write barriers / no `preview_mt` yet)
- Allocation-free collector core (no managed-heap allocations during collect)
- Activate via `require "gcry"` + `-Dgc_none`

Details, non-goals, and phased roadmap live in [DESIGN.md](DESIGN.md).

## Supported platforms (v0.1)

| | |
|--|--|
| OS / arch | Linux x86_64 (primary); aarch64 cross-build experimental in CI |
| Crystal | `>= 1.21.0` |
| Threading | Single-threaded + Crystal fibers — **not** `-Dpreview_mt` |
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
| `GCRY_THRESHOLD` | Bytes since last major before auto-collect (default `4194304`) |
| `GCRY_DISABLE_AUTO=1` | Disable major auto-collect |
| `GCRY_NURSERY` | Young bytes before minor collect (default `524288` in process GC) |
| `GCRY_DISABLE_NURSERY=1` | Disable nursery / minor collections |

More detail: [docs/HARDENING.md](docs/HARDENING.md), [docs/POLICY.md](docs/POLICY.md).

## Development

```sh
make spec          # unit specs under Boehm
make samples       # build -Dgc_none samples into bin/
make bench         # library-heap churn bench
make format-check
```

Or directly:

```sh
crystal spec
crystal build -Dgc_none samples/stress.cr -o bin/stress && ./bin/stress 300
crystal build bench/churn.cr -o bin/churn && ./bin/churn 2000
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
