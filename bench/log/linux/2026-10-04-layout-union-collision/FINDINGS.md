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

## First fix, and why it was not enough

`6f8ff0c` kept only `Hash` layouts, behind `hash_shape_plausible?`, and
scanned everything else conservatively. The shape check is a heuristic about
the same untrustworthy key. In an HTTP + JSON program `Int64`'s type id is 372
(`type_ids.cr`: Nil 0, String 1, Array(JSON::Any) 2, Hash(String, JSON::Any)
57, Int64 372, Float64 378, Bool 381), so the 64-byte buffer of
`[hash, nil, 1_i64, nil]` — the size class of a `Hash(String, JSON::Any)` —
passes it:

| Hash field (offset) | buffer word there | check |
|---|---|---|
| `@entries` (8) | element 0's payload, the real Hash | heap pointer: passes |
| `@indices` (16) | element 1's tag, Nil = 0 | null: passes |
| `@size`, `@deleted_count` (24, 28) | element 1's payload, 0 | 0, 0: passes |
| `@indices_size_pow2` (33) | byte 1 of element 2's tag, 372 >> 8 = 1 | capacity 1 ≥ 0 used: passes |

The word at +8 was then marked without being traced, as a `@entries` blob
would be, and the first element's own entries were swept (`hash_e2e.cr`):
SIGSEGV on `6f8ff0c` with default settings, `bad=0 of 20000` with
`GCRY_DISABLE_LAYOUT=1`. A `JSON.parse`d three-element array (48 bytes, its
own size class) does not collide.

acikturkiye had lost Strings to the same class in August — blocks reading
`type_id 208` scanned to `Hash`'s map, missed edges on 193 of 216 collections
(`../2026-08-24-acikturkiye-live-string-uaf`). Each guard since narrowed the
next collision rather than closing the class.

## Fix

The mark reads no layout. `scan_object` and `scan_object_for_nursery` scan
every non-atomic block conservatively, and the `Hash` walk, its shape check
and `mark_noscan` are gone. Retention does not change for the reasons above,
and for `Hash` because Crystal clears what it deletes or compacts away
(`(entries + new_entry_index).clear(entries_to_clear)`, "so the GC can
collect them", `hash.cr`), while gcry hands every non-atomic block out zeroed
and `realloc` copies into a zeroed one, so the capacity tail past
`@size + @deleted_count` holds nothing. `@indices` is a `Pointer(UInt8)`
buffer, allocated atomic.

Tests, red on `ea65d06` and `6f8ff0c`, green after:

- `process_spec/regression/11_union_buffer_collision_spec.cr`: both buffer
  shapes, real `JSON::Any` arrays, read back after three collections with
  churn (`ea65d06` crashes on the first example, `6f8ff0c` on the second);
- `spec/layout_spec.cr` "a union buffer whose first tag is a registered type
  keeps every element", on a `Gcry::Heap`;
- `bench/layout_property_test.cr` checks that no registration loses an edge
  instead of pinning the narrowings.

`make nursery-headers` lost its red arm, which installed a `Hash` layout that
skipped keys — and turned out never to have tested what it was named for. A
major does not promote, so the Hash and its `@entries` were still young when
the key was planted; with the minor's whole old→young scan switched off by
hand the key still survived, because `GCRY_LIVE_ATTR` shows its first mark
came through the young Hash from the class-var pin. The old red arm went red
through the major after the minor. The gate now promotes the Hash with a minor
before planting, checks the Hash old and the key young, and its `--disabled`
arm turns the old→young scan off (`Heap#nursery_old_scan`) and requires the
key swept, asked of the heap by address: 3 of 3 each way.

Registration (`Gcry::Layout.register`, `register_hash`, `GCRY_AUTO_LAYOUTS`,
`GCRY_SCAN_CAPS`, the gates that inspect entries) still exists and no longer
affects marking. Removing it is a public API change, left for a decision.

## Cost

CI `Perf A/B` run 37220644804, `ea65d06` (0.34.0) against `0671a0c`, 10
interleaved reps:

| bench | x86_64 mark | arm64 mark | x86_64 time | arm64 time |
|---|---:|---:|---:|---:|
| JsonParsePure | 1608 → 1111 ms (−30.9%) | 2427 → 1522 ms (−37.3%) | −23.7% | −30.8% |
| JsonParseSerializable | −2.2% | −8.0% | +3.8% | +0.0% |
| JsonGenerate | −4.6% | −8.3% | −5.7% | +0.3% |
| Primes | −4.6% | −10.8% | −3.1% | −3.8% |
| Binarytrees | −6.1% | −12.8% | −0.3% | −2.7% |
| Knuckeotide | 29 → 32 ms (+9.9%) | 43 → 47 ms (+9.4%) | −1.2% | +0.4% |

[INFERENCE] Knuckeotide's +3-4 ms is the `Int32` values and hash words of its
`Hash(String, Int32)` counts, which the `Hash` walk skipped and the
conservative scan reads.

## Soak

CI dispatch run 37226315432 on `078bcb2` (the mark with no layout): the
Kemal soak's three arms, 2 h each, `--workers=4 --collect-hz=20`, queue audit
and poisoned frees on — PASSED, all three.
