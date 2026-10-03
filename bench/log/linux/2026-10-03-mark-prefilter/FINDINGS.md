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

Primes and JsonParsePure are still ~3× Boehm. Library-mode callgrind after
the change (`markprof`, 100 000 nodes, 4 collections, no `--debug`: a
`--release --debug` build ran 3× the instructions and is not a usable proxy):

| per call | instructions (inclusive) |
|---|---:|
| `scan_object` | ~675 |
| `mark_impl_unlocked` (one pointer word) | ~355 |
| `find_block_with_chunk` | ~166 |
| `chunk_containing` (library mode, with `@index_lock`) | ~83 |
| `Layout.entry_for` | ~55 |

Two follow-ups were tried and **dropped**, both measured against this commit
with 10 interleaved reps:

- `mark_noscan_unlocked` resolving the chunk once (`find_object_with_chunk`
  then `block_marked_in?` / `set_block_mark_in`, as `mark_impl_unlocked`
  does, instead of `heap_marked?` / `heap_set_mark` resolving it again
  each). Same marked set (per-collection `live_objects` equal to ±1), fewer
  instructions on paper, and **+11.6% Σ mark on JsonParsePure**, −2% Primes,
  −5% Binarytrees.
- Dropping `scan_hash_object`'s field loops in the major mark, where
  `scan_hash_body` marks the same words: +5.8% JsonParsePure, ±0 elsewhere.

The SIGPROF sampler (`../2026-10-03-monitor-wait-spin/sampler.c`) later
explained the first one. Under headerless, `heap_set_mark` reads
`header.value.size` for `SizeClasses.index_of?`, and the "header" there is the
blob's own first line — so the old path took the cache miss on `@entries`
inside `mark_noscan`, sampled as `size_classes.cr:64` (6.6% of JsonParsePure's
CPU). The single-resolution path never reads the blob, and the same miss
reappears one step later on the entries walk's first read of each slot
(`hash_word`, 3.3% → 13.2%). Total CPU samples: 2737 → 2631 (−4%). The cost is
the dependent miss on the blob, which both versions pay; the instructions
saved are not where the time is.

Rerun on quiet GitHub runners with `runner-ab.sh` (10 interleaved reps): x86-64
JsonParsePure Σ mark **+15.8%** (time +12.5%), aarch64 −4.0%, the other three
benchmarks within ±1.5%. On x86-64 the old path's slowness is useful: its read
of the blob's first line is issued early, and the size-class loop around it
gives the core independent work while the miss is outstanding, so the entries
walk that follows finds the line resident. Kept as it is. Otherwise, changes of this size on a QEMU
guest without perf counters are binary-layout noise as much as anything. The gap left is the per-candidate
chain (radix L1 → L2 at 4 KiB granules → chunk header → occupancy bitmap →
mark bitmap), which a structural change would have to shorten — e.g.
size-aligned small chunks, whose header is `addr & ~(chunk_bytes - 1)`
without a table walk. That is a mapping-policy change with its own RSS and
fragmentation questions, not a mark-loop tweak.

## Follow-up kept: `Layout.entry_for` inlined

`entry_for` was a call per scanned object that built the whole `Entry` — 17
loads from 17 parallel arrays — though `scan_object` reads only `alloc_size`,
`kind` and the offset slices on the common paths. `@[AlwaysInline]` on
`entry_for`, `entry_at`, `find_entry_index`, `index_slot` and `ensure_booted`
lets LLVM drop the unused loads.

- Instructions (callgrind, `markprof 100000 4`, deterministic): mark loop
  484.0 M → 464.8 M, **−4.0%**; ~29 per scanned object.
- Σ mark, 10 interleaved reps against the Monitor-fix build: Primes −6.6%,
  Binarytrees −6.7%, JsonParsePure +2.3% (its wall −1.1%). JsonParsePure has
  moved the wrong way on every mark change tried on this host, including ones
  with identical marked sets; see above.
- Confirmed on quiet GitHub runners (`runner-ab.sh`, 10 interleaved reps),
  reading the other way — the inline reverted is the variant: Σ mark +5.2%,
  +4.0%, +8.7%, +7.3% on x86-64 and +5.9%, +3.0%, +5.5%, +5.4% on aarch64
  (Primes, JsonParsePure, Binarytrees, JsonGenerate).

## Candidate resolution, step by step, on quiet runners

`resolve.cr` times each step of resolving 3 M live block pointers in random
order with the world marked stopped (no index lock), on GitHub runners because
this host was running a campaign. ns per pointer, median of 3 runs:

| step | x86-64 (ubuntu-latest) | aarch64 (ubuntu-24.04-arm) |
|---|---:|---:|
| read the word at the pointer | 8.4 | 9.6 |
| radix → chunk | 10.3 | 11.2 |
| + block (`find_block_with_chunk`) | 22.3 | 18.7 |
| + occupancy bit | 30.9 | 36.8 |
| + mark bit (its own bitmap) | 43.5 | 79.5 |
| + a second bit from the occupancy word's line | 38.8 | 59.5 |

The last row models occupancy and mark words interleaved, so one line serves
both: it would save ~5 ns per candidate on x86-64 and ~20 ns on aarch64. With
resolution ~24% of Primes' CPU that is a 3–6% mark win, for a change to every
site that walks either bitmap word by word — the allocator's refill and the
sweep's `occ = mark` among them. Not taken.

## Tried and dropped: prefetching the radix slots of an object's words

A pass over each conservatively scanned object (≥ 4 words) that prefetched the
radix slot of every in-span word before the marking pass, so the slots' misses
would overlap. A/B on quiet GitHub runners against `cf2ff20`, both built in the
same job, 10 interleaved reps (`runner-ab.sh`, `runner-ab.py`):

| bench | Σ mark, x86-64 | Σ mark, aarch64 |
|---|---:|---:|
| Primes | +19.4% | +32.0% |
| JsonParsePure | +7.8% | +12.1% |
| Binarytrees | +14.1% | +39.8% |
| JsonGenerate | +41.3% | +54.3% |

Worse everywhere. The slots are shared by every object in a 4 KiB page of the
heap, so they are mostly cached already, and the pass costs a second read of
every word plus the prefetches.

## Reproduce

`stats_main.cr` replaces crystal-metric's `main.cr`; build it in a checkout of
crystal-metric with this shard on the path, `-Dgc_none --release` for gcry and
plain `--release` for Boehm. `markbench.sh <bin>` prints the best-of-3 Σ mark
and wall time per bench.
