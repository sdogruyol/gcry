# Per-object mark cost: small objects scanned in the batch loop

Follows `../2026-10-15-mark-cost/` and `../2026-10-16-parallel-mark-batch/`
(ROADMAP "Per-collection mark cost on a large pointer heap"). Host: QEMU
x86-64 guest (AMD, no PMU, no AVX exposed), 12 vCPUs, Crystal 1.21.0,
crystal-metric `--release`, every run a fresh process **under `taskset -c
0-3`** as in those logs, so gcry counts 4 CPUs and its default is 2 mark
workers (`d` arms); `1` arms set `GCRY_PARALLEL_MARK=1`. Base is
`release-0.39.0` at `6fc6665c`. Every build and session ran under the shared
heavy lock; five other agents' light work shared the CPUs, so only arms
interleaved in one session are compared.

## Method and tools

- `marksum.py` (from the 2026-10-15 log, extended): per (trial, bench) the arm
  order is shuffled; each run sums `mark_ns` over every `collect_end` of
  `GCRY_TRACE=1`, and `live_objects`. Main metric: **Σ mark / Σ live
  objects, ns per marked object**, median (min–max), 7 runs per cell; `<`
  marks a cell whose every run is below every base run. s4 also records
  each collection, and reports the mean mark of the collections at ≥95% of
  the run's largest heap (gcry: `live_objects`; Boehm: the "In-use heap"
  pointer KiB after each `GC_PRINT_STATS` marking line) — a per-collection
  cost at the full heap, where both collectors mark the same live set.
- Boehm in the same interleave (`GC_MARKERS=1 GC_PRINT_STATS=1`, "World-stopped
  marking took", which includes its root scan).
- `sampler.c`/`pcprof.py`/`prof.sh`: the SIGPROF sampler of 2026-10-06.
- Callgrind (`valgrind --tool=callgrind --dump-instr=yes`, collection
  toggled on `run_collection_body`, `GCRY_COLLECT_SCRUB=0`) and `cgins.py`,
  which prints each instruction's Ir beside `objdump`.
- `build.sh` (one arm from a source snapshot), `buildpad.sh` (the same with
  `N` bytes of nops ahead of all code, perf-ab's `pN`), `audit.sh` with
  `main_audit.cr`, `main_probe.cr`.

## Where JsonGenerate's mark goes (base, one marker)

SIGPROF, 3 runs (`profile-base-JG.txt`): `scan_edges_inline` 12.8% of all
samples, `run_collection_body` (the inlined batch drain) 2.0%,
`scan_object` 1.9%. Inside `scan_edges_inline`, 176 of 613 samples (29%) sit
on the instruction after the mark word's `lock or`, which waits for the
`occ` and mark words loaded before it.

Callgrind, one run (`callgrind-base-JG-*.txt`), counts over the run's
collections: 276.2 M payload words read, 88.5 M at or above `@heap_min`,
33.2 M inside the heap span, 32.8 M fresh marks, 21.9 M objects scanned
and pushed. Instructions: `scan_edges_inline` 5.32 G, `scan_object`
1.12 G, `run_collection_body` 0.99 G, of 7.47 G collected. Per scanned object
the call pair `scan_object` → `scan_edges_inline` cost **51 instructions in
`scan_object`** (six pushes and six pops around a tail call, the tag decode, a
bounds-checked size read, four `self` flag loads, the scanned-byte store)
**and 38 in `scan_edges_inline`'s entry and exit** (six pushes, five field
loads with three spilled to the stack, six pops): 1.9 G, a quarter of the
instructions, where the whole word loop over all 276 M words cost about
1.8 G (six instructions a word, two more for the 88 M at or above the span's
start).

## Boehm's loop, for comparison

bdwgc `mark.c` `GC_mark_from` and `gc_pmark.h` (master, read 2026-10-23):

| | Boehm | gcry |
|---|---|---|
| loop shape | one function pops `(start, descr)` and scans the words inline; no call per object | until this change, `scan_object` and `scan_edges_inline` called per object |
| candidate filter | `least_ha < q < greatest_ha`, two compares | `w < lo \|\| w >= hi`, the same two |
| header | `HC_GET_HDR`: a header cache, then the two-level index | radix L1 → L2 → chunk header |
| object start | `hb_map[granule]` byte table (or a reciprocal with `MARK_BIT_PER_OBJ`) | reciprocal multiply by the class's magic |
| allocated? | none | `occ` bit (a stale pointer to a free block must not resurrect it) |
| mark set | mark **bytes** with a plain byte store (`USE_MARK_BYTES`; a race only pushes twice), or with mark bits under parallel mark `AO_or` | mark bit, test then `lock or` |
| prefetch | each candidate that passes the filter (`PREFETCH(q)`), and the range ahead | each popped entry's payload, 16 entries ahead in the batch |
| large ranges | split past 128 words, rest pushed | split past 64 KiB under parallel mark |

The one structural difference that maps to a gcry cost is the first row.

## Kept: the batch loop scans small objects itself (`e3230e5e`)

(The commit after it, with this log, only rewrites that function's comment
with the numbers below; every measurement and gate here ran on
`e3230e5e`'s source.)

`scan_batch_prefetched` (the serial drain's and every parallel marker's
batch scan) now handles a tagged entry — a small, non-atomic block of a known
class, which is what nearly every push is — in place: the class's size from
the tag, the base-only decision, and `scan_edges_run`, the old
`scan_edges_inline` loop made `@[AlwaysInline]` and given the span and radix
fields, which the batch loads once. Scanned bytes and fast hits are summed
over the batch. Untagged entries (large blocks, rest entries) still go
through `scan_object`. The function is `@[NoInline]`, so the collector's own
frame does not grow: `run_collection_body` stays at `sub $0x518,%rsp`; the
new function's frame is 0x88 bytes serial, 0x78 with a shard.
`scan_edges_inline` keeps its callers (`scan_payload` for large payloads and
the non-batch paths) as a wrapper.

The planted miss of `make mark-audit` (`GCRY_MARK_TEST_SHORT_TID`) is
applied in the new path as in `scan_payload`, so that gate's red arm drops
an edge on it: with the two lines removed, `make mark-audit` fails ("hold:
1418 edges walked, 0 missed", `mark-audit-red-noplant.txt`), so its hold
arm's objects are scanned by the new loop.

ns per marked object, 7 interleaved runs per cell (`s2.txt`, `s3.txt`,
`s4.txt`; the arm is `fused` in s2–s3 and `cand`, a `git archive` of
`e3230e5e`, in s4):

| bench | config | s2 | s3 | s4 |
|---|---|---|---|---|
| Primes | 1 marker | 10.26 → 8.69 (−15.3%) < | 10.69 → 9.00 (−15.8%) < | 10.71 → 9.21 (−14.0%) < |
| Primes | 2 (default) | 6.52 → 6.04 (−7.3%) | 6.72 → 6.01 (−10.6%) | 6.90 → 6.24 (−9.5%) |
| JsonParsePure | 1 marker | 10.65 → 9.45 (−11.3%) < | 10.74 → 9.44 (−12.1%) < | 10.85 → 9.68 (−10.8%) < |
| JsonParsePure | 2 (default) | 7.08 → 6.30 (−11.0%) | 6.77 → 5.92 (−12.5%) | 6.82 → 6.58 (−3.6%) |
| JsonGenerate | 1 marker | 8.46 → 7.29 (−13.8%) < | 8.17 → 7.25 (−11.3%) < | 8.46 → 7.84 (−7.4%) < |
| JsonGenerate | 2 (default) | 5.59 → 5.32 (−4.8%) | 5.50 → 4.79 (−13.0%) | 5.12 → 4.93 (−3.7%) |
| Binarytrees | 1 marker | 8.34 → 6.71 (−19.6%) < | 8.17 → 6.63 (−18.9%) < | 8.84 → 7.25 (−18.0%) < |
| Binarytrees | 2 (default) | 8.27 → 6.67 (−19.3%) < | 7.95 → 6.62 (−16.7%) < | 8.50 → 7.17 (−15.6%) < |

Binarytrees' live set is under the 32 MiB floor, so its default runs the
serial drain too.

**Per collection at the full heap** (s4, mean mark of the collections at
≥95% of the run's largest heap, ms, median of 7):

| bench | Boehm 1 marker | gcry base, 1 | gcry new, 1 | base, 2 | new, 2 |
|---|---|---|---|---|---|
| Primes | 145.8 | 67.7 | 57.2 (−15.6%) < | 39.4 | 36.3 (−7.9%) |
| JsonParsePure | 101.4 | 50.0 | 43.6 (−12.8%) < | 29.2 | 27.1 (−7.2%) |
| JsonGenerate | 61.2 | 44.2 | 41.0 (−7.3%) < | 26.5 | 26.1 (−1.3%) |
| Binarytrees | 4.7 | 2.3 | 1.9 (−15.8%) | 2.1 | 1.8 (−14.1%) < |

At the same (full) live set gcry's one marker took 0.46×/0.49×/0.72× of
Boehm's one marker on Primes/JsonParsePure/JsonGenerate before and
0.39×/0.43×/0.67× now. The ROADMAP's "per collection 0.70×, 0.91×, 1.17×"
divided Σ mark by the collection count, and Boehm's count includes many
small early collections (JsonGenerate: 24–26 against 13–14; its first
twelve each mark under 2 ms): Σ/count compares heaps of different sizes,
not mark costs. Σ / count in s4 still reads 15.6 ms Boehm against 22.0 ms
gcry base on JsonGenerate, for that reason.

**Pacing turns part of it into collections.** `Heap.threshold_pace_pct`
scales the next threshold by the last cycle's cost, so a cheaper mark gives
smaller thresholds: on JsonGenerate with one marker the new build took 14
collections where base took 13 in 6 of 7 runs, and its Σ mark was +3.1%
(285.9 → 294.7 ms) while every full-heap collection was 7% cheaper; the
extra collection comes before the timed section (the four full-heap ones
in `run` are the same four on both builds). With the default workers Σ mark
fell on all four (Primes −10%, JsonParsePure −0.5%, JsonGenerate −8.8%,
Binarytrees −21%). Local wall time moved within its spread on every cell
(JsonGenerate one marker 0.60 → 0.62 s, default 0.61 → 0.62).

## Soundness

- `GCRY_MARK_AUDIT=1` on all 26 crystal-metric benches, one marker and
  default (`audit.sh`, `main_audit.cr`, `audit-cand.txt`): 52 of 52 runs
  with **0 misses**, e.g. JsonGenerate 32.5 M edges walked, JsonParsePure
  32.0 M, Primes 10.4 M, Binarytrees 2.9 M; the default runs marked in
  parallel where the live floor allows (JsonGenerate 8 parallel cycles,
  RegexDna 17, Revcomp 21).
- The new path makes the same decisions as the old pair for every entry: it
  is taken only when `@mark_edges_inline` holds, for tags 1–40 (a class), and
  the size, base-only test, planted miss and word loop are the old code's;
  `@mark_scanned_bytes` (which paces) and `@radix_fast_hits` get the same
  sums per batch. `main_probe.cr` on JsonGenerate, one marker: fast hits
  38.1 M / 37.2 M, slow lookups 7 699 / 7 735, 14 collections each (base /
  new; the hits follow the collections' heaps).
- Gates on the branch (`gates.sh`, `gates/`), all exit 0: see the list at
  the end.

## Measured, not kept

- **Plain mark-bit store when serial** (`dropped-plain-store.patch`, s1): the
  serial path's `lock or` replaced by a load-or-store. One marker: Primes
  +5.2%, JsonParsePure +1.0%, JsonGenerate −3.8%, Binarytrees +2.7%; default
  −3.2%, +4.1%, −3.0%, +6.7% — none beyond the spread. The third such
  measurement (2026-10-05, 2026-10-06 on Primes and JsonParsePure): the 29%
  of samples after the `lock or` are the wait for its operands' lines, not
  the lock.
- **One unsigned span test** (`dropped-span-test.patch`, on top of the kept
  change, s3): `w &- lo >= hi &- lo` in place of the two compares. Slower than
  the kept change on all eight cells: one marker 9.00 → 9.18, 9.44 → 9.93,
  7.25 → 7.92, 6.63 → 6.90 (Primes, JsonParsePure, JsonGenerate,
  Binarytrees); default 6.01 → 6.22, 5.92 → 6.41, 4.79 → 5.21, 6.62 → 6.77.
- **A one-entry chunk cache** (`measured-chunk-cache.patch`, on top of the
  kept change, s4): `scan_edges_run` keeps the last small chunk it resolved
  (data start, end, class, bitmap words) for the batch and skips the radix
  walk and header checks for a word inside it. One marker 9.21 → 8.83
  (−4.1%), 9.68 → 9.88 (+2.1%), 7.84 → 7.70 (−1.8%), 7.25 → 7.17 (−1.1%);
  default +0.3%, +1.3%, +6.8%, −1.0%. No cell beyond the spread; not kept.

## Keep rule: `perf-ab.yml` on the five runners

**Run 39922915306**: `mark-cost-039` at `e3230e5e` against its parent
`6fc6665c`, 15 reps, Primes, JsonParsePure, Binarytrees, JsonGenerate,
JsonParseSerializable, JsonParsePull, Revcomp, RegexDna, Knuckeotide, Boehm
on, GC counters 3 runs (`ci/<run>-<runner>.md`). Σ mark, new against base
(median of paired ratios):

| runner | Primes | JsonParsePure | JsonGenerate | Binarytrees | JsonParseSerializable | JsonParsePull |
|---|---|---|---|---|---|---|
| `ubuntu-latest` | −19.8% | −12.3% | −14.8% | −20.1% | −16.6% | −18.3% |
| `ubuntu-24.04-arm` | −8.8% | −2.1% | −15.3% | −21.5% | +4.3%¹ | +5.1%¹ |
| `windows-latest` | −12.8% | −10.3% | −14.8% | −10.7% | +7.8%¹ | −8.5% |
| `macos-latest` | −4.5% | −4.6% | −13.1% | −30.0% | −1.6% | −17.8% |
| `macos-15-intel` | +22.1%¹ | −13.7% | −9.8% | −19.5% | −14.7% | −9.5% |

¹ with one more collection than base in the median run (pacing, above).

Wall and timed section slower than base beyond their interquartile range:
none on `windows-latest`, `macos-latest` or `macos-15-intel`. On
`ubuntu-24.04-arm`: JsonParseSerializable timed +1.7% [+1.2, +1.8] (wall
+0.6%), JsonParsePull +1.8% [+1.5, +2.0] (wall +1.1%), Knuckeotide +0.4%
[+0.0, +0.9]. On `ubuntu-latest`: JsonParsePull timed +5.1% [+3.9, +5.3]
(wall +1.8%), JsonParseSerializable +2.6% [+2.2, +3.2] (wall +1.1%), Revcomp
+2.5% [+2.1, +3.7] (wall +1.8%, Σ mark +0.2%: it barely marks), Knuckeotide
+1.0%, JsonGenerate timed +0.9% (wall −1.3%). Faster beyond the range there:
Primes, JsonParsePure, Binarytrees and RegexDna timed. Peak: every row but
Knuckeotide at or under 1.07× Boehm on every runner (largest: JsonParsePure
1.07× on `ubuntu-24.04-arm` and `windows-latest`, as base); Knuckeotide
1.28–1.78×, base 1.32–1.77×, the documented exception
(`../2026-10-21-knuckeotide-pin/`). Windows' JsonParseSerializable and
JsonParsePull peaks fell 12.0% and 7.5%; RegexDna's on `macos-15-intel` read
+12.3% [−0.2, +32.9] (0.50× Boehm against 0.42×).

The rows that moved on Linux were probed for placement:

- **Run 39925823114** (`ubuntu-latest`, `ubuntu-24.04-arm`; JsonParsePull,
  JsonParseSerializable, Revcomp, JsonGenerate, Knuckeotide; pads `p16 p64
  bp16 bp64`, i.e. 16/64 bytes ahead of all code, each revision). Timed
  section, s, the three placements of each revision:

  | runner | bench | new: 0 / p16 / p64 | base: 0 / bp16 / bp64 |
  |---|---|---|---|
  | `ubuntu-latest` | JsonParsePull | 0.758 / 0.734 / 0.758 | 0.733 / 0.680 / 0.733 |
  | `ubuntu-latest` | JsonParseSerializable | 0.760 / 0.740 / 0.768 | 0.749 / 0.700 / 0.746 |
  | `ubuntu-latest` | Revcomp | 1.579 / 1.456 / 1.502 | 1.544 / 1.476 / 1.541 |
  | `ubuntu-latest` | JsonGenerate | 1.367 / 1.416 / 1.358 | 1.359 / 1.419 / 1.374 |
  | `ubuntu-latest` | Knuckeotide | 1.324 / 1.330 / 1.324 | 1.322 / 1.336 / 1.337 |
  | `ubuntu-24.04-arm` | JsonParsePull | 0.635 / 0.628 / 0.630 | 0.623 / 0.634 / 0.630 |
  | `ubuntu-24.04-arm` | JsonParseSerializable | 0.646 / 0.640 / 0.641 | 0.635 / 0.645 / 0.641 |

  On arm64, Revcomp, JsonGenerate and Knuckeotide the revisions' ranges
  overlap: placement. The x86 JSON rows stayed above base at every
  whole-program pad, so they were probed twice more.
- **Run 39930906562** (`ubuntu-latest`, pads `p8 p32 p48 p96` each
  revision): JsonParsePull new 0.760 / 0.752 / 0.762 / 0.714 / 0.766
  against base 0.730 / 0.739 / 0.732 / 0.706 / 0.729; JsonParseSerializable
  0.761 / 0.758 / 0.769 / 0.732 / 0.763 against 0.746 / 0.748 / 0.749 /
  0.716 / 0.744. A whole-program pad moves both revisions together, so it
  cannot separate the change from where the JSON code lands relative to the
  collector's.
- **Run 39936139933** (`ubuntu-latest`, pads `16 48 112 b16 b48 b112`: bytes
  ahead of the benchmarks' code only, which moves the JSON code against the
  collector's; this job drew a faster runner): JsonParsePull new 0.407,
  padded 0.371 / 0.373 / 0.367; base 0.368, padded 0.422 / 0.383 / 0.381.
  JsonParseSerializable new 0.430, padded 0.393 / 0.398 / 0.398; base 0.402,
  padded 0.445 / 0.396 / 0.403. Each revision has one slow layout (new
  unpadded, base padded by 16), and the new build's three other layouts are
  at or below base's. The counter builds of the same runs (another main,
  so another layout) read JsonParsePull 0.358 / 0.359, 0.362 / 0.388, 0.359
  / 0.351 s and JsonParseSerializable 0.400 / 0.381, 0.421 / 0.368, 0.379 /
  0.380 (base / new, per run), and in 39922915306 0.710 / 0.710, 0.713 /
  0.706, 0.710 / 0.721 and 0.761 / 0.738, 0.736 / 0.736, 0.741 / 0.737.
- Locally (`s5.txt`, `buildpad.sh`, 9 interleaved runs, default workers),
  each revision at 0, 8, 16, 32, 48 and 64 bytes ahead of all code:
  JsonParsePull medians base 0.314–0.349 s (mean of the six 0.332), new
  0.316–0.348 (0.334); JsonParseSerializable base 0.327–0.353 (0.339), new
  0.318–0.351 (0.339).

**Verdict:** no row is slower than base beyond what placement moves on the
same runner. The change runs only inside a collection; on `ubuntu-latest`
the JSON rows' Σ mark fell 16.6% and 18.3% at the same collection count
while their timed sections rose, and those timed sections follow the
binary's layout (a bench-code pad of 16–112 bytes takes the new build from
0.407 to 0.367–0.373 s on JsonParsePull, base's own range is 0.368–0.422).
Peak stays inside the 1.1× budget everywhere but Knuckeotide.

## Gates (`gates.sh`, `gates/`, all under the heavy lock)

All exit 0 on the branch: `crystal tool format --check src spec
process_spec bench samples`; `make lint`; `crystal spec -Dgc_none
spec/all_specs.cr` (296 examples) and with `-Dgcry_block_headers` (318);
`crystal spec -Dgc_none process_spec` (286), with `-Dgcry_block_headers`
(287), and `GCRY_BITMAP_ALLOC=0` with `-Dgcry_block_headers` (287); `make
alloc-entry-frame` (5); `make windows-typecheck`; `crystal build
--no-codegen -Dgc_none --cross-compile --target aarch64-apple-darwin
samples/hello.cr`; `make mark-audit` (hold 1 021 edges, 199 missed; clean
1 418, 0; control nothing walked); `make parallel-mark-termination` (fixed
arm 60 runs, 459 288 entries stolen; the unlocked arm red, `damage=chain 14
node 312`); `make parallel-mark-stress` (10 of 10); `make
parallel-mark-process` (four workers stole 232 738 entries, 27 wakes;
`--disabled` stole 0); `make chunk-list-drift` (0 stranded over 36 291
mappings). Both `spec/all_specs.cr` runs print the one `GCRY INVARIANT
FAILURE: live_objects mismatch: actual=1 reported=2` line earlier logs
already had.

Bounded stress (`bench/stress_overnight.sh` at scale 0.02 on a `git
archive` of `e3230e5e`, `stress-summary.txt`): 26 of 28 loops passed every
run. `soft-soak-ec4-smoke` failed at setup (`assert_gcry_lib: … is not a git
work tree`, the snapshot) and passed rerun in the worktree. One
`process_spec` run on Crystal 1.22.0 failed regression 81's fixed arm (an
indexed chunk still listed after the in-stop sweep); that spec is not on
the mark's path and was rewritten on `release-0.39.0` after this branch's
base (`4cbfb8a6`), and its binary on 1.22.0 passed 20 of 20 runs on this
branch and 20 of 20 on base.

## Files

- `FINDINGS.md`; `dropped-plain-store.patch` (on base),
  `dropped-span-test.patch` (on the change), `measured-chunk-cache.patch`
  (on the change).
- Scripts: `build.sh`, `buildpad.sh`, `marksum.py`, `audit.sh`,
  `main_audit.cr`, `main_probe.cr`, `gates.sh`, `cgins.py`, `pcprof.py`,
  `prof.sh`, `sampler.c`.
- Data: `s1`–`s5` `.txt` and `-raw.json` (s1: plain store; s2: the change;
  s3: the change and the span test; s4: Boehm, the commit and the chunk
  cache, with per-collection rows; s5: placement); `profile-base-JG.txt`,
  `callgrind-base-JG-*.txt`; `audit-cand.txt`; `mark-audit-red-noplant.txt`;
  `gates/`; `stress-summary.txt`; `ci/` (the four runs' summaries as
  `<run>-<runner>.md`, and two runs' GC counters).
