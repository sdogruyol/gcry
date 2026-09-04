# The Darwin bitmap free-page stand-down: written blind, and the reason was backwards

**Status: the stand-down is kept and its stated reason is replaced. The
staleness it names is real; its *direction* is not. On a bitmap chunk
`BlockHeader.free?` is false for every block, forever, so the free-page mask
over-reports liveness and can only fail to release. The `next` is a cost
decision, not a soundness one — and the thing that actually keeps the bitmap
representation sound is a different stand-down, in
`unlink_free_only_page_runs`.**

Apple M2 Pro, Darwin 25.6.0 / macOS 26.6.2 arm64, Crystal 1.21.0, 16 KiB pages.
`bench/darwin_bitmap_page_release.cr`, five arms.

## What was written blind

`src/gcry/collect_sweep.cr`, inside the Darwin arm of
`flush_pending_page_release_chunks`:

```crystal
next if bitmap_alloc_chunk?(chunk)
```

with a comment reading, in substance: *this walk visits every kept size-class
chunk rather than only flagged ones, so without the test a bitmap chunk reaches
`release_free_pages_in_chunk`, whose live mask is built by reading every block
header — the one authority that is stale on a bitmap chunk, because the
streaming sweep never writes FREE.*

Written on Linux. Never run on Darwin, which is the only place the arm exists.

## The two stories it could have been

Everything turns on what the stale flag *reads*:

* reads **not free** → the mask is all-ones, no run is selected, and the
  stand-down saves a pointless walk;
* reads **free** for live blocks → runs covering live objects are selected, and
  the only thing between that and a live object being `madvise`d away is the
  `occ`-based re-read in `audit_page_run_live`.

The comment asserted the second. The code says the first, and it says it
structurally:

* `bitmap_alloc.cr:271` — allocation calls `BlockHeader.set_used`, and
  `block.cr:381` constructs the header with `flags & ~Flags::FREE`. Handing a
  block out **clears** FREE.
* `bitmap_alloc.cr:486` — `bitmap_free_block` clears bits in `occ` and `mark`
  and touches no header. Giving a block back **does not set** FREE.
* `collect_sweep.cr:1098` — `sweep_small_blocks` dispatches to
  `sweep_small_bitmap` for every non-nursery chunk under `@bitmap_alloc`, and
  that path never reaches `push_size_class_free`, the only writer of
  `Flags::FREE | Flags::SWEPT` on the size-class path.

So on a bitmap chunk `BlockHeader.free?` is false for every block that has ever
been allocated, and the mask marks every page holding a whole block live. It
over-reports. It cannot release a page holding an object; it can only decline
to release one that is empty.

## Measurement

`GCRY_PAGE_RELEASE_BITMAP_WALK=1` is the new research knob that removes the
stand-down. All arms under `GCRY_PAGE_DONTNEED=1`, 6000 held checksummed cells,
60 000 churned allocations, 13 collections.

| arm | `live_blocks` | `skipped_runs` | `release_bytes` | damaged | intact |
|---|---|---|---|---|---|
| default (`GCRY_BITMAP_ALLOC=1`) | 0 | 0 | 0 | 0 | yes |
| `--headers` (bitmap off) | 0 | 0 | **2949120** | 0 | yes |
| `--walk` (`GCRY_BITMAP_ALLOC=1` + knob) | **0** | 321 | **212992** | 0 | yes |
| `--unchecked` (+ `GCRY_PAGE_RELEASE_UNCHECKED=1`) | **0** | 321 | 212992 | 0 | yes |

Read in order:

* the **default** arm's zeros are the stand-down holding: both counters are
  only ever written from inside `release_free_pages_in_chunk`.
* the **headers** arm is the control. 2.88 MiB released says the walk works on
  this host, so the default arm's zeros are a fact about the stand-down and not
  about a walk that never engages anywhere.
* the **walk** arm engages — 208 KiB — and `live_blocks=0` is the finding: the
  `occ` authority found **no live block** in any run the header-built mask
  selected. 5 runs of 5. 208 KiB against the header arm's 2.88 MiB is the
  over-reporting, quantified: what is left is the tail slack below the last
  whole block, which has no header and therefore no way to read live.
* the **unchecked** arm removes the `occ` re-read as well, so the stale mask is
  used as-is. Still nothing lost, 5 of 5.

`skipped_runs=321` is **not** `audit_page_run_live` firing. It is the *other*
stand-down: `unlink_free_only_page_runs` (`collect_sweep.cr:725`) refuses
outright on a bitmap chunk and increments the same counter once per chunk. That
one is load-bearing, and its own comment carries the measured record — an
`occ`-built live mask made the walk engage (0 B → 1.97 MB) and corrupted,
`page-release-corruption`'s HOLED arm faulting 1 of 4. The reason is structural
and unfixed: under bitmap allocation there is no freelist to unlink, and the
pool cursor can hand out a block inside a run this walk is about to discard.
Porting that needs the cursor excluded from the run under the size-class lock.

## Why the evidence is a counter and not the checksum

This is the part that changes how the table above should be read, and it is
Darwin-specific.

`Platform.release_physical_pages` on Darwin (`platform/darwin_stubs.cr:100`)
issues `madvise(addr, len, 5)` — `MADV_FREE`. Linux's HOLED path issues
`MADV_DONTNEED`, which zeroes the page there and then, so on Linux a
mis-released page is caught by any checksum immediately. Measured here, on a
64-page anonymous mapping still referenced and fully written:

| advice | `madvise` rc | intact immediately | intact after 2 GiB of pressure |
|---|---|---|---|
| 5 (`MADV_FREE`) | 0 | 64/64 | 64/64 |
| 7 (`MADV_FREE_REUSABLE`) | 0 | 64/64 | 64/64 |

and through the collector's own call, on 256 live payload pages:
`release_physical_pages` accepted all 256 and **0** of them lost their first
word.

So on this platform a released live page is **latent**. Every `intact=yes` in
the table above is therefore non-discriminating, and `page_release_live_blocks`
— binary, immediate, read from the `occ` authority — is the evidence. The gate
asserts on the counter and says this in the arm that measures it.

The verifier itself was checked the way `bench/page_release_corruption.cr`
checks its own: one held cell's payload zeroed on purpose, `damaged=1`,
`checksum_match=false`. A checksum gate that cannot be shown to fail is not a
gate, even when it is not the one carrying the verdict.

## What shipped

The `next` stays, with `&& !@page_release_bitmap_walk` added so the arm exists,
and its comment replaced with the above. The cost it buys is a full chunk walk
per collection against ~208 KiB of tail slack on a bitmap heap; nobody should
remove it expecting a correctness win, and nobody should keep it believing it
is one.

`make darwin-bitmap-page-release`.
