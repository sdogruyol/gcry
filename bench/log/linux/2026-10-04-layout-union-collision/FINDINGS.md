# A mixed-union buffer collides with a registered layout — use-after-free

Linux x64, Crystal 1.21.0, tree `ea65d06` (0.34.0 + leaderboard), default
settings. Found while measuring why layouts cost JsonParsePure mark time
(`../2026-10-04-hash-entries-prefetch/`).

## The defect

`Gcry::Layout` identifies a block by its first `Int32`. A raw buffer of a
mixed union (one with value types in it) stores every element as
`{type id : Int32, padding, payload}`, so the buffer's first `Int32` is its
first element's type id. When that id is a registered type and the buffer's
size class equals the type's `alloc_size`, `scan_object` trusted the map:

```
Array(JSON::Any) instance=24 alloc_size=32 scan=[16] noscan=[]  sizeof(JSON::Any)=16
real buffer tag[0]=2 (Array(JSON::Any) id=2) tag[1]=1 (String id=1)
block payload=32 child0 live=false child1 live=false
```

(`test_heap.cr`, on a `Gcry::Heap`.) `[JSON::Any.new(array), JSON::Any.new("x")]`
is 32 bytes and starts with `Array(JSON::Any)`'s id. It was scanned at that
type's one offset, +16, which in the buffer is the second element's tag. The
pointers at +8 and +24 were never read.

End to end, with the process GC and nothing set (`e2e.cr`, 20 000 such pairs,
three collections with churn in between, then read back):

| run | result |
|---|---|
| default | `Invalid memory access (signal 11)` in `String#==` reading an element back |
| `GCRY_DISABLE_LAYOUT=1` | `bad=0 of 20000` |
| fixed | `bad=0 of 20000` |

`Array(JSON::Any)` is in `register_builtins`. Any array of two `JSON::Any`
built by a literal, `map`, `Array.new(2)` or `dup` has that size; parsing
grows arrays to capacity 3, 6, 12, which is why JSON-heavy benchmarks never
showed it.

The other two narrowings fail the same way. `scan_cap` stops a colliding
buffer at the instance size, missing its tail; the leaf path skips the buffer
entirely, and its guard (the first word's high half is nonzero for a raw
pointer buffer) is passed by a union tag, whose high half is padding.

## What the narrowings were buying

Nothing a real instance needed:

- `clear_block` zeroes a non-atomic block to its whole size class
  (`heap.cr`), and Crystal never writes past `instance_sizeof`, so the slack
  `scan_cap` clipped was always zero.
- Crystal allocates a class with no `has_inner_pointers?` ivar with
  `malloc_atomic` (`compiler/crystal/codegen/codegen.cr:2256-2259` in 1.21.0),
  and atomic blocks never reach the scan, so a "leaf" that did was a collision.
- The buffers noscan offsets name (`Array(Int32)#@buffer`, `IO::Memory`,
  `String::Builder`) are pointer-free and atomic for the same reason, so
  tracing them costs nothing either.

The CI probe that started this (`probe-layout-env`, 8 interleaved rounds,
both Linux architectures) measured layouts on against `GCRY_DISABLE_LAYOUT=1`:
neutral on Primes, JsonGenerate, Binarytrees, JsonParseSerializable and
Knuckeotide, and JsonParsePure 30-32% faster with layouts off.

## Fix

`scan_object` and `scan_object_for_nursery` apply a layout only when it is a
`Hash`, keep the `Hash`'s own shape check, and scan everything else
conservatively. `spec/layout_spec.cr` "a union buffer whose first tag is a
registered type keeps every element" fails on `ea65d06` and passes with the
fix; `bench/layout_property_test.cr` now checks that no plain registration
loses an edge instead of pinning the narrowings.

Residual, documented in `docs/SOUND-DEFAULTS.md`: a buffer that collides with a
registered `Hash` and passes `hash_shape_plausible?` has its `@entries` /
`@indices` words marked without being traced.
