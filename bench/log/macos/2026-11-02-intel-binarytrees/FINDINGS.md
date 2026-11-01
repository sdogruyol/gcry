# macos-15-intel Binarytrees, 0.40 against 0.39.0 (2026-11-02)

The question: on `macos-15-intel`, Binarytrees in the 0.40 tree (`87ccf4f4`)
reads 3–6% slower than `v0.39.0` (`c0d570c5`), sometimes outside the keep
rule's pad band (PaceGrowth's 41306370503 +5.7%, 41306378233 +3.6%). Is it
code placement, the high heap, or a commit?

**Answer: none of them alone. Two commits together: FREEING (`6aa84284`,
`e3a2de7a`) and the large-cache counters (`f18e9c17` and its follow-ups).
Each of the two changes the allocation hit path's machine code in
`Heap#malloc`, and either change is enough to keep the slowdown.** The time
goes to the mutator, not to the collector. The fix moves the word advance
out of line and moves FREEING's three fields after the hit path's fields.
With both changes, Binarytrees reads as 0.39.0's pad arms do.

All sessions ran on `i7-8700B` runners, Crystal 1.21.0 (LLVM 15.0.7),
interleaved per rep, 21 reps, `base` = `v0.39.0`. They come from the probe
workflow `probe/intel-bt` (push-triggered, full SHAs, deleted afterwards;
`probe-intel-bt.yml`, `probe-ab.patch`: `AB_REVERTS` and `AB_PATCHES` arms,
and Σ pause/sweep recorded per run). Raw runs are in `runs/<id>-s<N>.json`
(with `scanned_per_collection` dropped). `python3 tab.py <id>` prints every
arm against base and var.

| run | arms (besides base, var) | control |
|---|---|---|
| 41308869235 (3 sessions) | `var_env` = `GCRY_HIGH_HEAP=0`, `rv_unroll` (`cbf1b2e8`), `rv_freeing` (`e3a2de7a`+`6aa84284`), `rv_counters` (`2e91d538`+`606017b0`+`b8bbd85c`+`f18e9c17`), pads p16 p64 bp16 bp64 | Nbody |
| 41312559042 (3) | `rv_all` (the three reverts together), `rv_mem` (those plus the high-heap and fence commits `b4a707f4` `16d7112d` `e6149bcb` `28780034`), pads p16 p32 p48 p64 bp16 bp32 bp48 bp64 | Nbody |
| 41315976650 (3) | `rv_all`, bench-only pads 16 48 1040 2096 b16 b48 b1040 b2096 | Nbody |
| 41320057272 (1, 1 rep) | disassembly of `Heap#malloc` for base, var, rv_freeing, rv_counters, rv_all (`dis/`) | — |
| 41321793091 (3) | `rv_all`, patches f1 f2 f12 f13 (below), pads p16 bp16 | Nbody |
| 41325522076 (3) | `rv_all`, patches f2 f4 f24, pads p16 bp16 | Nbody |

## 1. Per arm, over all sessions

The table shows the median of the per-rep paired timed-section ratio against
base, averaged over the sessions an arm ran in (min to max in brackets).

| arm | sessions | vs base | vs var |
|---|---:|---|---:|
| base-code pads (bp16…bp64, b16…b2096) | 3–12 each | −2.8 to +1.1 (min −5.0, max +2.9) | −2.9 to −7.4 |
| **rv_all** | 12 | **+0.9** (−2.5, +3.3) | −3.7 |
| rv_mem | 3 | +0.4 (−1.1, +1.2) | −4.6 |
| **f24** (the fix) | 3 | **+1.2** (+0.5, +1.7) | −3.3 |
| f2, f4, f1, f12 | 3–6 | +2.5 to +2.7 | −1.2 to −1.9 |
| rv_counters | 3 | +3.1 (+2.5, +3.8) | −1.8 |
| var-code pads (p16…p64, 16…2096) | 3–12 each | +2.7 to +6.9 | −2.2 to +0.3 |
| **var** | 15 | **+4.3** (+1.3, +7.7) | — |
| var_env (`GCRY_HIGH_HEAP=0`) | 3 | +5.2 (+4.4, +5.8) | −0.1 |
| rv_freeing, rv_unroll | 3 each | +5.7 | +0.5, +1.3 |

Nbody (no allocation), var against base, each session: −2.2% to +1.6%, every
IQR spanning zero.

## 2. Not the high heap

`var_env`, the same binary with `GCRY_HIGH_HEAP=0`, against var: +1.9%
[−0.8, +5.6], −2.5% [−8.1, +3.1], +0.3% [−1.3, +3.9]. `rv_mem`, which also
takes out the high heap's code, reads as `rv_all` (+0.4 against +0.9). Faults
are within 5% everywhere (14.3–16.4 k per run, either way). The counter
runs in 41308869235 show `high_heap_misses=0` and bases from 20.7 to
30.7 TiB.

## 3. Not one commit, and not the unroll

`rv_unroll`, `rv_freeing` and `rv_counters` each stay slow (+5.7, +5.7 and
+3.1 against base). Only `rv_all`, which reverts all three, comes down into
the base pads' band: against var −3.3, −3.9, −2.9 (41312559042), −5.3, −4.3,
−3.1 (41315976650), −5.2, −1.5, −2.0 (41321793091), −4.0, −3.8, −4.7
(41325522076). Reverting the unroll on top of the other two adds nothing,
since `f24` keeps the unroll and reads like `rv_all`.

## 4. Where the time goes: the mutator

Σ pause is the same for base and var (41312559042: 160.5/160.2,
170.6/174.0, 164.2/156.1 ms), and Σ mark is equal or lower in var. All of
var's extra time is time − Σ pause (+7.2%, +7.5%, +1.6% there), and so is
user time. Var runs 3–6% more collections, but that follows from the slower
mutator, not the other way round. The pace is time-based
(`Heap.threshold_pace_pct`: cycle time over mutator time), so a slower
mutator gets a smaller threshold. The base-code pads show it too: the slower
ones collect more.

## 5. Mechanism: `Heap#malloc`'s machine code

The hit path (`Heap#fast_alloc`, inlined into `Heap#malloc`) is the same
source in 0.39.0 and 0.40. `GC::malloc` and `TreeNode` are byte-identical.
`Heap#malloc` is not (`dis/heap-malloc-*.s`):

- base and rv_all: the same instructions, a 0x88 frame, 18 stack stores;
- var, rv_freeing, rv_counters: a 0x98 frame, 19 stack stores. On every
  allocation the hit path spills `bytes_local` (`local`) and the size-class
  index (`movq %rsi, -0x38(%rbp)`, `movq %rsi, -0xa0(%rbp)`) and reloads
  them (`-0xa0(%rbp)` before the `bytes_local` store, `-0x38(%rbp)` for
  `@block_bytes[index]`). [INFERENCE] The `local` round trip adds a
  store-forward to the loop-carried `bytes_local` chain, about the measured
  ~1 ns per allocation.
- FREEING also adds three typed fields in `bitmap_alloc.cr`
  (`cursor_free_deferrals`, `bitmap_free_split_hook`,
  `bitmap_free_claim_guard`). Crystal lays out typed ivars first, so these
  moved 651 of the heap's 679 0.39.0 fields by 32 bytes, every field the hit
  path reads among them (`runs/offsets-*.txt`, from `offsets.cr`). The
  counters commit changes the register allocation without moving the hot
  fields. That is why neither single revert restores the 0.39.0 code.

Placement probes do not reach the gap. Prepads move all code together.
Bench-only pads move `TreeNode` relative to the collector. Every var-code
arm, at every alignment mod 64 of `Heap#malloc`, stays above every
base-code arm except one. `layout.py` (run on the downloaded artifacts,
which hold `syms/`) shows the slowest arms all share var's `Heap#malloc`
code.

## 6. Fix and A/B

The candidates, each a patch on var (`AB_PATCHES`; `f24.patch` is what
landed):

- f1: re-read `bytes_local` at its store instead of keeping `local` live.
  This removes one spill, but the frame stays 0x98: +2.5.
- f2: `cursor_advance_word` `@[NoInline]`. It runs once per word, up to 64
  hand-outs. `Heap#malloc` drops to 302 lines, a 0x28 frame and 5 stack
  stores: +2.5 over 6 sessions.
- f4: FREEING's fields declared inferred, last (in this probe at the end of
  `thread_block_audit.cr`). Every 0.39.0 field is back at its offset: +2.5.
- f13 (f1, plus `@block_bytes[index]` read before the sentinel): +5.4,
  worse.
- **f24 = f2 + f4: +1.3 [−2.4, +3.9], +0.5 [−6.6, +3.2], +1.7 [−0.3, +7.2]
  against base; −1.6, −4.1, −4.2 against var.** In the same sessions the
  base pad `baseprepad16` read +1.3, +1.3, +1.1, and `rv_all` −0.9, −0.8,
  +0.9.

What landed on `intel-bt-040`, on `release-0.40.0` `367c3707`:

- `cursor_advance_word` is `@[NoInline]` (`bitmap_alloc.cr`).
- The three FREEING fields live in `src/gcry/heap_cold.cr`, inferred and
  required last from `gcry.cr`, with typed accessors so regression 91's
  hook still auto-casts.
- `spec/heap_cold_fields_spec.cr` checks that the cold fields sit after the
  hit path's fields. It is green on the fix and red on the tip ("Expected
  736 to be GreaterThan 86723").

On the 87ccf4f4 base, the fix against v0.39.0 with the keep rule's pads, in
two Intel sessions (perf-ab 41328410784, 41328418845):

- Binarytrees +2.2% [−2.6, +6.2] and +1.6% [−4.6, +4.5]. Both IQRs span
  zero, so not flagged.
- In 41328418845 the fix's `var` (1.629 s) is inside base's 1.627–1.678 s.

## 7. Keep rule and verification: not finished

- The five-runner keep rule on the final source was not run. The dispatch
  on the pre-rebase commit (41328401326) was cancelled when the base moved.
  Next: `gh workflow run perf-ab.yml --ref intel-bt-040 -f base=v0.39.0
  -f reps=15 -f benches="Primes JsonParsePure Binarytrees JsonGenerate
  JsonParseSerializable JsonParsePull Revcomp RegexDna Knuckeotide"
  -f os='["ubuntu-latest","ubuntu-24.04-arm","macos-latest","macos-15-intel","windows-latest"]'
  -f pads="p16 p64 bp16 bp64"`, then
  `../../linux/2026-11-01-0.40-keep-rule/keep.py`.
- `verify.sh`, `make windows-typecheck`, `make darwin-typecheck` and
  `make alloc-entry-frame` have not run on the final tree. A run was
  started and killed when the tree was rebased under it. The darwin
  cross-typecheck of the revert trees passed.

## Open

- On the rebased base, the pace's `@pace_*` (`a62a47fd`) and
  `@inc_barrier_lost_collections` (`7d101c9a`) again move the hit path's
  fields, by +8 bytes (`@fast_path`, `@bytes_since_gc`) and +32 bytes
  (`@collecting`, `@incremental_marking`, `@lazy_sweep_pending`) against
  0.39.0 (`runs/offsets-fix.txt` is the pre-rebase layout). Moving only
  their declarations into `heap_cold.cr` does not move them, because a plain
  `@x = …` in `collect.cr`'s methods places them where that file is met
  (tried, reverted). Whether that shift costs Intel Binarytrees has not been
  measured; the keep rule's Intel row will show it.
- Why the 32-byte field shift costs ~1.5–2% (f4) is [INFERENCE]; the
  hit path's distinct cache lines are 9 in both layouts.
