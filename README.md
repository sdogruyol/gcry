# gcry

A garbage collector written in Crystal, intended as an alternative to [bdwgc](https://github.com/ivmai/bdwgc) (Boehm GC).

Ships as a **shard**: reopen Crystal’s `GC` module under `-Dgc_none`, same integration style as [ysbaddaden/gc](https://github.com/ysbaddaden/gc) (Immix).

> **Status:** Phase 4 complete — use as process GC with `require "gcry"` + `-Dgc_none`.
>
> - [DESIGN.md](DESIGN.md) — architecture, frozen API, roadmap
> - [docs/INTEGRATION.md](docs/INTEGRATION.md) — Crystal 1.21.0 `GC` / fiber notes
> - [CHANGELOG.md](CHANGELOG.md) — notable changes

## Why

Crystal ships with Boehm today (`boehm` backend) and also supports `gc_none`. **gcry** replaces the `gc_none` stubs at require-time with a conservative mark–sweep collector implemented in Crystal — no Crystal compiler/stdlib patch required.

## Goals

- Match Crystal’s `GC` API (`malloc`, `malloc_atomic`, `collect`, fiber `set_stackbottom`, finalizers, stats, …)
- Conservative stop-the-world mark–sweep MVP on Linux x86_64 (single-threaded + fibers first)
- Allocation-free collector core (no managed-heap allocations during collect)
- Activate via `require "gcry"` + `-Dgc_none`

Details, non-goals, and phased roadmap live in [DESIGN.md](DESIGN.md).

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

Require gcry when building with the null GC, then compile with `-Dgc_none`:

```crystal
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

puts "hello"
```

```sh
crystal build -Dgc_none samples/hello.cr -o hello
./hello
```

Without `-Dgc_none`, Crystal links Boehm; do not install gcry as the process GC in that mode.

There is no separate application-level allocator API for normal programs: allocations go through Crystal’s runtime (`GC.malloc` / language allocations). The shard overrides `GC` underneath.

## Development

```sh
shards install
crystal spec
```

Heap unit tests can run under the default (Boehm) GC while `Gcry::*` is exercised as a standalone allocator.

Design notes: [DESIGN.md](DESIGN.md). Runtime hookup: [docs/INTEGRATION.md](docs/INTEGRATION.md).

Suggested order of work:

1. ~~Research & API contract (Phase 0)~~
2. ~~Heap allocator (`mmap` arenas, size classes)~~
3. ~~Conservative mark–sweep~~
4. ~~Fiber / root registration~~
5. ~~`module GC` reopen + `-Dgc_none` samples~~
6. Hardening / CI / tune auto-collect

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
