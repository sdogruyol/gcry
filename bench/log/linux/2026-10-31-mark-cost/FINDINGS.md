# Per-object mark cost after 0.39's batch loop: where the instructions go, one trim kept, three loop shapes that lost (2026-10-31)

Follows `../2026-10-23-mark-cost/` (ROADMAP "Per-object mark cost on a large
pointer heap"). Host: the QEMU x86-64 guest of those logs (12 vCPUs at a
nominal 4.3 GHz, no PMU, SSE4.2, no AVX), Crystal 1.21.0, crystal-metric
`--release`, every run a fresh process under `taskset -c 0-3` (two mark
workers by default; `GCRY_PARALLEL_MARK=1` for one) and under the shared
heavy lock, with other agents' work on the remaining CPUs. Base is
`release-0.40.0` at `bf607374` (its `src/` is 0.39.0's; the trim's runner A/Bs
used `80d23a9d`, the same `src/`).

## Tools (this directory)

- `build.sh`: crystal-metric against a gcry source snapshot (`MS_SCRATCH`).
- `cg.sh` (cache simulation: D1 48 KiB 12-way, LL 32 MiB), `cgb.sh` (branch
  simulation), `cgi.sh` (instructions only): callgrind with one marker and
  `GCRY_COLLECT_SCRUB=0`, collecting only in `scan_batch_prefetched` (the
  serial drain's and every marker's batch scan, with `scan_edges_run`
  inlined into it), `scan_object` and `mark_impl*`.
- `cgev.py`: per-instruction self cost of every event of one function beside
  `objdump`, for those outputs.
- `../2026-10-31-parallel-mark-floor/ms.py`: the interleaved local runner
  (ns per marked object = Σ `mark_ns` / Σ `live_objects` over the run's
  collections, as in the earlier logs).

Every callgrind run below scanned the same work: 21.86 M objects, 218.6 M
payload words (the pacing under valgrind made the same collections each
time), so their instruction counts compare directly.

## Where JsonGenerate's mark goes (base, one marker)

`callgrind-cache-base-JG.txt`: 3.806 G instructions in `scan_batch_prefetched`.

| part | instructions | each | share |
|---|---:|---:|---:|
| word filter (`add`, `cmp`/`jae` end, load, `cmp`/`jb` lo; `cmp`/`jae` hi for the 32.8 M at or above lo) | 1.38 G | 6 a word | 36% |
| per object: entry prefetch 16 ahead (`prefetch_mark_entry`, tag decode, size, line loop) | 0.58 G | 27 | 15% |
| per object: pop, tag test, size, base-only and planted-miss tests, spills | 0.83 G | 38 | 22% |
| per candidate in the span (radix, header checks, reciprocal, mark and `occ` tests, `lock or`, push) | 1.00 G | 92 | 26% |

Of the 10.93 M words in the span, 10.93 M passed the header checks, 705 were
already marked, none failed the `occ` test, and 10.93 M were marked
(242 atomic leaves not pushed): JsonGenerate's graph is a tree.

**Caches** (callgrind ignores `prefetcht0`, so its misses on the payload
stand for the lines the prefetch has to cover): 29.1 M D1 read misses, 27.4 M
of them on the payload word load. The candidate chain's loads hardly miss:
radix L2 slot 49 k, chunk header 19 k, mark word 35 k, `occ` word 33 k D1
misses over 10.9 M candidates (under 0.5%).

**Branches** (`callgrind-branch-base-JG.txt`, callgrind's per-branch 2-bit
predictor — a much weaker one than any real core's): 875 M conditional
branches, 43.7 M mispredicted (5.0%), all but 0.2 M of them on two
branches: the payload loop's exit (21.86 M, one per object) and the
`w < lo` test (21.75 M).

**Throughput, not latency.** The same build marks JsonGenerate serially in
298 ms Σ over 13 collections scanning 2 349 MiB (3 runs). Scaled from the
callgrind run's 1 668 MiB, that is ~5.4 G instructions in 298 ms, ~18 G a
second: about 4.2 instructions a cycle at 4.3 GHz [INFERENCE: no PMU here,
so the clock and the count are not measured together]. At that rate the loop
is bound by how many instructions it issues, and the three shapes below
moved Σ mark in the direction and roughly by the size of their instruction
counts.

## Measured, not kept

Each is a `dropped-*.patch` against base.

| shape | instructions in the batch scan | Σ mark / ns per object |
|---|---:|---|
| base | 3.806 G | — |
| **unroll by four** (`dropped-unroll4.patch`): the word loop tests the end once per four words, each word's low-end test first, the candidate code inlined four times | 3.685 G (−3.2%) | locally (`local-unroll4.txt`, 7 runs): one marker Primes −1.5%, JsonParsePure −3.4%, JsonGenerate +0.9%; default +2.0%, +12.2%, +5.1% — nothing outside the spread |
| **skip four** (`dropped-skip4.patch`): one copy of the candidate code; a four-word loop skips words below the span (`cmp` with a memory operand, four fused branches) and a word loop finds the candidate in the quad | 4.057 G (+6.6%) | Perf A/B 41207501220, Σ mark against base: JsonGenerate +4.8% (x86), +12.1% (arm64), +6.3% (M1), +3.7% (Windows); JsonParsePure +6.6%, +2.1%, −1.0%, +7.8%; Primes +3.7%, +5.2%, +3.1%, +15.3% (`ci/`). Locally one marker JsonParsePure 9.97 → 10.88 ns per object |
| **candidate buffer** (`dropped-cand-buffer.patch`): every word of the batch's payloads written branch-free to a 512-word buffer mapped behind the batch, its index advanced by the span test (`cmp`/`adc`), the buffer resolved at the end of the batch or when full — no data-dependent branch per word | 5.540 G (+45.6%) | locally (`local-cand-buffer.txt`, 9 runs), ns per marked object, base → buffer: one marker Primes 9.72 → 12.48 (+28%), JsonParsePure 10.20 → 13.38 (+31%), JsonGenerate 8.03 → 10.26 (+28%), Binarytrees 7.55 → 9.91; every run of the buffer slower than every run of base. Its Perf A/B (41210630429) was cancelled for that |

The buffer took the 21.75 M `w < lo` mispredictions of the simulated
predictor out and cost 28–31%: the real cores predict that branch far
better than callgrind's model, and 11 instructions a word for the gather
(against 6) is what the time followed. Skip four lost because a quad that
holds a candidate is read twice and leaves and re-enters two loops.
Unrolling saved what it saved — 3% of the instructions, at the edge of what
interleaved local runs can resolve, and not worth a runner keep-rule run on
its own.

## Kept: unroll by four plus one-compare tag tests (`trim`)

`scan_edges_run` tests the payload's end once per four words, each word's
low end first and the high end in `scan_edge_word` (written as one
`w >= lo && w < hi`, LLVM evaluated both compares on every word and combined
them with `setcc`/`and`: 4.50 G instructions, +18%; the branchy form is the
one kept). The batch loop's "small tagged entry" test and
`prefetch_mark_entry`'s "untagged or rest" test are one unsigned compare each
(`tag &- 1 < classes`, `tag &- 1 >= SIZE_CLASS_COUNT`). The candidate code
moved unchanged into `resolve_candidate`. Callgrind: 3.510 G instructions
for 21.72 M objects, 161.6 per object against base's 174.1 (−7.2%).

Locally (9 interleaved runs, `local-trim.txt`) ns per marked object, one
marker: Primes −1.7%, JsonParsePure −0.9%, JsonGenerate −1.7%,
Binarytrees +3.1%; default +6.8%, −1.5%, +1.5%, −2.6% — inside the host's
spread. On the runners (Perf A/B 41213949301, 15 reps, `ci/`), Σ mark against
base:

| runner | Primes | JsonParsePure | JsonGenerate | JsonParseSerializable | JsonParsePull | Revcomp | RegexDna | Knuckeotide |
|---|---|---|---|---|---|---|---|---|
| `ubuntu-24.04-arm` | −3.9% | −7.0% | −8.6% | −11.9% | −11.5% | +5.9% | +3.9% | −1.7% |
| `windows-latest` | +1.6% | −5.3% | −1.3% | −4.9% | −3.1% | +2.5% | +5.5% | −11.9% |
| `macos-latest` | −0.7% | −5.0% | −0.5% | −7.0% | +2.3% | +2.5% | +3.9% | −14.5% |
| `macos-15-intel` | +32.7%² | −1.0% | +4.8% | +10.7%² | −3.8% | +5.6% | +3.7% | −3.2% |
| `ubuntu-latest` | +21.4%² | +0.1%¹ | −4.0% | +9.3%¹ | +7.0%¹ | +11.8%² | +4.6% | −6.0% |

¹ one more collection than base in the median run (`threshold_pace_pct`
turns a cheaper mark into a smaller threshold, as in `../2026-10-23-mark-cost/`).
² IQR spans zero by tens of points. Revcomp and RegexDna mark a few
milliseconds of large and atomic blocks; their Σ mark is not the change's.

**Keep rule.** Timed section or wall slower than base beyond the IQR in that
run: `ubuntu-latest` JsonParsePure +2.4%, JsonGenerate +2.6%,
JsonParseSerializable +4.0%, JsonParsePull +5.5%, Revcomp +2.7%;
`ubuntu-24.04-arm` JsonGenerate timed +0.7% [+0.2, +1.5] (wall −0.6%);
`windows-latest` RegexDna +0.8% [+0.2, +1.2]. Each was probed with
whole-program pads of both revisions in one session (timed section s,
revision at 0 / 16 / 64 bytes):

| run | runner | bench | new | base |
|---|---|---|---|---|
| 41216031947 | `ubuntu-latest` | JsonParsePure | 0.525 / 0.518 / 0.524 | 0.527 / 0.525 / 0.527 |
| | | JsonGenerate | 0.805 / 0.804 / 0.783 | 0.781 / 0.805 / 0.826 |
| | | JsonParseSerializable | 0.387 / 0.372 / 0.388 | 0.382 / 0.373 / 0.377 |
| | | JsonParsePull | 0.363 / 0.347 / 0.361 | 0.357 / 0.354 / 0.360 |
| | | Revcomp | 0.851 / 0.772 / 0.818 | 0.814 / 0.798 / 0.793 |
| 41221127852 | `ubuntu-24.04-arm` | JsonGenerate | 1.081 / 1.089 / 1.072 | 1.070 / 1.073 / 1.093 |
| 41219560170 | `windows-latest` | RegexDna | 3.444 / 3.429 / 3.479 | 3.442 / 3.452 / 3.510 |

Every new range overlaps base's: placement. In those same sessions the
unpadded new build was level with base (`ubuntu-latest` +0.6% to +2.3%
timed except Revcomp +4.9%, its slow layout; arm64 JsonParsePure −1.6%;
Windows RegexDna +0.2% [−0.1, +0.5]). Peak: every row at or under 1.07×
Boehm on every runner but Knuckeotide (1.13–1.66×, the documented
exception); JsonParsePure's 1.07× on arm64 and Windows is base's too.

**Soundness.** `GCRY_MARK_AUDIT=1` on all 26 crystal-metric benches, one
marker and default (`audit.sh`, `main_audit.cr`, `audit-trim.txt`): 52 of 52
runs with 0 misses (JsonGenerate 32.5 M edges, JsonParsePure 32.0 M, Primes
10.4 M, Binarytrees 2.9 M; the default runs marked in parallel where the
floor allows). Exit 1 on seven rows is crystal-metric's `err` line, which base
and Boehm print too on Crystal 1.21. `make mark-audit`: hold 1 021 edges
walked, 199 missed (the planted miss still applies on this path); clean
1 418, 0; control nothing walked. `make parallel-mark-termination`: fixed
arm 60 runs, 693 885 entries stolen; unlocked arm red. `make
parallel-mark-stress` 10 of 10; `make chunk-list-drift` 0 of 24 processes
stranded a chunk. The words scanned, their order and every per-candidate
decision are the old loop's.

## What is left

The kept trim takes 7% of the instructions; the candidate chain is still not
where the time is on this heap: its loads hit L1
and its branches predict, and the four earlier attempts at it — the size
class in the radix entry, `occ` and mark words interleaved, a one-entry
chunk cache, a plain mark store when serial (`../2026-10-23-mark-cost/`,
`../2026-10-15-mark-cost/`) — all landed inside the spread. A further gain
has to remove instructions: the word filter (36%) and the per-object
overhead (37%) are the bulk, and no loop shape tried here cut either by
more than a few percent without adding more elsewhere.
