# The large-freelist page release madvised its own bookkeeping

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 · Crystal 1.21.0 / LLVM 20.1.8
Branch `fix-large-freelist-madvise` off `master` (287404d)

## The defect

`release_large_freelist_pages_locked` (`collect_sweep.cr`) computed its lower
bound as the chunk base and rounded up:

```crystal
data_lo = chunk.address
start   = (data_lo + page - 1) & ~(page - 1)
```

A chunk base is page-aligned, so the round-up is a no-op and `start` **is** the
chunk base. The released range therefore began at page 0 — the page holding
that chunk's own `ChunkHeader` and, for a large chunk, the object's
`BlockHeader`, including the `next_free` link that threads the very bucket
chain the loop is walking.

Every other release site in the file starts above the metadata, two of them by
rounding up from `data_start` (`:615`, `:1059`) and two by filtering
`run_start >= data0` (`:803`, `:1175`). This one used `chunk.address`. The
asymmetry is the tell: the intent was clearly `data_start`.

It was not behind a knob. `release_large_freelist_pages` runs unconditionally in
the post-STW flush (`collect.cr:2080`), on the default path, every collection
that has anything on the large freelists.

## What it costs

When the kernel acts on the advice, that page reads back as zeroes. Then:

- `chunk.value.mapped_bytes` reads 0, so `take_large_free`'s exact-size match
  (`heap.cr:1294`) never fires for that entry;
- `header.value.next_free` reads null, so the bucket chain **truncates at the
  first reclaimed entry**. Every large chunk behind it is unreachable while
  `@large_free_bytes` still counts it, and `trim_large_cache` then walks a chain
  that can no longer reach them.

A leak plus an accounting divergence, not a use-after-free — the memory is
already free. But it is unbounded and it is invisible: nothing reports it.

## Why it survived, and why the gate asserts on the range

Linux uses `MADV_FREE` here and Darwin `MADV_FREE_REUSABLE`. Both **preserve
content until the kernel actually reclaims**, which happens under memory
pressure at a moment nothing in the process controls. So the damage is real,
rare and load-dependent, and "write the header, release, read it back" is not a
test — it is a race that usually loses. That is exactly the shape of defect this
codebase has learned to gate on the *decision* rather than the *outcome*.

What is deterministic is the range. So the fix is in two parts:

1. `release_large_freelist_pages_locked` bounds on `ChunkHeader.data_start`.
2. `madvise_range_ok?` — which this site did not consult at all — now requires
   `run_start >= data_start(chunk)`, and the site consults it.

The second part is the one worth having. The guard previously bounded on the
chunk *base*, so it would have waved this range through. Tightening it turns
"every release site remembered to start above the header" from a convention
into a checked property, at zero cost to the other sites, which already
satisfied it.

## Gate: `make large-freelist-madvise`

Two arms, and the second is the point.

| Arm | `madvise_range_rejects` | bytes released | Verdict |
|---|---:|---:|---|
| default bound | **0** | **4,386,816** | the walk runs and never reaches metadata |
| `GCRY_LARGE_RELEASE_FROM_BASE=1` | **119** | 0 | the old bound is refused every time |

The control arm reproduces the pre-fix bound under a knob — the same pattern as
`GCRY_TRIM_IMMEDIATE=1` and `GCRY_INDEX_CACHE_UNCHECKED=1`, both of which exist
so a fixed arm's green means something. 119 refusals in a ~4 s run is the
measurement of how often the old code aimed at a header page on the default
path.

The default arm also asserts that bytes *were* released. Without that, a zero
reject count would be satisfied by a walk that never ran, which is the failure
mode this file was written to avoid — and which it caught during development:
the first version of the harness read `dontneed_bytes` once per round, but that
counter is reset at the top of every major sweep (`collect_sweep.cr:32`), so it
reported 0 for the wrong reason. Sampling after each collect fixed it.
Instrumenting the release directly confirmed 119 successful `madvise` calls with
correctly aligned ranges before that was understood.

## Scope

Found while A/B-ing an unrelated change on the `simdgc` branch; it is a
pre-existing defect on `master` and this branch carries only the fix. `ROADMAP`
and `CHANGELOG` entries are for the release that picks it up.

Not fixed here, noted for whoever touches the file next: the dormant flush at
`:612` computes `finish = data_start + mapped_bytes`, which overshoots the chunk
end by `data_offset`. It is currently harmless — `end_page` rounds back down to
the chunk end because `data_offset < page` — but it is correct by accident, and
the same arithmetic with a larger metadata region would not be.
