# Regression 71 on Darwin: the target taken from the large cache (2026-11-03)

The question: since run 41330687873 (`16a6804b`) every Darwin job
(darwin native, x86_64 and arm64 gates, x86_64 root gates) fails
`process_spec/regression/71_large_unlink_walks_nothing_spec.cr:50`,
`unlink_depth(heap, target).should be >= UNLINK_SIDE`, with depths 56, 44,
46 and 57. It was green at `f3ccc4dc` (run 41323054114). Between the two
are the nursery-mprotect commits (`dafe2830`..`367c3707`) and `16a6804b`
(regression 61's scrub, spec only).

**Answer: the spec's construction broke, not the large-chunk list.** The
spec needs its 513 blocks mapped fresh, each prepended to `@chunks`; the
target then lies 256 back blocks deep, and the collection's reversing
rebuild puts it behind everything older plus the 256 front blocks. On
Darwin, `alloc_large` takes any cached chunk of the exact size in place
(`take_large_free(mapped)`; Linux recycles, and takes only a chunk the
program freed itself). When the examples ahead of regression 71 leave a
chunk of the target's mapped size (4 MiB + one page) in the cache, the
target is that chunk, wherever it sits in the old part of the list: both
runs are in front of it, and the collection reverses it to the front. The
list handling, the back-links and the unlink are right throughout
(`chunk_back_link_faults` 0). Fixed in the spec: the cache is trimmed to
nothing with collection already off, and checked empty, before the
construction.

## Evidence

Probe `probe/darwin71` (push-triggered, full SHAs, deleted afterwards),
run 41366840505: regression 71 instrumented without any allocation between
the construction and the collection (counters read into locals, chunk
positions counted by a walk), alone and inside two full
`crystal spec -Dgc_none process_spec` runs, at `f3ccc4dc`, `367c3707` and
`16a6804b` on `macos-latest` and `macos-15-intel`.

| runner | sha | examples | cache at entry | target from cache | built (tpos, front/back before it) | after collect depth | result |
|---|---|---|---|---|---|---|---|
| intel | f3ccc4dc | 286 | 3 395 584 | no (hits 0) | 256, 0/256 | 416 | pass ×2 |
| intel | 367c3707 run 1 | 310 | 3 395 584 | no | 256, 0/256 | 417 | pass |
| intel | 367c3707 run 2 | 310 | 7 593 984 | **yes** (hits 1) | **613, 256/256** | **59** | fail |
| intel | 16a6804b ×2 | 310 | 7 593 984 | **yes** | **613, 256/256** | **58** | fail ×2 |
| arm64 | all three ×2 | 286/310 | 3 129 344 | no (hits 2, 64 KiB) | 256, 0/256 | 408-410 | pass |
| both | all, spec alone | 1 | 0 | no | 256, 0/256 | 286 | pass |

7 593 984 − 3 395 584 = 4 198 400 = 4 MiB + 4 KiB, the target's mapping on
x86_64. In the failing runs the target's chunk sat at position 613 of 675
before the collection, behind both runs, and at 58-59 after it. Whether a
chunk of that size is cached when regression 71 starts depends on what ran
ahead of it: on Darwin 66 examples ran ahead at `f3ccc4dc` and 90 from
`dafe2830` on, regression 99's 24 (no other spec file was added in the
range). Which example frees the 4 MiB block was not traced; on the arm64
probe runner the cache held no such chunk in four runs, while all four CI
jobs failed.

The instrumentation had to avoid allocating after `GC.enable`: a first
version that built its report there triggered an automatic collection
(`collections` 0 → 1 between construction and `GC.collect`), whose extra
reversal changes the shape it set out to measure.

## Reproduction and fix

A seed example (probe only, `seed_spec.cr.txt` here) raises
`large_cache_retain` to 16 MiB, maps a 4 MiB block and 64 blocks of 64 KiB
with collection off, frees the 4 MiB block, collects, and checks the chunk
cached. Built ahead of regression 71 into one binary:

- Linux, `GCRY_LARGE_RECYCLE=0` (in-place take as on Darwin): the spec as
  it was fails, `Expected 65 to be GreaterOrEqual 256`; the fixed spec
  passes. With recycling on, the seed's chunk is not kept (the recycling
  budget trims it), so Linux does not reach the window this way.
- Darwin, run 41371565065 on the fixed tree (`65a2bd0b`, the same change
  before its rebase), `macos-15-intel` (15.7.9, x86_64) and `macos-latest`
  (`macos-26-arm64`, 26.6.2), 20 loops each of three binaries:

  | runner | seed + spec as it was | seed + fixed spec | fixed spec alone | full process_spec, fixed |
  |---|---|---|---|---|
  | macos-15-intel | 20/20 fail, depth 65 | 0/20 fail | 0/20 fail | 3/3 pass, 344 examples |
  | macos-latest arm64 | 20/20 fail, depth 65 | 0/20 fail | 0/20 fail | 3/3 pass, 344 examples |

  The seed's chunk was cached in every loop (4 198 400 bytes on x86_64,
  4 210 688 with arm64's 16 KiB page). `probe-41371565065.txt`.

Instrumented spec of run 41366840505: `instr71_spec.cr.txt`, its output
`probe-41366840505.txt`. Both probe workflows ran on `probe/darwin71`,
deleted afterwards.

## Checks

`crystal tool format --check`, `make lint` (after `rm -rf lib/ameba
bin/ameba`), `make windows-typecheck`, `make darwin-typecheck`, and the spec
alone on Linux, all on the fixed tree.
