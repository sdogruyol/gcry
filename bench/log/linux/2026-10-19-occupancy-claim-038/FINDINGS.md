# The occupancy claim on the 0.38 base: sound, shipped in 0.38.0 (2026-10-19, decided 2026-10-20)

`bench/log/linux/2026-10-17-occupancy-claim/` describes the change: a cursor
claims a word's free blocks in `occ` with one atomic and hands them out with
no shared write. It failed the keep rule on the 0.37 base. This cut ports it
onto `release-0.38.0` and re-runs the correctness evidence. It then measures
the change on all five runners and separates the schedule effects from the
claim's own cost.

Branch `occupancy-claim-038`, rebased onto `origin/release-0.38.0` at
`4fc3fe53`. Bottom up:

- `c2dd2226`: the allocation entry's fork check keeps its message buffer
  out of line. This is the fix for item 3 below, and it is independent of
  the claim (`../2026-10-20-alloc-entry-frame/`).
- Its findings.
- The three cherry-picks of `35e51828`, `95e73e39` and `dc4d14b6`.
- This folder.

**Final verdict (2026-10-20), measured on top of the fix and against base
plus the fix:** see "On top of the frame fix" at the end. The JSON peaks'
+8% and the x86 Linux wall cost are gone. Binarytrees gains 2 to 20
points of Boehm on every runner. What is left: JSON-row peak rises of
+0.3% to +1.1% on Linux and macos-15-intel, not attributed; Revcomp +1.4%
on ubuntu-latest, covered by placement; and Knuckeotide's peak, which is
stack pinning.

The sections between here and the last one are the first round, on
`16b7e67c` without the fix (var `24df3da5`). That round found three
things:

1. JSON rows' peak was +8% on both Linux runners: the pace. With the pace
   off it was +0.8–0.9%, and that remainder was item 3.
2. Some rows on `ubuntu-latest` were slower beyond their spread: three JSON
   rows +1.7–3.5% wall, Revcomp +2.2%. Placement probes of the same source
   covered it.
3. With the schedule pinned, about 25 MB more large mappings were unmapped
   and mapped again: +4.8% page faults, +1.3% peak. Attributed and fixed on
   2026-10-20. A 512-byte unwritten buffer in `GC.malloc_atomic`'s frame
   held a dead 33.5 MB buffer through one more collection.

Knuckeotide's peak rise is conservative stack pinning, in a crystal-metric
frame whose layout the inlined allocation path changes. Knuckeotide is
outside the RSS budget.

## Correctness on the 0.38 base

All local (QEMU x86-64 guest, 12 vCPU), Crystal 1.21.0, release builds for
the loops, one heavy-lock hold per run. Logs in `stress/` and `red/`.

- `claim_stress --seconds=5 --workers=4`, lazy sweep, seeds 3001–3100:
  **100 of 100 passed**. In-stop sweep (`GCRY_DISABLE_LAZY_SWEEP=1`), seeds
  4001–4050: **50 of 50 passed**.
- `stw_mt_property_test --iterations=200 --workers=2,4` under
  `bench/run_bounded.sh 600`, seeds 6001–6200: **196 passed, 0 failed, 0
  gcry stalls**. 4 runs (6008, 6015, 6094, 6175) exited 3, the Crystal
  Parallel-scheduler resume deadlock: in each, four threads sit in
  `parallel/scheduler.cr:97` and no collector frame shows
  (`stress/stwmt-*.log.gz`).
- `mt_property_test --iterations=500 --workers=2,4,8`, seeds 7001–7050:
  **50 of 50 passed**.
- `make counter-loss chunk-list-drift thread-churn-uaf large-cache-race`:
  all exit 0. Counter-loss's plain red arm drifted in 6 of 6 rounds, as it
  should.
- Red arms (`red/`, patches from the 0.37 findings, applied to the port;
  r5 to `release-0.38.0` with `bench/claim_stress.cr` added). **Every arm is
  caught**, with the same signatures as on 0.37:

| arm | spec | `claim_stress`, 3 runs |
|---|---|---|
| r1 free reads raw `occ` | "Expected ArgumentError but nothing was raised" | — |
| r2 settle does not mark pinned claims | spec 74: `occ & claim` = 0 | in-stop 3 of 3: refused frees 21 039 / 22 501 with drift, one SIGSEGV |
| r3 claim never marked while a sweep can run | claim swept (`occ & claim` = 0) | lazy 3 of 3: 127 946–142 477 legitimate frees refused, drift |
| r4 retire does not release | `cursor_claims_released` 0 for 63 | lazy 3 of 3: walk drift +1 223 to +1 736 |
| r5 plain per-block OR on the base tree | — | lazy 3 of 3: live drift +1 733 to +1 740 |

- Both spec suites, both `process_spec` arms, `make lint`,
  `make windows-typecheck` and the darwin cross-compile pass on the rebased
  tree (listed in the hand-off).

## Five runners, default schedule

`Perf A/B`
[39381964928](https://github.com/sdogruyol/gcry/actions/runs/39381964928):
var `24df3da5`, base `origin/release-0.38.0` (`16b7e67c`), nine
crystal-metric rows, 15 interleaved reps, Boehm, Kemal 15 trials,
`stats=3`. Files are `perf-<runner>/`. Cells are var against base, median
[IQR] of paired reps.

| runner | Binarytrees, % of Boehm | its wall | slower beyond spread (wall) | peak worse beyond spread |
|---|---:|---:|---|---|
| ubuntu-24.04-arm | 75% → **88%** | −14.5% [−15.8, −13.8] | Revcomp +0.6% [+0.5, +1.0], RegexDna +0.3% [+0.1, +0.4] | **Knuckeotide +36.7% [+23.0, +41.0]** (1.11× → 1.59×); JsonParseSerializable +8.2%, JsonParsePull +8.2% (0.83× → 0.90×) |
| ubuntu-latest | 95% → **98%** | −4.4% [−5.0, −3.1] | **JsonParsePure +1.7% [+0.8, +2.8], JsonParseSerializable +2.6% [+1.8, +2.9], JsonParsePull +3.5% [+2.9, +4.4], Revcomp +2.2% [+1.8, +2.4]** | Knuckeotide +19.6% [−2.5, +25.2] (1.31× → 1.53×); JsonParseSerializable +8.3% (0.76× → 0.82×), JsonParsePull +8.6% (0.80× → 0.87×) |
| macos-latest | 88% → **92%** | −5.1% [−10.0, −2.8] | none | none (JsonParseSerializable −5.7%, JsonParsePull −3.9%) |
| macos-15-intel | 129% → **138%** | −8.1% [−11.2, −6.1] | none | none (Knuckeotide −16.0%, 1.79× → 1.42×) |
| windows-latest | 116% → **120%** | −4.3% [−7.0, −0.0] | none | none |

Kemal `/json`, % of Boehm base → var: ubuntu-latest 108.2% → 107.2%,
ubuntu-24.04-arm 101.2% → 101.9%, macos-latest 106.5% → 106.5%,
macos-15-intel 111.9% → 116.4%. Every pair's IQRs overlap, and peaks are
level (1.00×, 1.31×, 1.38× → 1.36×, 1.39×). Windows has no wrk.

Collections and Σ scanned are unchanged on every JSON row and on Revcomp
(`+0.0%`), so the x86 wall cost is not more collector work. RegexDna's Σ
scanned is +50.4% on arm64 only, the same as on 0.37, with collections and
peak unchanged [INFERENCE: a stack-held pointerful object, like Knuckeotide;
not checked on arm64].

## The schedule pinned: what the claim costs by itself

Pacing (`THRESHOLD_PACE_MAX_PCT`) is the one part of the schedule that reads
time. Everything else follows bytes. The task's candidates for the claim
moving the schedule were bytes accounting of claimed blocks, live bytes
counting claims, and allocate-black of whole words. None of these holds on
this tree:

- **Bytes.** The hit path credits `bytes_local` per hand-out, as base does,
  and the claim adds nothing to it. With pacing off, the local
  JsonParsePull trace (`GCRY_TRACE`) has identical thresholds, live bytes,
  scanned bytes and heap sizes at every one of its 20 collections. The only
  difference is the heap size at collection 15, +256 KiB.
- **Live bytes.** The sweep subtracts a cursor chunk's claim from `live`, so
  `size_class_live_bytes` is equal (the same trace).
- **Allocate-black.** A word claimed while a cycle or a sweep can run stays
  marked only until the next major's mark clear. Its unhanded blocks are
  ANDed out of `mark` at release, so they never reach a threshold
  computation.

The pace is allocated × cycle time ÷ mutator time. Allocated is identical
(8.4 MB at collection 2 on both trees, debug build). Cycle and mutator time
are where any difference comes from (`local/jsonparsepull-local.txt`). On
the local guest their run-to-run spread (at collection 2 the pace was 111–223 over 8 earlier runs of each tree)
covers any difference between the trees.

The probe pins the schedule on both sides. Branches
`occ038-probe-base-nopace` (`2fd6806a`, release-0.38.0 with the constant at
100) and `occ038-probe-var-nopace` (`1141ab5e`, the port with the same
change) were dispatched as `Perf A/B`
[39384545534](https://github.com/sdogruyol/gcry/actions/runs/39384545534):
six rows, 15 reps, `stats=3`, files in `pinned-<runner>/`. Collections and
Σ scanned are +0.0% on every JSON row on all three runners:

| row | ubuntu-latest wall | ubuntu-24.04-arm wall | windows-latest wall | peak, both Linux |
|---|---:|---:|---:|---:|
| JsonParsePure | **+1.6% [+1.1, +2.0]** | −1.0% [−1.4, +0.1] | −0.6% [−5.3, +0.6] | +0.0% |
| JsonGenerate | +0.5% [+0.2, +1.0] | −0.1% [−0.5, +0.2] | −1.0% [−2.8, −0.4] | +0.0% |
| JsonParseSerializable | **+2.4% [+1.7, +2.7]** | −0.5% [−1.2, +0.1] | −1.1% [−4.1, +1.1] | **+0.8 / +0.9%** |
| JsonParsePull | **+2.9% [+2.3, +3.4]** | −0.7% [−0.8, −0.3] | +4.1% [−5.4, +4.9] | **+0.9 / +0.9%** |
| Binarytrees | −3.6% [−4.7, −2.3] | −14.6% [−14.9, −14.0] | −18.0% [−19.4, −15.3] | +0.2 / +0.1% |
| Knuckeotide | −2.6% [−3.4, −1.5] | −2.5% [−2.9, −1.2] | −0.9% [−5.2, +1.0] | +1.3% [+0.0, +13.0] / +2.1% [−1.2, +10.9] |

So:

- **JSON peak +8% is the pace.** With pacing off it is +0.8–0.9%, with the
  same collections. The pace answers a different timing input, not a
  different byte count. The rule's exception covers only stack pinning, so
  this rise still fails it. On Linux both rows stay at or under 0.90× Boehm.
- **The x86 Linux wall cost survives the pinned schedule**, so it is not
  schedule. It is absent on Windows' x86 and on macos-15-intel (−1.5 to
  −2.3% there in the default run).

### Placement: the x86 Linux cost moves with code layout

`Perf A/B`
[39390349335](https://github.com/sdogruyol/gcry/actions/runs/39390349335)
on `ubuntu-latest` (files in `pads-ubuntu-latest/`): base, var, and five
placement probes of var (`pads="16 2096 p16 p2096 p4096"`). The probes are
the same source with nops ahead of the benchmarks or of all the code. 15
reps, no Boehm. Wall as % of base (higher = faster):

| row | var | pad16 | pad2096 | prepad16 | prepad2096 | prepad4096 |
|---|---:|---:|---:|---:|---:|---:|
| JsonParsePure | 98% | 100% | 101% | 98% | 101% | 99% |
| JsonGenerate | 100% | 100% | 101% | 99% | 101% | 99% |
| JsonParseSerializable | 97% | 100% | 101% | 99% | 100% | 98% |
| JsonParsePull | 96% | 99% | 101% | 97% | 99% | 97% |
| Revcomp | 98% | 102% | 102% | 101% | 101% | 99% |
| Binarytrees | 104% | 108% | 106% | 103% | 105% | 103% |

Every row has a probe at or above base: pad2096 is 101% on all four JSON
rows, and the pads put Revcomp at 99–102%. In the timed section the probes
beat var itself by 2–8% on the JSON rows and by 8.3–11.5% on Revcomp. Code
placement alone therefore moves these rows by more than var's whole
deficit on this runner. The source change does not cost x86 Linux
[INFERENCE: the pads move code, not frames, so this does not prove the
per-allocation cost is zero; it shows the measured deficit is inside what
placement does]. The same runner's Kemal row carries an open placement item
(ROADMAP, `a975d5cd`). On arm64, Revcomp +0.6% and RegexDna +0.3% had no
placement probe run.

Faults are +2.8% to +4.8% on JsonParsePure, JsonParseSerializable,
JsonParsePull and Revcomp, for var and for every probe alike. That is the
third item, below.

### What the pinned schedule leaves: more chunks unmapped and mapped again

Locally, pacing off, JsonParsePull is deterministic. Var takes 133 241–133 249
minor faults against 127 103–127 107 (+4.8%) and peaks at 423.0–423.2 MB
against 417.5–417.8 MB (10 runs each over two sessions) (+1.3%). Its `unmapped_bytes` is 501 575 680 against
476 409 856: **25.2 MB more chunks unmapped and mapped again**, with the
same `heap_size`, collections, `sweep_cursor_pinned` (20 / 20),
`sweep_cursor_retired` (0 / 0), `release_refused_cursor` (0 / 0) and
`fast_miss_refill` (4 137 / 4 137); var releases 5 975 claims
(`local/jsonparsepull-local.txt`). 25.2 MB is 6 150 pages, the fault
difference. So some chunk reads empty at a sweep on var where base still
holds something in it, or the other way round, and the freed chunk is
mapped back in later. Which chunks, and why the claim's word-at-a-time
hand-out changes which chunks empty, was not found. This is the +0.8–0.9%
pinned peak on the Linux JSON rows; Windows shows +0.0% [INFERENCE: its
chunk release differs; not examined].

## Knuckeotide's peak is stack pinning, and this shows where

The 0.37 findings put the rise on one dead 6.1 MB buffer kept by words on
the main fiber's stack, without naming the frame. On this tree
(`local/knuckeotide-holder.txt`; `local/holder_gdb.py` breaks at the 31st
`run_collection_body` and scans the main stack for words into the buffer):

- The buffer is the 6 100 096-byte Fasta output string built in
  `Knuckeotide#initialize` (`res = f.@result.to_s`, the 6.1 MB map at
  collection 2 in `GCRY_TRACE_LARGE`). It is dead once the constructor
  returns.
- **On var one word holds it**, at `0x7fffffff8fa0`. That is 0x40 above the
  stack pointer of `*Benchmark::run<(String | Nil)>:Nil`, crystal-metric's
  driver, which inlines the constructor and the timed run. **On base no
  word on the stack points into it.**
- `Benchmark::run` is 0x1774e bytes on base and 0x17dcc on var (+1 662), and
  its frame is `sub $0x3fd8,%rsp` against `sub $0x3ff8,%rsp` (+32 bytes).
  The inliner makes different choices around gcry's allocation path: 71
  out-of-line calls to `GC::malloc_atomic<UInt64>` on var against 43, and
  different `String::new` inlining. The same dead slot sits at a different
  frame offset, and on var nothing later overwrites it.
- It is layout, not the claim. The exit-counter build (`gc_counters.cr`
  main) of var keeps 13.6 MB of large mappings (base 3.3 MB, 3 of 3 runs
  each). A build with another main and the same gcry source, `qvar`, keeps
  0.26 MB, while `qbase` keeps 3.3 MB (`@seq`, live).
- The run frees the buffer late, so the threshold stays high and the
  collections are fewer: −2.9% (x86) and −6.8% (arm64) in the default run,
  Σ scanned −17% and −10%. The peak follows.

Knuckeotide is outside the RSS budget. Its rise is this effect, and
macos-15-intel's −16% (1.79× → 1.42×) is the same effect going the other
way. This row alone would not block the change. arm64 was not examined with
gdb [INFERENCE: the same mechanism, from the same counters' signature:
collections down, Σ scanned down, peak up].

## What is left, precisely

1. **The JSON peaks' +8% on Linux are the pace.** The claim does not change
   the bytes the threshold sees: allocated, live and scanned bytes are equal
   at every collection. It changes the time the pace reads. Shipping needs
   one of two things: a pace input that is the same for equal work, such as
   cycle cost measured in bytes marked instead of in ns, or a ruling that a
   pace-driven peak within budget (0.82–0.90× here) is acceptable. Not
   attempted here: either is a change to the schedule's design, outside
   this change.
2. **x86 Linux wall, +1.7–3.5%**, is inside what placement moves on
   `ubuntu-latest`, shown by the pad arms. The keep rule as written counts
   it; a placement exemption is the maintainer's call, as for the Windows
   Revcomp item.
3. **The +25 MB unmap/remap churn** under the pinned schedule: +4.8%
   faults and +0.9–1.3% peak. (Found and fixed 2026-10-20: see the last
   section.) Next: log each sweep's
   empty-chunk decisions (chunk, class, live, claimed) on both trees under
   `GCRY_THRESHOLD_PACE=100` and diff them.

## Runs and branches

| run | what | head |
|---|---|---|
| [39381964928](https://github.com/sdogruyol/gcry/actions/runs/39381964928) | five runners, nine rows, Boehm, Kemal, stats | `24df3da5` (`occupancy-claim-038` before the rebase) |
| [39384545534](https://github.com/sdogruyol/gcry/actions/runs/39384545534) | pacing off on both sides, three runners | `1141ab5e` (`occ038-probe-var-nopace`) against `2fd6806a` (`occ038-probe-base-nopace`) |
| [39390349335](https://github.com/sdogruyol/gcry/actions/runs/39390349335) | placement probes, ubuntu-latest | `24df3da5` |

The probe branches were deleted after these runs. No CI (`ci.yml`) run was
made for this port.

## On top of the frame fix (2026-10-20)

**What the churn was.** Item 3 was not the claim's semantics. It was the
large cache, not size-class chunks: per-site `@unmapped_bytes` puts all
+25.2 MB in `trim_large_cache`, and the sweep's chunk flush is equal on both
trees. With the claim, `Heap#malloc_atomic` is inlined into
`GC.malloc_atomic`, so that frame is the one live across an
allocation-triggered collection. It held 512 unwritten bytes,
`check_fork_poison!`'s message buffer. One stale word there kept a dead
33.5 MB `IO::Memory` buffer marked through one more collection, and the
large cache then recycled a different mapping. The trace, gdb holder and
counts are in `../2026-10-20-alloc-entry-frame/`, along with the fix's
regression (process_spec 79, `make alloc-entry-frame`) and its own
five-runner numbers. With the fix the same claim build matches base's
faults and peak on JsonParsePull in 8 of 8 local runs.

**Claim on the fix, five runners.** `Perf A/B`
[39419215218](https://github.com/sdogruyol/gcry/actions/runs/39419215218):
var `ea37bd3a` (this branch then), base `occ038-probe-base-fix`
(`c2dd2226`: release-0.38.0 `4fc3fe53` plus the fix). Nine rows, 15 reps,
Boehm, Kemal 15 trials, `stats=3`. Files in `claimfix-<runner>/`, all rows
in `claimfix-table.txt`. Var against base:

| runner | Binarytrees, % of Boehm | its wall | slower beyond spread (wall) | peak worse beyond spread |
|---|---:|---:|---|---|
| ubuntu-latest | 84% → **103%** | −18.0% [−19.4, −17.1] | Revcomp +1.4% [+1.0, +1.9] | Knuckeotide +20.0% (1.33× → 1.68×); JsonParsePure +0.3% [+0.2, +0.4] |
| ubuntu-24.04-arm | 84% → **100%** | −15.8% [−17.7, −14.9] | none | Knuckeotide +24.1% (1.16× → 1.48×); JsonParsePure +0.2%, JsonParseSerializable +0.8% [+0.4, +1.2], JsonParsePull +1.0% [+0.8, +1.3] |
| macos-latest | 89% → **93%** | −3.0% [−7.4, −2.1] | none | none (JsonParseSerializable −8.7%, JsonParsePull −6.9%) |
| macos-15-intel | 126% → **146%** | −11.6% [−13.0, −10.3] | none | JsonParsePull +1.0% [+0.6, +1.7] |
| windows-latest | 119% → **121%** | −1.0% [−3.0, −0.5] | none | none |

- **The JSON peaks' +8% is gone.** Before the fix both Linux runners read
  +8.2% to +8.6% on JsonParseSerializable and JsonParsePull. Now they read
  −1.7% to +1.0%. The pace was answering the dead 33.5 MB buffer's extra
  cycle, not the claim.
- **The x86 Linux wall cost is gone.** Every JSON row on ubuntu-latest is
  −0.3% to −1.0%, against +1.7–3.5% before. Revcomp +1.4% is left. The
  placement run [39428951848](https://github.com/sdogruyol/gcry/actions/runs/39428951848)
  (`claimfix-pads2-<runner>/`, `pads="2096 p16 bp2096 bp16"`, both Linux
  runners) reads Revcomp at var 99% of base, var pads 99%, base pads 99–100%
  on ubuntu-latest: inside the spread.
- **Kemal `/json`**, % of Boehm base → var: ubuntu-latest 105.3% → 104.8%,
  ubuntu-24.04-arm 105.3% → 105.6%, macos-latest 104.0% → 108.4%,
  macos-15-intel 110.1% → 103.2%, every IQR overlapping, peaks level.
  Kemal placement on ubuntu-latest,
  [39429025751](https://github.com/sdogruyol/gcry/actions/runs/39429025751)
  (`claimfix-kemal-pads-ubuntu-latest/`, 20 trials, `p0..p48 bp0..bp48`):
  base 103.0%, var 105.2%, base pads 101.8–105.5%, var pads 103.0–105.5%.
- **Knuckeotide** +20% / +24% peak on Linux with 3–6% fewer collections and
  Σ scanned −22% to −24%: the signature of the stack pinning shown above.
  It is outside the budget.
- **Left, not attributed:** JSON-row peaks +0.2% to +1.1% beyond spread on
  arm64 (in both this run and the placement run) and macos-15-intel
  JsonParsePull +1.0%. Every one stays at or under 0.90× Boehm. Revcomp
  takes +3.4% faults on both Linux runners at an unchanged peak.

**Keep rule, read strictly:** speed passes. No row is slower beyond its
spread except Revcomp on ubuntu-latest, which placement covers. RSS passes
everywhere except the ≤1.1% JSON-row peak rises above, which are inside the
budget but neither stack pinning nor attributed. Knuckeotide is
stack-pinning and exempt. The decision on those is the maintainer's.

**Decision (2026-10-20): shipped in 0.38.0.** The maintainer took the change
with the ≤1.1% JSON-row peak rises (every row at or under 0.90× Boehm's peak,
inside the RSS budget) and Revcomp's +1.4% on ubuntu-latest (inside the
placement spread) accepted as they are.

Correctness on the final tree: `claim_stress` 100 lazy + 50 in-stop passed;
`mt_property_test` 50 of 50; `stw_mt_property_test` 199 of 200 with 1
Crystal scheduler deadlock (exit 3, `stress/final-stwmt-*.log.gz`). Both
spec suites, both `process_spec` arms, lint, the Windows and Darwin
typechecks, the four make stress gates, `make fork-test` and
`make alloc-entry-frame` all pass (`stress/summary-final.txt`).

Runs on the fix: 39419212059 (fix alone, five runners), 39414298640 (fix
alone, Linux, first), 39429021296 and 39429069428 (fix-alone placement),
39419215218 (claim on the fix, five runners), 39428951848 and 39429025751
(claim placement). Also 39414207840: claim plus fix against base without
the fix; macOS failed on the Kemal `cp` cycle, since fixed in `4fc3fe53`,
and that run's Linux and Windows halves are in `claimfix-vs-base-<runner>/`.
Probe branch `occ038-probe-base-fix` was deleted after the runs.

