# `make invariants` was never a Darwin problem

**Date:** 2026-08-15 · host: WSL2 x86_64, 20 CPU, Crystal 1.21.0 (`57cf7da50`)
· tip @ `d0afd54`

The board carried this as "`make invariants` has never passed on Darwin", with a
Darwin-specific hypothesis: `Invariant.count_live_blocks` walks dormant chunks
and counts any block whose header does not read free, and Darwin's
`MADV_FREE_REUSABLE` leaves those headers intact where Linux's `MADV_DONTNEED`
does not. It fails on **Linux** too, on this host, with the same signature — and
the hypothesis is right about the walk and wrong about why it is
platform-specific. It is not.

## Two failures, two causes

`GCRY_DEBUG_INVARIANTS=1 crystal spec` at `d0afd54`:

```
spec/collect_spec.cr:202  live_objects mismatch: actual=6502 reported=1   (after_collect)
spec/mt_spec.cr:118       live_objects mismatch: actual=40   reported=41  (after_malloc)
```

### 1. The walk counts dormant chunks

The decisive experiment the board asked for — count what the walker sees on a
chunk the sweep has just made dormant — run on Linux, same setup as the failing
spec (8 000 blocks, one rooted, `empty_chunk_retain = MAX`):

```
chunks=5 dormant=4 dormant_bytes=524288
live_objects reported: 1
walker counts: in dormant chunks=6501, in live chunks=1
dormant headers that read all-zero=6348, stale non-zero=153
```

The collector's accounting is exactly right: 1 live block, in the one chunk that
is not dormant. The walker adds 6 501 blocks that do not exist.

The mechanism is platform-independent, which is what the Darwin framing missed.
`free?` tests one flag bit. A header zeroed by `MADV_DONTNEED` has `flags == 0`,
which is not FREE, so it counts live — Linux gets there by *losing* the header.
Darwin gets there by *keeping* a stale one. Both read as live; only the byte
pattern differs. This host shows both at once: 6 348 zeroed, 153 stale (the tail
of the chunk's first page, which the page-aligned advice does not cover).

Skipping dormant chunks is not a weakened check. The sweep sets DORMANT only
`unless any_live` (`collect_sweep.cr:171`), so the chunk is empty by
construction, and the sweep itself already skips dormant chunks on the next pass
for the same reason (`collect_sweep.cr:47`). The walker was the only reader that
still believed those headers.

### 2. The walk races the mutator

The second failure is unrelated to chunks. `after_malloc` runs *outside* the
allocation lock, and `note_alloc_bytes` bumps `live_objects` at a different
instant than `set_used` writes the header. With four threads calling
`heap.malloc` (that spec deliberately runs without stop-the-world), the walk and
the counter are two different points in time. `actual=40 reported=41` is off by
exactly the one allocation in flight.

No fix makes a snapshot comparison valid under concurrent mutation. The check is
skipped when more than the usual main+monitor threads exist, and the skip is
**counted** — `Invariant.concurrent_skips` — because a checker that quietly stops
checking is indistinguishable from one that runs and finds nothing, which is the
failure mode this whole milestone is about.

## After

`make invariants`: **163 examples, 0 failures** — the first green run of the debug
checker recorded on any platform.

Both halves broken on purpose and observed red, separately:

| reverted | red spec |
|---|---|
| dormant skip | `spec/collect_spec.cr:202` |
| concurrent skip | `spec/mt_spec.cr:118` |

Both are now pinned by `spec/invariant_spec.cr` under plain `crystal spec`, with
no env var — so they gate on every platform's unit-spec job, Darwin included. The
dormant spec asserts `dormant_chunk_bytes > 0` first, so it cannot pass
vacuously if the sweep stops producing dormant chunks.

`GCRY_DEBUG_INVARIANTS=1 crystal spec` is also wired into the macOS CI job for
the first time. Whether Darwin has a *third* failure behind these two is not
known from here — no Darwin host was available — and that run is what will say.

## Left alone

A live block always has a non-zero size, so `counts_live?` also rejects a
zero-size header. That is reasoned, not measured: `MADV_FREE` on a SPARSE chunk
lets the kernel discard a page at any later moment under pressure, and SPARSE
chunks *do* hold live blocks, so the chunk flag cannot cover them. It is
one-directional — it can only stop garbage counting as live, never hide a live
block the counter forgot, which still fails as `actual < reported`.
