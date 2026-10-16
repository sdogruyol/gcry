# Parallel mark: pops of 1 024 entries into mapped batches

Follows `../2026-10-15-mark-cost/` ("Tried and dropped": a parallel pop
batch of 1 024 was 7–14% faster per object with two workers, but the
master's batch sat on the collector's stack). Host: QEMU x86-64 guest (AMD,
no PMU), 12 vCPUs, Crystal 1.21.0, crystal-metric `--release`, every run a
fresh process. Base is `release-0.37.0` at `4fcee559`. Builds and every
session ran under the shared heavy lock; other agents' light work still
shared the CPUs, so only arms interleaved in one session are compared, and
session-to-session drift is visible (s4 ran faster on every arm than s3).

## Method

- `marksum.py` (from the 2026-10-15 log): per (trial, bench) the arm order
  is shuffled; each run sums `mark_ns`, `pause_ns` (and from s4 `sweep_ns`)
  over every `collect_end` of `GCRY_TRACE=1`, and `live_objects`. The main
  metric is **Σ mark / Σ live objects, ns per object marked**, median
  (min–max); Σ mark ms and the bench's wall time are beside it. It also
  parses a `PROBE` line `main_probe.cr` prints at exit (worker count,
  parallel runs, entries helpers popped, wakes, mark stack mapped size), so
  one build per arm gives timings and steal shares.
- Pinned runs use `taskset -c 0-3` as on 2026-10-15: gcry counts 4 CPUs, the
  default is 2 mark workers (`_d`), and `GCRY_PARALLEL_MARK=4` is `_4`,
  `GCRY_PARALLEL_MARK=1` `_1`. Unpinned runs (`u` files) see 12 CPUs, where
  the default is already 4 workers (`12 / 4 + 1`), so only `_d` was run.
- Binarytrees' live set is under the 32 MiB floor, so it marks serially in
  every config (`pm-runs 0`): it is the control for code-placement noise.
- `pool.py`: one arm against another per session (`<` marks a cell where
  every run of the second arm is below every run of the first, "beyond the
  spread") and pooled over sessions with a Mann–Whitney U, reported as
  P(B < A) over all run pairs and a two-sided p (normal approximation).
  Pooling mixes session drift into both arms alike.
- `mkarms.sh` makes the arms (`impl-s1.patch`, `impl-s2.patch`: the change
  as measured in s1 and s2; `pb<N>` sets the batch, `pb<N>w<W>` wakes per
  `W`), `build.sh` builds one, `s1.sh`, `session.sh` and `s3.sh` are the
  exact sessions, `gates.sh` the gates.
- Seven crystal-metric benches (Knuckeotide, RegexDna, Revcomp,
  JsonGenerate, JsonParsePure, JsonParseSerializable, JsonParsePull) print
  `err` against their expected value and exit 1 on every build here, with
  the same result values on base, both arms below and a Boehm build of the
  same harness (JsonParsePure `x=0.49995358947126856` against an expected
  `0.4999535894712113`, JsonGenerate `3931493865` against `1584466874`).
  The harness's expectations, not a collector: timings are unaffected, and
  `s3-results.txt` has every bench's result line, identical across arms.

## The change (`50b1315e`)

Every marker, the master included, pops into a buffer mapped with its push
buffer (`Heap#ensure_mark_buffers`, one 12 KiB mapping per shard: 512 words
of push buffer, 1 024 of batch; the address is shard word `SHARD_BATCH`),
not into a `StaticArray` on its stack, and takes up to `MARK_POP_BATCH` =
1 024 entries per pop (was 256) with `MarkStack#pop_into` under the lock
instead of one `pop` per entry. Nothing else in the protocol moved: the pop
still counts the taker busy in the same critical section, a flush still
wakes one parked marker per `MARK_POP_BATCH` held, the local drain still
reuses the batch. A helper whose map fails sits the cycle out, and a master
whose map fails marks serially. `Heap#destroy` now unmaps the shards'
buffers after joining the helpers (they outlived the heap before); the spec
`maps the markers' batch buffers and unmaps them on destroy`
(`spec/mt_spec.cr`) fails with the unmap removed (`spec-red-release.txt`:
`Expected: 0 got: 2`) and passes with it.

Frames (`frames.txt`, `sub rsp` at entry, from the arms' binaries):

| | base | mapped (any N) |
|---|---|---|
| `run_collection_body` (inlines `mark_loop_drain`) | 0xce8 (3 304 B) | 0x6e8 (1 768 B) |
| `mark_worker_loop` | 0x858 (2 136 B) | 0x58 (88 B) |

So the frame the collection-entry and exit scrubs cover (16 KiB by default)
is 1.5 KiB smaller, and the master's batch of block addresses no longer
stays below the mutator's SP after a collection.

## Sweep of the batch size (s1, s2)

ns per marked object, 7 interleaved runs per cell (`s1p.txt`, `s1u.txt`,
`s2p.txt`, `s2u.txt`). `base` is the 256-entry on-stack batch; every other
arm is mapped.

Two workers (pinned, default):

| bench | base s1 | 64 | 256 | 1 024 | 1 024 w256 | base s2 | 512 | 1 024 | 2 048 | 4 096 |
|---|---|---|---|---|---|---|---|---|---|---|
| Primes | 7.35 | 9.02 | 7.35 | 7.06 | 6.90 | 7.04 | 7.07 | 7.33 | 7.31 | 7.10 |
| JsonParsePure | 7.76 | 8.81 | 7.33 | 7.10 | 7.29 | 7.56 | 7.13 | 7.26 | 7.05 | 7.38 |
| JsonGenerate | 6.45 | 7.86 | 6.53 | 5.32 | 5.51 | 6.51 | 5.73 | 5.81 | 5.38 | 5.58 |

Four workers (pinned, `GCRY_PARALLEL_MARK=4`):

| bench | base s1 | 64 | 256 | 1 024 | 1 024 w256 | base s2 | 512 | 1 024 | 2 048 | 4 096 |
|---|---|---|---|---|---|---|---|---|---|---|
| Primes | 6.32 | 10.32 | 5.45 | 4.90 | 4.73 | 6.38 | 5.72 | 4.90 | 5.62 | 5.27 |
| JsonParsePure | 5.43 | 8.39 | 5.41 | 4.71 | 4.56 | 5.56 | 4.86 | 5.01 | 4.93 | 4.76 |
| JsonGenerate | 4.80 | 7.77 | 4.53 | 3.74 | 3.53 | 4.67 | 3.99 | 3.65 | 3.64 | 3.79 |

Four workers (unpinned, default):

| bench | base s1 | 64 | 256 | 1 024 | 1 024 w256 | base s2 | 512 | 1 024 | 2 048 | 4 096 |
|---|---|---|---|---|---|---|---|---|---|---|
| Primes | 5.55 | 9.06 | 5.19 | 5.43 | 5.25 | 5.49 | 5.36 | 4.90 | 4.73 | 4.99 |
| JsonParsePure | 5.25 | 8.43 | 5.10 | 4.97 | 4.59 | 5.67 | 4.47 | 4.44 | 4.54 | 4.57 |
| JsonGenerate | 4.57 | 8.35 | 4.70 | 3.65 | 3.67 | 4.52 | 3.75 | 3.65 | 3.68 | 3.83 |

- 64 is slower than base on every parallel cell (up to 1.8×): a lock round
  trip per 64 entries.
- 256 mapped is base within spread on every cell: mapping the batch costs
  nothing and buys nothing by itself.
- 512 to 4 096 is one plateau; no size in it beats 1 024 beyond the spread
  anywhere. 1 024 is kept: the plateau's smaller end (a shallow stack is
  split among fewer pops) and the serial drain's batch size. At 4 096 the
  mark stack grew (JsonParsePure up to 4 MiB mapped, from 2) and wakes rose
  (JsonGenerate, four workers, 68 a run against 31 for base and 38 for
  1 024).
- `w256` (pop 1 024, wake a parked marker per 256 held instead of per
  1 024) is 1 024 within spread on every cell: not kept.
- The helpers' share of popped entries (`stolen` / Σ live) did not move with
  the size on any cell: Primes 0.46 (two workers) and 0.66–0.70 (four),
  JsonParsePure 0.37–0.38 and 0.55–0.58, JsonGenerate 0.32 and 0.46–0.48.
  Wakes per run moved within spread up to 2 048 (Primes 5 / 15–20,
  JsonParsePure 8–9 / 27–38).

## Kept: base against the commit (s3), and pooled

s3 (`s3p.txt`, `s3u.txt`, `s3-raw.json`): base, `kept` (a `git archive` of
`50b1315e`) and `keptil` (below), 7 interleaved runs. ns per marked object;
Σ mark ms and wall s medians:

| bench | config | base | 50b1315e | Σ mark ms | wall s |
|---|---|---|---|---|---|
| Primes | 1 marker | 10.79 (10.37–11.17) | 10.87 (10.52–11.28) | 150 → 140 | 0.81 → 0.81 |
| Primes | 2 (default) | 7.46 (7.00–7.87) | 7.02 (6.63–8.18) | 88 → 84 | 0.77 → 0.73 |
| Primes | 4 | 6.15 (4.89–6.99) | 5.11 (4.47–5.55) | 72 → 59 | 0.75 → 0.73 |
| Primes | 4, unpinned | 5.92 (4.91–6.48) | 5.53 (4.69–5.83) | 69 → 66 | 0.72 → 0.73 |
| JsonParsePure | 1 marker | 11.53 (11.19–12.11) | 11.40 (10.83–12.83) | 213 → 217 | 0.42 → 0.42 |
| JsonParsePure | 2 (default) | 7.37 (7.15–8.36) | 7.19 (6.85–8.03) | 160 → 161 | 0.41 → 0.43 |
| JsonParsePure | 4 | 5.42 (4.96–6.53) | 4.58 (4.28–5.56) | 121 → 100 | 0.39 → 0.41 |
| JsonParsePure | 4, unpinned | 5.61 (4.88–6.33) | 5.08 (4.35–5.56) | 126 → 114 | 0.39 → 0.40 |
| JsonGenerate | 1 marker | 9.02 (8.67–9.53) | 8.86 (8.21–8.94) | 331 → 297 | 0.66 → 0.66 |
| JsonGenerate | 2 (default) | 6.68 (6.10–7.51) | **5.75** (5.49–6.07) | 231 → 203 | 0.67 → 0.66 |
| JsonGenerate | 4 | 4.99 (4.00–5.31) | 4.01 (3.54–4.97) | 174 → 156 | 0.66 → 0.65 |
| JsonGenerate | 4, unpinned | 4.54 (3.99–4.79) | 3.69 (3.60–4.13) | 168 → 140 | 0.65 → 0.64 |
| Binarytrees | 1 marker | 8.64 (8.19–9.58) | 9.07 (8.31–9.73) | 25 → 26 | 0.62 → 0.64 |
| Binarytrees | 2 (default) | 8.51 (8.20–9.83) | 9.03 (8.12–9.66) | 21 → 28 | 0.63 → 0.63 |
| Binarytrees | 4 | 8.79 (8.21–9.74) | 8.61 (8.25–9.34) | 26 → 26 | 0.63 → 0.66 |
| Binarytrees | 4, unpinned | 8.97 (8.28–9.33) | 8.50 (8.23–9.37) | 26 → 18 | 0.66 → 0.63 |

One marker and Binarytrees run code this change does not touch and move
within their spread. Within one 7-run session few cells clear their spread
outright (bold here; over s1–s3, four of the 27 parallel cells), but the
shift is in every session. Pooled over
s1–s3, 21 runs per arm (`pool.py ns_per_obj base 1024 s1p:base:pb1024
s2p:base:pb1024 s3p:base:kept`, and the same for `u`):

| bench | config | base → 1 024 | change | P(1 024 < base) | p |
|---|---|---|---|---|---|
| Primes | 2 (default) | 7.34 → 7.26 | −1.1% | 0.63 | 0.16 |
| Primes | 4 | 6.32 → 5.08 | −19.7% | 0.86 | 6e-5 |
| Primes | 4, unpinned | 5.55 → 5.39 | −3.0% | 0.71 | 0.02 |
| JsonParsePure | 2 (default) | 7.44 → 7.19 | −3.4% | 0.69 | 0.03 |
| JsonParsePure | 4 | 5.47 → 4.84 | −11.5% | 0.90 | 7e-6 |
| JsonParsePure | 4, unpinned | 5.56 → 4.80 | −13.7% | 0.86 | 7e-5 |
| JsonGenerate | 2 (default) | 6.51 → 5.61 | −13.8% | 0.97 | 2e-7 |
| JsonGenerate | 4 | 4.80 → 3.82 | −20.4% | 0.93 | 2e-6 |
| JsonGenerate | 4, unpinned | 4.54 → 3.65 | −19.5% | 0.98 | 8e-8 |
| Binarytrees (serial) | 2 / 4 / 4 unpinned | 8.67 / 8.71 / 8.58 → 8.58 / 8.38 / 8.50 | −1.1 / −3.9 / −1.0% | 0.52 / 0.69 / 0.55 | 0.79 / 0.04 / 0.55 |

Binarytrees' p = 0.04 at "four workers", where it runs the serial drain,
is this table's floor for chance: Primes and JsonParsePure with the default
two workers are no better than it. What the batch buys is at four workers
on 4 CPUs on all three heaps (−11% to −20%), at four on 12 CPUs on
JsonParsePure and JsonGenerate (−14%, −20%; Primes −3%), and on
JsonGenerate with two; with two workers on Primes and JsonParsePure it is
inside the noise. Σ mark pooled:
Primes −22%, JsonParsePure −13%, JsonGenerate −17% at four workers pinned,
JsonGenerate −11% with two. Wall moved −2% to −4% on Primes and JsonGenerate
(p 0.02–0.06) and nowhere beyond the spread. Against the serial drain per
marked object, two workers are now 1.55× / 1.59× / 1.54× faster on Primes /
JsonParsePure / JsonGenerate (base 1.45× / 1.56× / 1.35×), four 2.13× /
2.49× / 2.21× (base 1.75× / 2.13× / 1.81×), all s3.

Mark stack mapped at exit (s3, `PROBE`): Primes with workers 256 → 512 KiB
(one more doubling, since markers hold more entries out of it),
JsonParsePure and JsonGenerate 1–2 MiB either way, one marker unchanged
(8 and 16 MiB).

A graph that is not crystal-metric (`gcp.py`, `gcp.txt`): `gc_phases
--seconds=2 --survival=0.5 --fanout=6 --shuffle`, the 2026-10-01 local-first
log's wide graph, base against `50b1315e`, 9 interleaved runs pinned to CPUs
0-3, the live floor off. Mean pause per collection, µs:

| objects, workers | base | 50b1315e |
|---|---|---|
| 64 B, 2 | 9 106 (8 922–11 264) | 9 461 (8 362–10 664) |
| 64 B, 4 | 5 823 (4 984–8 035) | 5 518 (5 007–8 607) |
| 512 B, 2 | 24 034 (23 101–25 392) | 24 018 (22 410–24 765) |
| 512 B, 4 | 13 662 (13 085–14 386) | 13 339 (12 483–14 970) |

All four inside the spread, allocations per run too: on this graph the
larger pop neither helps nor costs.

## Measured, not kept: interleaved `occ` and mark words

`measured-bitmap-interleave.patch` (on top of `50b1315e`): `occ[w]` at word
`2w` and `mark[w]` at `2w + 1` of the chunk's bitmap region, so the inline
candidate test (`scan_edges_inline`) reads one 16-byte pair, on one line,
where it read two words `bitmap_words` apart. Every reader and writer of the
two bitmaps strides by 2 (about 20 sites in `bitmap_alloc.cr`, `collect.cr`,
`collect_mark.cr`, `collect_sweep.cr`, `heap.cr`); the sweep's
`Kernels.sweep_words` and `popcount_words` were replaced by plain strided
loops, since the SSE/AVX2/NEON/SVE kernels assume two contiguous arrays.
Measured on the default (headerless) build; enough to run crystal-metric, not a
product patch. All 26 crystal-metric benches print the same result as base
and the kept commit (`s3-results.txt`).

ns per marked object, `kept` → `keptil` (s3: 7 runs, s4: 11 runs,
`s4p.txt`, `s4u.txt`):

| bench | config | s3 | s4 |
|---|---|---|---|
| Primes | 1 marker | 10.87 → 10.20 (−6.2%) | 9.85 → 9.85 (+0.3%) |
| Primes | 2 | 7.02 → 6.72 (−4.2%) | 7.12 → 6.30 (−11.5%) |
| Primes | 4 | 5.11 → 4.71 (−7.7%) | 5.01 → 4.81 (−4.1%) |
| Primes | 4, unpinned | 5.53 → 5.28 (−4.5%) | 4.25 → 4.14 (−2.5%) |
| JsonParsePure | 1 marker | 11.40 → 10.64 (−6.7%) | 10.39 → 10.21 (−1.8%) |
| JsonParsePure | 2 | 7.19 → 7.18 (−0.2%) | 6.42 → 6.45 (+0.5%) |
| JsonParsePure | 4 | 4.58 → 4.56 (−0.5%) | 4.21 → 4.38 (+4.2%) |
| JsonParsePure | 4, unpinned | 5.08 → 4.45 (−12.5%) | 3.89 → 3.99 (+2.6%) |
| JsonGenerate | 1 marker | 8.86 → 8.44 (−4.8%) | 7.88 → 7.64 (−3.1%) |
| JsonGenerate | 2 | 5.75 → 5.61 (−2.5%) | 4.92 → 4.88 (−0.8%) |
| JsonGenerate | 4 | 4.01 → 3.87 (−3.4%) | 3.31 → 3.34 (+0.8%) |
| JsonGenerate | 4, unpinned | 3.69 → 3.73 (+0.9%) | 3.39 → 3.35 (−1.2%) |
| Binarytrees | 1 marker | 9.07 → 8.70 (−4.1%) | 7.87 → 7.66 (−2.6%) |

No cell clears its spread in either session. With one marker, where the
2026-10-15 attribution put 13–29% of the inline path on these two words,
the interleave is lower on all four benches in s3 (−4% to −7%) and on three
of four in s4 (−2% to −3%; Primes +0.3%). Pooled over both (18 runs per
arm): Primes −4.8% (p 0.04), JsonParsePure −3.7% (p 0.07), JsonGenerate
−3.2% (p 0.27), Binarytrees −5.9% (p 0.09) — against a chance floor of
p ≈ 0.04 in the kept table above.
With workers the cells go both ways. The in-pause sweep (`sweep_ns`, s4)
was not slower with the scalar loop (Primes −10%, the others within
spread). Not kept: no win beyond the spread, and the real change is not
contained — new interleaved sweep kernels for four ISAs and their
equivalence fuzz (`make kernels-ir`, `kernels-broken`), the header layout,
and every walker of the two arrays.

## Gates (`gates.sh 50b1315e`, under `taskset -c 0-3`)

All exit 0 (`gates.txt`): `crystal spec -Dgc_none spec/all_specs.cr` (282
examples, the new one included), the same with `-Dgcry_block_headers`
(304), `crystal spec -Dgc_none process_spec` (200), `GCRY_BITMAP_ALLOC=0
crystal spec -Dgc_none -Dgcry_block_headers process_spec` (201), `make
parallel-mark-termination` (fixed arm 60 collections, 439 128 entries
stolen, no damage; the `GCRY_MARK_BUSY_UNLOCKED=1` arm red at its second
collection, `damage=chain 18 node 264`, now holding up to 1 024 unscanned
entries where it held 256), `make parallel-mark-process` (four workers
stole 356 569 entries in 4 runs with 31 wakes; `--disabled` stole 0), `make
mark-audit` (hold arm 199 missed, clean 0, control nothing walked), `make
lint`, `make windows-typecheck`, and `crystal build --no-codegen -Dgc_none
--cross-compile --target aarch64-apple-darwin samples/hello.cr`. Both
`spec/all_specs.cr` runs print the one `GCRY INVARIANT FAILURE: live_objects
mismatch: actual=1 reported=2` line the 2026-10-15 gates already had.

## CI

`50b1315e` pushed as `probe/parallel-mark-batch`. `ci.yml` run
38893200996 (dispatched with the 5 h soak by default) was cancelled for
38896277806 (`soak_duration=0`); `perf-ab.yml` run 38896881806 compares it
with `4fcee559` on `ubuntu-24.04-arm`, `macos-latest` and `windows-latest`
(10 reps, no Boehm arm). Both were still running when this log was
committed; their results are not in it.

## Files

- `FINDINGS.md`; `impl-s1.patch`, `impl-s2.patch` (the change as the s1 and
  s2 arms had it), `measured-bitmap-interleave.patch`.
- Scripts: `mkarms.sh`, `build.sh`, `main_probe.cr`, `marksum.py`,
  `pool.py`, `s1.sh`, `session.sh`, `s3.sh`, `gates.sh`, `gcp.py`. s2 was
  `session.sh s2 7 d,4 d base pb512 pb1024 pb2048 pb4096` and s4
  `SKIP_BUILD=1 session.sh s4 11 1,d,4 d kept keptil`.
- Data: `s1p/s1u/s2p/s2u/s3p/s3u/s4p/s4u.txt` with their `-raw.json`,
  `s3-results.txt`, `gcp.txt` and `gcp-raw.json`, `frames.txt`,
  `spec-red-release.txt`, `gates.txt`.
