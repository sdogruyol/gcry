# gcry

A garbage collector written in Crystal, intended as an alternative to [bdwgc](https://github.com/ivmai/bdwgc) (Boehm GC) behind Crystal’s `GC` abstraction.

> **Status:** early design / scaffolding. The collector is not usable yet. See [DESIGN.md](DESIGN.md) for architecture, API targets, and roadmap.

## Why

Crystal ships with Boehm today (`boehm` backend) and also supports `gc_none`. **gcry** aims to be a third backend: a conservative mark–sweep collector implemented in Crystal, with a path toward fiber-aware collection and, later, incremental or generational features.

## Goals

- Match Crystal’s `GC` API (`malloc`, `malloc_atomic`, `collect`, fiber `set_stackbottom`, finalizers, stats, …)
- Conservative stop-the-world mark–sweep MVP on Linux x86_64 (single-threaded + fibers first)
- Allocation-free collector core (no managed-heap allocations during collect)
- Integrate via a compile flag such as `-Dgc_gcry`

Details, non-goals, and phased roadmap live in [DESIGN.md](DESIGN.md).

## Requirements

- Crystal `>= 1.21.0`

## Installation

Once published, add it to your `shard.yml`:

```yaml
dependencies:
  gcry:
    github: sdogruyol/gcry
```

```sh
shards install
```

Runtime integration with Crystal’s `GC` module will require a Crystal build that selects the gcry backend (planned: `-Dgc_gcry`). That hook is not available yet.

## Usage

```crystal
require "gcry"
```

There is no public collector API to call yet. When the MVP lands, programs will allocate through Crystal’s normal runtime (`GC.malloc` / language allocations); gcry will sit behind that facade rather than being used as a manual allocator in application code.

## Development

```sh
shards install
crystal spec
```

Design notes and milestones: [DESIGN.md](DESIGN.md).

Suggested order of work:

1. Heap allocator (`mmap` arenas, size classes)
2. Conservative mark–sweep
3. Fiber / root registration
4. Crystal `-Dgc_gcry` backend wiring

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
