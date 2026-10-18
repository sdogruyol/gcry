# Per-collection mark cost: a batched serial drain

Host: QEMU x86-64 guest (AMD host: `AuthenticAMD`, `vmmcall`; no AVX
exposed), 12 vCPUs, Crystal 1.21.0, crystal-metric `--release`, every
process fresh. **Every build and run was under `taskset -c 0-3`**, as in
`../2026-10-06-mark-cost/`, so gcry counts 4 CPUs and its default is 2 mark
workers. Base is `release-0.37.0` = `v0.36.0` (`233b3ad6`). Every heavy step
ran under the shared heavy lock; other agents' light work still shared the
CPUs, so only arms interleaved in one session are compared.

## Method and tools

- `marksum.py` (7 trials, arm order shuffled per trial and bench): Σ
  `mark_ns` and `pause_ns` over every `collect_end` of `GCRY_TRACE=1`, and
  Σ `live_objects`. The collection count and the heap at each collection
  move from run to run (pacing): JsonParsePure took 12–15 collections, and
  Binarytrees 211–254. So the main metric below is **Σ mark / Σ live
  objects** (ns per object marked), medians (min–max); Σ mark is in the raw
  tables. `mark_ns` is the drain alone (`mark_loop`).
- Boehm runs in the same interleave (`GC_MARKERS=1 GC_PRINT_STATS=1`, Σ
  "World-stopped marking took", which includes its root scan).
- `sampler.c` / `pcprof.py`: the SIGPROF sampler of 2026-10-06 (`mmap`ed
  buffer), ~1 sample per ms of CPU. `attrib.py` groups one function's
  samples by instruction range (a sample lands one instruction after the
  stall, so each range starts after the load it is named for).
- No PMU: `perf_event_paranoid` is 4 and there is no sudo, and the guest
  exposes no counters. Callgrind with a cache model stood in for miss
  counts (`cg.sh`); the process GC faults under valgrind in its stack scrub
  (it clears below SP), so those runs set `GCRY_COLLECT_SCRUB=0`.
- `build.sh`/`snap.sh`/`prof.sh`/`cg.sh`/`sessions.sh` are the exact
  scripts (`s1`…`s5` in the file names are those sessions); `main_stack.cr`
  and `main_shadow.cr` are the probe mains.

## Where one marker's time went (base)

Function shares of all samples, 3 runs each, one marker
(`profile-functions.txt`; its `rtagprod` rows are the tag experiment below):

| | Primes | JsonParsePure | JsonGenerate |
|---|---|---|---|
| `scan_edges_inline` | 15.2% | 17.5% | 13.3% |
| `run_collection_body` (the inlined 16-entry ring drain) | 7.0% | 4.5% | 3.3% |
| `scan_object` | 2.5% | 2.1% | 1.7% |

In the ring, 47 of Primes' 159 drain samples sit on the instruction after
its first `prefetcht0`: the prefetch waits for a free fill buffer.

Inside `scan_edges_inline`, by what the sampled instruction waited on
(`attrib-base-serial.txt`):

| range | Primes | JsonParsePure | JsonGenerate |
|---|---|---|---|
| after `lock or` (the mark and `occ` words) | 13.0% | 19.3% | 29.0% |
| chunk header loads and tests | 16.4% | 13.5% | 8.3% |
| ordinal arithmetic (`mul`, `imul`) | 14.4% | 16.3% | 13.3% |
| loop head (branch recovery) | 11.5% | 14.5% | 10.7% |
| payload word | 10.1% | 5.8% | 10.6% |
| entry and exit (6 saved registers, spills) | 14.1% | 10.8% | 9.4% |
| mark and `occ` tests | 7.8% | 7.6% | 9.0% |
| radix L1 and index | 6.3% | 6.2% | 4.7% |
| radix slot | 4.3% | 4.4% | 1.8% |
| push | 2.0% | 1.6% | 3.3% |

So the candidate chain is radix slot → chunk header → mark/`occ` words,
the drain itself is bound by fill buffers, and about a tenth of the inline
path is branch recovery.

Callgrind (one marker, Primes, mark scan functions only, D1 64 KiB / LL
16 MiB, no hardware prefetcher, software prefetches ignored): 13.22 M LL
data misses with the ring, 13.03 M with the batch drain below (−1.4%),
D1 misses 14.6 M → 25.1 M (`callgrind-*.txt`). The batch does not touch
fewer lines; what it changes is when they are asked for [INFERENCE: overlap,
not locality — callgrind cannot model the overlap].

## Kept: the serial drain takes the stack in batches (`336dc9d0`)

`serial_mark_drain` was a 16-entry ring in front of a strict LIFO drain.
It now pops up to 1 024 entries into a buffer the `MarkStack` `mmap`s once
(`MarkStack#batch_buffer`, `#pop_into`) and scans them with the parallel
workers' `scan_batch_prefetched` (shard nil), prefetching 16 entries
ahead. The buffer is mapped, not on the collector's stack: 8 KiB there grew
`run_collection_body`'s frame from 0xce8 to 0x24e8 bytes (measured on the
first experimental build), more than twice what the entry and exit scrubs
must cover.

One marker, ns per live object, 7 interleaved runs (`s3.txt`,
`s3-raw.json`; the `sbprod` arm is this commit's code):

| bench | ring (base) | batch 1 024 | batch 4 096 |
|---|---|---|---|
| Primes | 14.80 (14.04–16.17) | **11.41** (11.05–13.58) | 12.35 |
| JsonParsePure | 14.73 (13.62–15.45) | **12.49** (11.77–12.79) | 12.35 |
| JsonGenerate | 10.38 (10.07–11.51) | **9.26** (8.92–9.51) | 9.55 |
| Binarytrees | 11.78 (10.30–12.58) | **9.71** (9.27–10.48) | 10.06 |

Σ mark ms: Primes 205 → 157, JsonParsePure 262 → 235, JsonGenerate
355 → 318, Binarytrees 30 → 30 (its collection count moves 214–253).
Every batch run is below every ring run on JsonParsePure and JsonGenerate;
Primes and Binarytrees overlap at one extreme run each. Wall time: Primes
1.01 → 0.89 s, the others within spread. Batches of 64 and 256 were also
measured against the ring in `s2.txt` (an earlier on-stack variant):
Primes 13.52 / 12.57 / 12.34 at 64 / 256 / 1 024, JsonParsePure 15.21 /
13.93 / 12.68, against 16.22 and 15.95 for the ring.

The re-measurement on a build of the commit itself (`s5.txt`, the `b37b`
arm) agrees: Primes 15.71 → 12.53, JsonParsePure 14.63 → 12.37,
JsonGenerate 10.98 → 9.38, Binarytrees 11.27 → 9.45.

Default workers: the parallel path is unchanged, and its rows moved within
spread (`s5.txt`: 8.42 → 8.89, 8.61 → 8.63, 7.48 → 7.09), except
Binarytrees, whose live set is under the 32 MiB floor, so it drains
serially: 11.09 → 9.72.

Mark stack mapped size at exit (`s3-markstack.txt`, `main_stack.cr`): with
one marker identical to the ring's on all four (256 KiB, 8 MiB, 16 MiB,
256 KiB). The large stacks come from JsonParsePure's and JsonGenerate's
big arrays, which the serial path pushes whole either way.

## Ratios to Boehm's single marker

`s5.txt`: the commit's build, its base and Boehm in one interleave, 7
runs, Σ mark ms (Boehm's includes its root scan):

| bench | Boehm 1 marker | gcry base | gcry batch | batch / Boehm | collections Boehm / gcry |
|---|---|---|---|---|---|
| Primes | 470 | 231 | 175 | 0.37 (base 0.49) | 15 / 8 |
| JsonParsePure | 497 | 273 | 236 | 0.47 (base 0.55) | 24 / 12–13 |
| JsonGenerate | 541 | 376 | 335 | 0.62 (base 0.70) | 25–26 / 13–14 |
| Binarytrees | 97 | 28 | 22 | 0.23 (base 0.29) | 85 / 216–254 |

gcry collects about half as often on the three large heaps, so Σ is not a
like-for-like cost. Per collection (Σ / median count), batch against Boehm:
Primes 21.8 against 31.4 ms (0.70), JsonParsePure 18.9 against 20.7 (0.91),
JsonGenerate 24.8 against 21.2 (1.17). The heaps at those collections
differ, and no per-byte figure was taken from Boehm's `In-use heap` lines
[not measured]. Boehm's numbers on this host are higher than on 2026-10-06
(Primes 378 → 470 ms Σ), and gcry's base is lower than then (774 → 231 ms,
13 → 8 collections), so the 2026-10-06 ratios (1.0× JsonParsePure, 1.3×
Primes) cannot be compared with these.

## Measured, not kept: the size class in each radix entry

`radix-class-tags.patch` (on top of the batch drain). Chunk bases are
page-aligned, so a radix entry's low 12 bits are free. An entry for a
size-class bitmap chunk outside the nursery carried the class + 1 and an
atomic bit; the class's data offset, bitmap words and block count sat in a
per-class table, written by the first tagged chunk and compared by every
later one. `scan_edges_inline` went from the slot straight to the `occ`
and mark words, skipping the chunk header line (the 8–16% "chunk header"
row above); every other reader masked the tag off.

ns per live object, 7 interleaved runs (`s4.txt`, `s4-raw.json`):

| bench | batch, 1 marker | + tags, 1 marker | batch, default | + tags, default |
|---|---|---|---|---|
| Primes | 12.16 (11.27–13.15) | 11.69 (10.58–13.27) | 7.84 (7.55–9.07) | 7.62 (7.31–9.71) |
| JsonParsePure | 12.39 (11.92–12.92) | 11.71 (11.06–12.69) | 8.80 (8.23–9.40) | 7.99 (7.14–9.04) |
| JsonGenerate | 9.41 (9.22–9.78) | 9.91 (9.53–10.36) | 7.19 (6.64–8.09) | 6.94 (6.26–7.90) |
| Binarytrees | 9.38 (9.22–10.15) | 8.90 (8.49–9.81) | 10.10 (9.29–10.86) | 9.20 (8.79–10.16) |

Against the ring in an earlier session (`s2.txt`, arm `rtag`) all 8 cells
moved down, so 15 of 16 cells over the two sessions did, but only
JsonParsePure with one marker cleared its spread; JsonGenerate with one
marker went up 5% in the second session.

Its equivalence checks passed: `shadow-check.patch` re-derived, for every
tagged candidate, class, geometry, atomic and nursery flags, large-ness,
the masked entry and containment from the chunk header — 0 mismatches in
188.1 M checks over all 26 crystal-metric benches, one marker and default
(`s4-shadow.txt`); its two specs were green (`tags-spec-green.txt`) and
each failed with its own defect planted (`tags-spec-red-*.txt`). With the
class off by one, though, the spec process died (`pthread_mutex_unlock:
Invalid argument`) instead of failing an assertion.

Not kept: no cell beats its spread by itself, and it adds an invariant —
every field a tag stands for is fixed for the chunk's life — whose
violation crashes instead of asserting.

## Tried and dropped

All against `base`, 7 interleaved runs (`s1.txt`):

- **Deferred mark writes** (`dropped-deferB.patch`): the inline loop
  collects up to 8 tested candidates, then does their `lock or`s and
  pushes, so that one candidate's loads need not wait for the previous
  candidate's locked write. Σ mark one marker +13% Primes, +12%
  JsonParsePure, +20% JsonGenerate. The lock is not what serialises the
  chain (as the 2026-10-06 plain-store arm found).
- **Branch-free span filter** (`dropped-mask.patch`): a pass builds a bit
  mask of the payload words inside the heap span, then the loop visits set
  bits. Meant for the loop-head share above. +18% Primes, +35%
  JsonParsePure, +14% JsonGenerate with one marker.
- **Serial batch of 4 096** (`s3.txt`): no better than 1 024 anywhere.
- **Parallel pop batch 1 024** (`measured-pop-batch-1024.patch`, on top
  of the batch drain): default workers 8.88 → 8.01 Primes, 8.61 → 7.96
  JsonParsePure, 7.43 → 6.40 JsonGenerate (JsonGenerate below every
  256-batch run). **Promising, not taken**: the master's pop batch lives in
  `mark_loop_drain`'s frame, inlined into `run_collection_body`, so 8 KiB
  there is the scrub-window problem the serial buffer avoids; it needs the
  same mapped buffer and its own measurement. (Taken on 2026-10-16 with
  mapped per-marker batches, `../2026-10-16-parallel-mark-batch/`.)

Not attempted, with the attribution that argues for them:
- Interleaving `occ` and mark words (one line per fresh mark instead of
  two; "after `lock or`" is 13–29% of the inline path). Every bitmap walker
  and the SSE/AVX2/NEON/SVE sweep kernels assume two contiguous arrays.
  (Measured on 2026-10-16 and not kept: −2% to −7% with one marker, never
  beyond the spread, `../2026-10-16-parallel-mark-batch/`.)
- Dropping the `occ` test (Boehm has none): it changes what a stale
  pointer to a free block does (`occ = mark` would resurrect it), which is
  outside "conservative semantics unchanged".

## Gates on `336dc9d0` (all under `taskset -c 0-3`, `gates.txt`)

All exit 0: `crystal spec -Dgc_none spec/all_specs.cr` (281 examples), the
same with `-Dgcry_block_headers` (303), `crystal spec -Dgc_none
process_spec` (199), `GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none
-Dgcry_block_headers process_spec` (200), `make lint`, `make
windows-typecheck`, `make mark-audit`, `make parallel-mark-process`, `make
parallel-mark-termination`, and `crystal build --no-codegen -Dgc_none
--cross-compile --target aarch64-apple-darwin samples/hello.cr`. Both
`spec/all_specs.cr` runs print one `GCRY INVARIANT FAILURE: live_objects
mismatch: actual=1 reported=2` line and still pass every example; the same
line is in the run on the tag commit; on `v0.36.0` it was not checked.
