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
out of line and declares the hit path's heap fields first
(`src/gcry/heap_hot.cr`), so no field added elsewhere moves them. On the
final source, Binarytrees reads +0.8% [−2.9, +2.6] against 0.39.0 and −6.0%
[−10.9, −3.4] against the tip; the five-runner keep rule passes.

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
| **f24** (the first fix, §6) | 3 | **+1.2** (+0.5, +1.7) | −3.3 |
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

## 6. Fix candidates and A/B

The candidates, each a patch on var (`AB_PATCHES`):

- f1: re-read `bytes_local` at its store instead of keeping `local` live.
  This removes one spill, but the frame stays 0x98: +2.5.
- f2: `cursor_advance_word` `@[NoInline]`. It runs once per word, up to 64
  hand-outs. `Heap#malloc` drops to 302 lines, a 0x28 frame and 5 stack
  stores: +2.5 over 6 sessions.
- f4: FREEING's fields declared inferred, last (`f24.patch` without f2).
  Every 0.39.0 field is back at its offset: +2.5.
- f13 (f1, plus `@block_bytes[index]` read before the sentinel): +5.4,
  worse.
- **f24 = f2 + f4: +1.3 [−2.4, +3.9], +0.5 [−6.6, +3.2], +1.7 [−0.3, +7.2]
  against base; −1.6, −4.1, −4.2 against var** (41325522076). In the same
  sessions `baseprepad16` read +1.3, +1.3, +1.1 and `rv_all` −0.9, −0.8,
  +0.9. On the 87ccf4f4 base with the keep rule's pads (41328410784,
  41328418845) f24 read +2.2% [−2.6, +6.2] and +1.6% [−4.6, +4.5].

f24's "cold fields last" works only for fields that no earlier file
assigns. On the rebased base the pace's `@pace_*` (`a62a47fd`) and
`@inc_barrier_lost_collections` (`7d101c9a`) still moved the hit path's
fields by 8 to 32 bytes. Moving their declarations into a last-required file
did not move them: a plain `@x = …` in `collect.cr`'s methods places them
where `collect.cr` is met.

## 7. What landed: hit path fields first, word advance out of line

`intel-bt-040`, on `release-0.40.0` `16a6804b`:

- `cursor_advance_word` is `@[NoInline]` (`bitmap_alloc.cr`).
- `src/gcry/heap_hot.cr`, required first by `heap.cr`, declares every heap
  field `Heap#fast_alloc` reads, typed:
  - the flags `@fast_path`, `@collecting`, `@incremental_marking`,
    `@lazy_sweep_pending` and (Darwin) `@cursor_tsd_slot`;
  - the counters `@bytes_since_gc`, `gc_threshold`, `alloc_pfw` and the
    five `fast_miss_*`;
  - the tables `@block_bytes`, `@fit_index`, `@fit_payload`.

  Crystal lays out typed declarations first, in program order, so these
  take the lowest offsets whatever is added elsewhere. This is now the only
  layout convention; f24's cold file was dropped.
- `spec/heap_hot_fields_spec.cr` asserts the behaviour, not numbers: every
  hot field's offset is below every other field's (`@type.instance_vars`).
  It is green on the fix and red on the tip ("Expected 86723 to be LessThan
  8").
- Regression 86's control arm (the slow path without the wipe) found 0
  stale words on x86-64 Linux with the fix, where it found 2: with the
  advance out of line, `Heap#malloc`'s frame no longer leaves unwritten
  slots below it. The control is now deterministic instead. A research knob,
  `Heap#slow_wipe_gap`, makes `allocate_wipe` tail-call
  `allocate_traced_below_gap`, which builds the slow path's frames below 32
  words nothing writes, inside the wipe's band. The spec plants its pattern
  there; the control must find it (> 0) on every target, the fixed arm none,
  and a third arm (wipe on, no gap) none. `--release`, regressions 79 and 86,
  5/5 in all four runs:

  | tree | layout | control | fixed | no gap |
  |---|---|---:|---:|---:|
  | fix | default | 27 | 0 | 0 |
  | fix | `-Dgcry_block_headers` | 26 | 0 | 0 |
  | tip `16a6804b` with the hook | default | 25 | 0 | 0 |
  | tip `16a6804b` with the hook | `-Dgcry_block_headers` | 25 | 0 | 0 |

Fast-path fields, byte offset in `Heap` (`runs/offsets-*.txt`, from
`offsets.cr`, x86-64). Darwin agrees: the fix's `Heap#malloc` reads
`@fast_path` at `0x4(%rdi)`, 0.39.0's at `0x1509c(%rdi)`.

| field | v0.39.0 | 0.40 tip (87ccf4f4) | fix |
|---|---:|---:|---:|
| `@fast_path` | 86124 | 86156 | 4 |
| `@collecting` | 86496 | 86528 | 5 |
| `@incremental_marking` | 86512 | 86544 | 6 |
| `@lazy_sweep_pending` | 86691 | 86723 | 7 |
| `@bytes_since_gc` | 85840 | 85872 | 8 |
| `@gc_threshold` | 14368 | 14400 | 16 |
| `@alloc_pfw` | 6616 | 6648 | 24 |
| `@fast_miss_refill` | 656 | 656 | 56 |
| `@block_bytes` | 8472 | 8504 | 72 |
| `@fit_index` | 12648 | 12680 | 392 |
| `@fit_payload` | 12908 | 12940 | 652 |

`Heap#malloc` on macos-15-intel (LLVM 15; probes 41320057272 and 41331431976;
`dis/`):

| tree | lines | frame | stack stores |
|---|---:|---:|---:|
| v0.39.0 | 499 | 0x88 | 18 |
| 0.40 tip | 504 | 0x98 | 19 |
| **fix** (`dis/heap-malloc-fix.s`) | **298** | **0x28** | **5** |

## 8. Keep rule on the final source (src `19cf3a60`, run at `6ac62ad9`)

Five runners, nine benches, 15 reps, Boehm, pads `p16 p64 bp16 bp64`,
against `v0.39.0`: perf-ab 41331393029 (`keep/`; `keep.py`'s output is
`keep/41331393029-keep.txt`).

**Placement by the rule:** every flagged row but one. They are Intel
JsonParsePull, Revcomp and RegexDna; arm64 JsonGenerate; and Windows
JsonParsePure, JsonParseSerializable, JsonParsePull, Revcomp and RegexDna.
0.40's own keep rule (41248448693) flagged and excused the same rows.

**The exception, Intel JsonGenerate,** read +7.1% [+2.0, +19.6]. That session
ran slow throughout (Intel Primes 2.7 s, against about 1 s elsewhere). Two
rechecks, 15 reps each, same pads:

- **Against v0.39.0** (41339843203): time +6.1% [+1.3, +8.8], wall +2.6%
  [−1.4, +4.8]. The var-code medians are 2.250, 2.113 and 2.023 s, the
  base-code ones 2.242, 2.092 and 2.151 s: placement by the rule.
- **Against the tip** `16a6804b` (41339851130): +1.6% [−0.5, +3.6], wall
  −0.6%. The fix leaves JsonGenerate where the tip has it. Intel
  JsonGenerate's timed section has read +2–4% against 0.39.0 since the high
  heap's code landed (`../2026-10-31-heap-high/` §5).

**Binarytrees:**

| run | against | Binarytrees |
|---|---|---|
| 41331400915 (Intel only, 21 reps) | v0.39.0 | **+0.8% [−2.9, +2.6]**, with `baseprepad16` +5.3% and `baseprepad64` −1.3% |
| 41339843203 | v0.39.0 | +0.4% [−5.0, +3.8] |
| 41339851130 | tip | **−6.0% [−10.9, −3.4]** |

**Local, all passing** (format, lint and both typechecks rerun after the regression 86 hook):

- `verify.sh`: format, lint, `spec/all_specs.cr` (307 examples; 330 with
  block headers; 307 with invariants), `process_spec` (366; 367 and 367 in
  the block-header arms);
- `make windows-typecheck` and `make darwin-typecheck`;
- `make alloc-entry-frame`, 5/5 with regression 86's planted control (both layouts, fix and tip);
- `process_spec` under Crystal 1.22.2: 366 examples, 0 failures.

## Open

- Why the 32-byte field shift cost ~1.5–2% (f4) is [INFERENCE]: the hit
  path touches 9 distinct cache lines in both layouts. With the hot fields
  at offsets 4–1680 the question no longer applies to the fix.
