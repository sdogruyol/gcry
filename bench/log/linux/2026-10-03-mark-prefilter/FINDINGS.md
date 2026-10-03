# Heap-span prefilter in the mark loops

## Why

crystal-metric on every platform (Windows x64 / arm64, macOS arm64; see
`../2026-10-03-crystal-metric-cross-platform/`) has two outliers where gcry
runs at 26–33% of Boehm's speed: **Primes** and **JsonParsePure**. Everything
else is 87–107%.

`GCRY_TRACE=1` per collection, Linux x64, `crystal-metric` built with
`stats_main.cr` (a `GCSTATS` line at exit):

| bench | collections | Σ pause | Σ mark | Σ sweep | Σ flush | biggest live set |
|---|---:|---:|---:|---:|---:|---|
| Primes | 15 | 2843 ms | 2839 ms | 4 ms | 42 ms | 10.2 M objects, 546 MiB, mark 514 ms |
| JsonParsePure | 25 | 2496 ms | 2492 ms | 7 ms | 36 ms | 4.2 M objects, 439 MiB, mark 352 ms |

The pause is the mark phase and nothing else. Boehm (`GC_PRINT_STATS`) marks
the same Primes heap (545 MiB pointer-containing) in 178 ms at its largest
collection and ~520 ms over all 15; gcry's is ~5× that, on the same number of
collections. It is ~50 ns per live object.

## Where the mark time goes

`callgrind --cache-sim=yes` on a library-mode graph of 48/80/64-byte blocks
(Primes' shape: node → hash → entries → children), 100 000 nodes:

- `scan_object` inclusive 81% of the run; `mark_impl_unlocked` 51%, of which
  `find_block_with_chunk` 15%.
- `mark_impl_unlocked` *self* is 22.5% of all instructions, and almost all of
  it is the prologue plus the heap-span reject: it is called once per scanned
  word, it is not inlined into the scan loop, and most words of a body — nulls,
  small integers, hashes — are rejected by its first test.

## Change

The span test moves into the callers' loops, against `@heap_min`/`@heap_max`
loaded once per object (no chunk is mapped or unmapped while the world is
stopped for a mark):

- `scan_object`'s conservative loop and its `scan_cap` loop;
- `scan_hash_body`'s loop;
- `mark_candidate` (every precise layout slot and Hash entry key/value) is
  `@[AlwaysInline]` with the same test first.

`mark_impl_unlocked` keeps its own test, so the result is unchanged for every
word: a word outside the span was rejected there before
`find_block_with_chunk` ran. The one hook before that test,
`ThreadListWatch.note_candidate`, only watches an object inside the heap (it is
armed with its chunk base), so no word it could match is filtered out.

## Measurements

Linux x64, same host running a 5-lane campaign (noisy; arms interleaved in
random order per rep). Binaries: `base` = `05b7d69`; `pf` = conservative loops
only; `pf2` = the commit.

Σ mark ms per run (`GCRY_TRACE`), median of 6 (`ab-mark-ms.json`):

| bench | base | pf | pf2 |
|---|---:|---:|---:|
| Primes | 2773 | 2289 (−17.4%) | 2222 (−19.9%) |
| JsonParsePure | 2583 | 2442 (−5.5%) | 2082 (−19.4%) |
| Binarytrees | 275 | 235 (−14.7%) | 219 (−20.6%) |

Wall time, median of 8, with Boehm in the same interleave (`ab-wall-s.json`):

| bench | Boehm | base | pf2 | pf2 vs base | speed % of Boehm, base → pf2 |
|---|---:|---:|---:|---:|---|
| Primes | 1.029 s | 3.404 s | 2.798 s | −17.8% | 30.2% → 36.8% |
| JsonParsePure | 0.561 s | 1.757 s | 1.617 s | −8.0% | 31.9% → 34.7% |
| Binarytrees | 0.787 s | 1.006 s | 0.909 s | −9.7% | 78.2% → 86.6% |

`pf` alone did little for JsonParsePure: its live set is mostly `Hash` and
`JSON::Any`, scanned through the precise Hash path and `scan_hash_body`, which
`pf2` covers.

## Gates

`crystal spec` (default, `-Dgcry_block_headers`, `GCRY_DEBUG_INVARIANTS=1`),
`process_spec`, `make interior-only-buffer unaligned-only-buffer mark-audit
parallel-mark-process parallel-mark-termination parallel-mark-stress
finalizer-complex bitmap-marks-freelist poison-freed thread-churn-uaf
stw-mt-sample`, `ci/sound-suite.sh`: all green.

## Still open

Primes and JsonParsePure are still ~3× Boehm. The rest of the per-object cost
is the candidate resolution itself (`find_block_with_chunk` → radix → block
ordinal → bitmap) and its cache misses; see the next findings in this series.

## Reproduce

`stats_main.cr` replaces crystal-metric's `main.cr`; build it in a checkout of
crystal-metric with this shard on the path, `-Dgc_none --release` for gcry and
plain `--release` for Boehm. `markbench.sh <bin>` prints the best-of-3 Σ mark
and wall time per bench.
