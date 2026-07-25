# gcry API surface (shard)

## Integration

```crystal
# shard.yml
dependencies:
  gcry:
    github: sdogruyol/gcry

# app.cr
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}
```

```sh
crystal build -Dgc_none app.cr
```

Under `-Dgc_none`, `require "gcry"` reopens Crystal’s `GC` module. Everyday code keeps using `String` / `Array` — no separate malloc API for app objects.

## Module `Gcry`

| API | Role |
|-----|------|
| `Gcry::VERSION` | Shard version string |
| `Gcry.default_heap` | Process / default `Heap` |
| `Gcry.malloc` / `malloc_atomic` / `realloc` / `free` | Library-heap helpers (tests) |
| `Gcry.collect` / `minor_collect` / `collect_a_little` | Manual collection |
| `Gcry.pause_stats` | STW pause ring (`last` / `p50` / `p99` / `max` / `count`) |
| `Gcry.metrics` | Extended counters (collections, RSS-ish bytes, blacklist, layout, …) |
| `Gcry.prometheus_text` | Prometheus exposition format |
| `Gcry::Observability.json_stats` | JSON snapshot for `/gc-stats` |
| `Gcry.register_layout(T)` / `register_hash(K,V)` | Precise scan tables |
| `Gcry.register_set(T)` | `register_hash(T, Nil)` for `Set(T)` backing |
| `Gcry.register_layouts` | Auto-register concrete `Reference` subclasses (default-on; skip with `GCRY_DISABLE_AUTO_LAYOUTS=1`) |

Process GC calls `Layout.register_builtins` at init (curated Array/Hash/Deque/`IO::Memory`/`JSON::Any` maps) and, by default, `Gcry.register_layouts` for the whole-program walk. The compile-time `@unsafe_layouts` blacklist (Cry, Crystal::*, LibC::*) keeps conservative scanning for stdlib/runtime internals whose layouts shift across versions. Disable with `GCRY_DISABLE_AUTO_LAYOUTS=1` (escape hatch for unsound precise layouts).

## Class `Gcry::Heap`

Conservative mark–sweep allocator used as the process GC or as a private heap under Boehm in specs.

Notable knobs (also via `GCRY_*` env on process GC): `gc_threshold`, `nursery_enabled`, `incremental_auto`, `release_empty_chunks`, `type_id_gate`, `blacklist_enabled`, `tlab_enabled`, `layout_precise`, `stop_the_world`.

## Env knobs

See [README.md](../README.md) Tuning table and [HARDENING.md](HARDENING.md).

## HTTP example

```crystal
{% if flag?(:gc_none) %}
  get "/metrics" do |env|
    env.response.content_type = "text/plain; version=0.0.4"
    Gcry.prometheus_text
  end

  get "/gc-stats" do |env|
    env.response.content_type = "application/json"
    Gcry::Observability.json_stats
  end
{% end %}
```

Kemal bench and **acikturkiye** dogfood the same helpers: `GET /gc-stats` → `Gcry::Observability.json_stats`, `GET /metrics` → `Gcry.prometheus_text` (under `-Dgc_none`).
