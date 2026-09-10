# Does headerless still win on the 0.25.0 tree? (review of PR #41)

Date: 2026-09-10 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.2
Tree: PR #41 head `700a36c` · Crystal 1.21.0
`bench/performance/kemal_ab.py`, Kemal `/json`, 20 rotated rounds × 4 arms,
15 s per trial after warmup, identical-binary null control.

## Why re-measure

The PR's headline table is `../2026-09-06-bitmap-default-ab/`, taken on tree
`8421f7b` — v0.23.0 plus fixes, i.e. **before** 0.24.0, 0.24.1 and 0.25.0.
Between then and now the bitmap allocator became the default, the chunk-list
lock was added to allocation searches, the cursor handoff was made to claim
ownership under the list lock (#39), and an explicit `GC.collect` began
releasing the warm budget. Every one of those touches the path the two layouts
differ on, so the +6.9 pp / −17% peak RSS claim needed a reading on the tree
that is actually being merged. Both gcry arms are the same PR checkout; the
only difference is `-Dgcry_block_headers`.

## Result

Against Boehm (`analysis_boehm.txt`), null control 98.6% [95.2, 102.0]:

| arm | req/s | % Boehm [95% CI] | peak RSS | post-GC RSS | faults / 1k | CPU ms / 10k | wrk p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Boehm | 78 835 | 100.0% | 28.2 MB | 28.2 MB | 0.5 | 111.4 | 3.48 ms |
| header layout (0.25.0 default) | 82 319 | 104.9% [98.4, 111.5] | 35.6 MB | 17.1 MB | 3.6 | 97.0 | 3.10 ms |
| **headerless (PR default)** | 88 596 | **112.9%** [105.8, 120.0] | **30.2 MB** | 15.7 MB | 1.5 | 88.9 | 2.94 ms |

Against the header layout (`analysis_headers.txt`): headerless is
**108.4%** [102.0, 114.8] at **0.85×** its peak RSS, 1.5 against 3.6 minor
faults per 1 000 requests, 8% less CPU per request, GC pause p50 0.658 against
0.743 ms.

## Reading

The claim holds on this tree, and every column moves the same direction as the
2026-09-06 run:

| | 2026-09-06 (pre-0.24.0) | 2026-09-10 (PR head) |
|---|---|---|
| headerless vs Boehm | 112.6% [106.6, 118.6] | 112.9% [105.8, 120.0] |
| header vs Boehm | 105.3% [99.2, 111.3] | 104.9% [98.4, 111.5] |
| gap | +7.3 pp | +8.0 pp |
| peak RSS × header | 0.83 (31.2 / 37.5 MB) | 0.85 (30.2 / 35.6 MB) |

Both readings are the same measurement to within their CIs, four releases
apart, on different trees. The throughput gap (t = 2.74 against the header
arm, 8.4% ± 6.4) is the one number that is significant on its own; the RSS cut
is not a statistical claim at all, it is 16 bytes × live objects and shows up
as such.

Only the *peak* differs much between layouts now — post-GC is 15.7 vs 17.1 MB,
because 0.24.1's explicit-collect release already returns the warm budget on
both. What headerless removes from peak is the header bytes inside live
chunks, which the warm budget then does not have to cover.

## Not measured here

The fat app (`acik /api/v1/`) on the two layouts; Darwin (the PR cites
`../../macos/2026-09-06-bitmap-default-ab/`, also pre-0.24.0). Neither changes
the direction, and the Linux gap is the one the default flip rests on.
