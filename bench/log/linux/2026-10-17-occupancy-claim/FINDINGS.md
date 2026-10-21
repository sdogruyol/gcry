# The occupancy OR off the hit path: claim a word, hand out with no shared write (2026-10-17)

`bench/log/macos/2026-10-16-binarytrees/` left Linux Binarytrees at 88%
(x86-64) and 77% (arm64) of Boehm and put the gap on one instruction: the
`lock or` (`ldxr/orr/stxr` on arm64) that set a block's `occ` bit on every
hit-path allocation. Its `noatomic` probe (a plain OR, unsound) took the two
to 103% and 92%. This cut asks which writers that atomic protects against,
finds a shape that drops it soundly, and ships it.

## Every writer of an `occ` word, and when it runs against the owning cursor

| writer | thread, lock | when, relative to the cursor that holds the chunk | before | after |
|---|---|---|---|---|
| hit path `fast_alloc` | owner, no lock | inside the sentinel window, any time | atomic OR per block | **none** (pop from the private mask) |
| locked path `bitmap_alloc_locked` | owner (or a fallback-set thread), class lock | inside the sentinel window | atomic OR per block | **none** |
| claim `cursor_claim_word` (`cursor_advance_word`, `bitmap_refill_pool`) | owner; no lock on the hit path, class lock on the refill | when the cursor takes a word (mask was zero) | — | atomic OR of the word's free mask, once per word |
| release `cursor_release_claim` (`retire_cursor_slot`) | collector in a stop (set not mid-allocation), or the owner (exhausted refill, after-world own-set retire) under the class lock | owner outside its window | — | atomic AND of what is left of the mask, `occ` and `mark` |
| `free` → `bitmap_free_block` | any thread, class lock (now the allocator's lock, `false`, for every bitmap chunk) | any time, concurrent with the owner's hit path | atomic AND | atomic AND, after `block_allocated_exact?` under the lock |
| sweep kernel `occ = mark` (in a stop) | collector, all mutators frozen (Monitor gated by `MonitorGate`) | owners frozen anywhere; pinned chunks swept too | plain store | plain store; pinned claims marked by the settle first |
| sweep kernel (after the stop, lazy) | collector, class lock | PINNED chunks skipped; other CURSOR chunks are locked-path cursors (hit path closed while `@collecting`) | plain store | plain store; claims made while a sweep can run are marked at claim time |
| incremental finishing slice sweep | collector, stop, no settle | after begin's settle; hit path closed while `@incremental_marking` | plain store | same; claims made while marking are marked |
| settle `bitmap_settle_cursor_sets` | collector, stop | owner frozen | pins only | pins, and ORs a pinned slot's claim into `mark` and `occ` (`cursor_premark_claim`) |
| dormant revive | owner, class + alloc lock | chunk just set CURSOR, no word claimed yet | zero | zero |
| `map_chunk` | owner | fresh mapping | zero | zero |
| thread death | none (set marked EXITING; retired, so released, at the next stop) | — | — | — |
| fork child | none (other sets EXITING, retired at the next stop) | — | — | — |

The atomic on the hit path existed for one row: a `free` on another thread
clearing a bit of the word the owner is OR-ing into (and a frozen owner's
later OR racing the in-stop sweep's store, which the pin covered).

## Shapes considered

- **(a) Claim the word, then hand out privately — shipped.** `occ` means
  "allocated or claimed"; the claim is the slot's `free_mask`. The owner
  never writes `occ` while it holds a word except the claim itself, which
  only sets bits that were clear, so no `free` (which only clears handed-out
  bits) is ever lost and no claim bit is ever lost.
- **(b) Hand out privately, publish the word's bits once at the end.** A
  block handed out and not yet published reads unallocated: a legitimate
  cross-thread `free` of it is refused as a double free (or silently ignored
  through `GC.free`), and every off-stop reader would have to consult the
  owner. Rejected: unsound for correct programs, where (a) only changes what
  incorrect programs see.
- **(c) LSE on aarch64.** Crystal 1.21 emits an LL/SC loop for
  `atomicrmw or` on both `aarch64-linux-gnu` and `aarch64-apple-darwin`
  (`ldxr/orr/stxr`, checked with `--emit asm`); `+lse` cannot be set from a
  shard, and a `.inst`-encoded `stset` behind a HWCAP test would recover at
  most the 7 of 16.5 points the probe measured, on one platform. (a) removes
  the RMW on every platform. Relaxed stores emit plain `str`, release
  stores `stlr`.
- **(d) Plain per-block OR with deferred cross-thread frees.** Needs an
  ownership handshake per word between a lock-free owner and the freer
  (arrival and departure), a pending-free bitmap folded at safe points, and
  the in-stop sweep taught not to store a word a frozen owner may be
  mid-RMW on. More moving parts than (a) for the same instruction count.

## Why (a) is sound (also in `bitmap_alloc.cr`, "Occupancy is claimed a word at a time")

1. **Claim order.** `cursor_claim_word` stores `word`, then `free_mask`
   (release), then — after a compiler fence — reads `@collecting ||
   @incremental_marking || @lazy_sweep_pending` and, if set, ORs the mask
   into `mark`, then ORs it into `occ` (release). The mask is zero whenever
   the word or chunk changes (advance and refill run only at mask zero;
   retire zeroes it after releasing), so at every point a stop can freeze
   the owner the slot's `(word, free_mask)` agree.
2. **Hand-out.** `in_flight = user`, compiler fence, then the pop (relaxed
   store). A stop between them finds the block in the mask (marked by the
   settle, so not traced and not swept); after the pop it is rooted by
   `in_flight` and occupied since the claim. The old window — a block handed
   out and not yet occupied — no longer exists: a block is occupied before
   its address exists anywhere.
3. **Release.** Only with the owner outside its window, so the stored mask
   is exactly the unhanded blocks; `occ` and `mark` are ANDed before the mask
   is zeroed.
4. **Free.** Under the class lock — the lock any change of the chunk's owner
   takes — `block_allocated_exact?` reads `occ`, then the owner's claim
   (`cursor_claim`: the chunk's one CURSOR slot, this thread's set first;
   `word`/`chunk` read around the mask with acquire loads and retried if
   they moved; within one hold the word only grows, so this terminates),
   then `occ` again. A legitimate free never targets a claimed bit (it was
   handed out, so popped before the pointer reached the freer). A double or
   stale free into a claimed block is refused like any double free; without
   this check (red arm r1) it is accepted, clears the bit under the cursor,
   and the block is later handed out twice. A stale free racing the
   *hand-out* of the same block is undetectable, as it was with the
   per-block OR.
5. **Sweep.** In a stop the settle (after `clear_all_marks`, before the
   roots) releases every retired set's claims and marks every pinned set's
   (red arm r2: the in-stop sweep reclaims the claim and the stress harness
   sees blocks handed out twice and SIGSEGVs). After the stop the sweep skips
   PINNED chunks and holds the class lock, under which every other claim
   since the restart was made, marked (red arm r3: legitimate frees refused,
   stamps broken, drift). The sweep's `live` subtracts the claim
   (`chunk_claimed_count`), so live bytes and the empty-chunk decision see
   objects only; `freed` never contained it.
6. **Readers.** `chunk_free_mask` never offers a claimed block. The mark
   reads raw `occ`; a claimed block is released before it runs or marked by
   the settle (incremental: marked at claim), so never traced.
   `block_allocated_exact?` backs `free`, `live?`, `block_allocated_public?`,
   `diag_allocated?`/`diag_flags` (heap dump, mark audit, invariant,
   poison holders); `chunk_occupied_count` and the release-time
   `guard_occupied` subtract the claim, so the invariant walks,
   `counter-loss`, `/gc-stats` and the refused-release counters count
   allocated blocks only.

Cost of the claim: blocks of a word stay claimed until handed out or until
the next stop; at most 63 blocks per (thread, class, kind) slot.
Allocate-black now covers a whole word claimed while a cycle runs (its
blocks stay black until the next major's mark clear); the per-block
allocate-black on both paths is kept.

## Tests

- `spec/occupancy_claim_spec.cr` (library heap, 5 examples): the claim is in
  `occ` and out of every count; a free of a claimed block is refused on this
  thread and another and the block is handed out once; a cross-thread free
  of a handed-out block is taken while the claim is held; a stop's retire
  releases the claim (`cursor_claims_released`, `live_objects`, walk drift
  0); a claim made in the after-world window (`post_stw_hook`) survives the
  lazy sweep and counts nothing freed.
- `process_spec/regression/74_occupancy_claim_pinned_spec.cr`: a set frozen
  mid-allocation (sentinel) across `GC.collect` with the sweep in the stop
  keeps its claim occupied and hands each block out once. Skipped on the
  header allocator (`GCRY_BITMAP_ALLOC=0`).
- `spec/fast_alloc_allocate_black_spec.cr` adjusted: its white control block
  now comes from a word claimed with no cycle running.
- `bench/claim_stress.cr`, `make claim-stress`: four Parallel workers
  allocate 15 sizes (atomic and not), stamp every block in its first two and
  last words, free a third locally, pass a third to another worker to free,
  drop a third; the main fiber collects every 0.2–2.2 ms. Fails on any
  broken stamp, on a legitimate free refused (`double_frees`), and on
  walk-against-counter drift. Typical 5 s run: 2.3 M allocations, 0.8 M
  cross-thread frees, ~1 580 collections, ~3 500 sets pinned mid-allocation,
  3.2 M claimed blocks released.

### Red arms (`red/`: each patch on this branch, its log)

| arm | change | caught by |
|---|---|---|
| r1 | free's in-lock check reads raw `occ` | spec: "Expected ArgumentError but nothing was raised" |
| r2 | settle does not mark pinned claims | process_spec 74 (`occ & claim` = 0); `claim_stress` in-stop arm: 3 of 3 runs, two SIGSEGV, one with stamps overwritten by another owner's data |
| r3 | claim never marked while a sweep can run | spec (claim swept); `claim_stress` lazy arm 3 of 3: broken stamps, 3 227–41 190 legitimate frees refused, drift |
| r4 | retire does not release | spec (`live_objects` 0 for 2); `claim_stress` lazy 3 of 3, drift |
| r5 | the `noatomic` probe on the base tree (plain per-block OR) | `claim_stress` lazy 3 of 3, live drift +694 to +1 214 (cross-thread frees lost) |

## Performance

Local (QEMU x86-64, 12 vCPU), `bt.cr` from the macOS cut, n = 18, release,
6 interleaved reps: base 602–637 ms, var 521–540 ms (−13.5%; build phase
−15%, walk unchanged). `objdump` of `Heap#malloc`: base has the per-block
`lock or` on the hit path; var's remaining `lock or`s are the inlined claim
(per word) and allocate-black.

`Perf A/B` run
[38949411941](https://github.com/sdogruyol/gcry/actions/runs/38949411941)
(var `a68e8b00`, same `src/` as the final commit; base `e8c0327e`; nine
crystal-metric rows, 15 interleaved reps, Boehm, Kemal 15 trials;
`perf-<runner>/summary.md`). `macos-15-intel` had not started when this was
written. % of Boehm base → var, and var against base, median [IQR] of paired
reps:

| runner | Binarytrees | wall | other rows, wall | peak, beyond spread |
|---|---:|---:|---|---|
| ubuntu-24.04-arm | 83% → **99%** | −16.1% [−17.3, −14.1] | all −4.1% to −0.2% | **Knuckeotide +36.9%** (1.36× → 1.92×), JsonParseSerializable +8.5% (0.84× → 0.91×), JsonParsePull +8.2% (0.85× → 0.92×) |
| ubuntu-latest | 86% → **93%** | −7.1% [−9.3, −5.3] | −1.7% to +1.5%, none beyond its IQR | **Knuckeotide +21.2%** (1.49× → 1.94×), JsonParseSerializable +8.6% (0.73× → 0.84×), JsonParsePull +8.3% (0.79× → 0.85×) |
| macos-latest (M1) | 90% → 90% | −0.5% [−5.8, +5.3] | within spread | **JsonGenerate +20.6%** (0.64× → 0.88×) |
| windows-latest | 112% → 115% | −2.7% [−4.0, +0.1] | within spread | none |

**The speed criterion holds and the RSS one does not.** Knuckeotide is
over the 1.1× budget on base already and 21–37% further over with the
claim; its collections fall 28% (55 → 38 on x86) and Σ mark 38%, and the
heap ends with 13.6 MB of large chunks mapped against 3.3 MB on base
(`large_reserved_bytes` 4 MiB against 0): a large buffer outlives the
point where base frees it, which raises the live size the threshold is
computed from. Attribution run
[38954860052](https://github.com/sdogruyol/gcry/actions/runs/38954860052)
(`perf2-<runner>/`, both Linux runners, `stats=3`, `var_env`
`GCRY_THRESHOLD_PACE=100`): pacing off leaves Knuckeotide at 1.84–1.88×
(not the pace), and takes the two JSON rows back to base's peaks (0.73×,
0.78× x86), so their +8% is the pace answering a schedule that changed.
Root cause of the retained large buffer: not found. The change is not
shipped as a default until it is (the RSS budget rule).

Kemal `/json` (15 trials, `perf-<runner>/kemal-summary.md`), % of Boehm
base → var at the same peak: ubuntu-latest 101.9% → 106.7% (1.39×),
ubuntu-24.04-arm 105.5% → 107.1% (1.49×), macos-latest 109.7% → 103.7%
(IQRs [102.1, 116.3] and [98.7, 109.0] overlap; 1.67× → 1.69×).

### Stress loops (local, release builds, one heavy-lock hold per run)

- `stw_mt_property_test --iterations=200 --workers=2,4`, seeds 1001–1200,
  600 s bound (`bench/run_bounded.sh`): 198 passed, 0 failed, 0 stalls;
  runs 48 and 115 stalled and were classified as the Crystal
  Parallel-scheduler resume deadlock (exit 3; two or more threads in
  `parallel/scheduler.cr:97`, no collector frame).
- `make soak-smoke` 3 of 3, `make soft-soak-ec4-smoke` 3 of 3.
- `claim_stress` lazy arm (5 s, 4 workers, seeds 2001–2100): 36 of 36
  passed when this was written; the in-stop arm and 50
  `mt_property_test` runs were queued behind it.

## A pre-existing bug the harness found: chunks fall off `@chunks`

With the sweep in the stop and more than one mutator
(`GCRY_DISABLE_LAZY_SWEEP=1`; in-stop sweeps also follow from
`GCRY_PAGE_DONTNEED=1`, TLAB, or parallel munmap), chunks end up in
`@chunk_index` and not on `@chunks`: never swept again, their blocks counted
live and their capacity free forever. On the base tree `e8c0327e`, 2 s runs
of `claim_stress --workers=2`: 5 of 10 seeds with 35–50 chunks unlisted and
drift −618 to −6 884 objects, −4.1 to −5.8 MB free bytes (this branch 3 of
10, same signature); every run with no unlisted chunk had zero drift on both
trees. The default (lazy) sweep showed none. `claim_stress` reports drift
with unlisted chunks without judging it; the stamps still decide. Not
investigated further here.

## CI and branches

Probe branch `occupancy-claim`. CI with a 30-minute soak:
[38951465299](https://github.com/sdogruyol/gcry/actions/runs/38951465299)
on `374696ff`; 38949451199 on `a68e8b00` was cancelled as superseded after
its two process-spec jobs failed on spec 74 under the header allocator
(fixed: the spec skips without the bitmap allocator).

### Knuckeotide's peak: not claimed blocks being scanned

Hypothesis tested: claimed blocks not yet handed out still hold their
previous occupant's bytes, and if a mark reached one and scanned it, those
stale words would act as roots. Measured on the local x86-64 guest with
crystal-metric's Knuckeotide, `km/{base,var}` under the OccupancyPlainOr
scratch directory:

- **No mark reaches a claimed block.** A temporary counter in both
  `mark_impl` and the batched candidate filter (`collect_mark.cr`) counted
  every block found occupied that was in a cursor's claim: 0 hits, 0 bytes,
  over 40 collections. That matches the structure. The settle runs after the
  mark clear and before any root is marked. It releases every retired set's
  claims, and the claims it keeps it marks without pushing them, so the trace
  skips them. Claims made while a cycle runs are marked when they are made.
  So during a mark no block is both claimed and unmarked.
- **What differs is the schedule, from collection 9 on.** `GCRY_TRACE`:
  collections 1–8 are identical (same thresholds, live sizes and heap sizes).
  At collection 9, base's threshold falls to the 8 MiB floor while var's
  stays at 13.2 MiB, because var still has a 6.1 MB large block live. The
  peak and the 28% fewer collections follow from that one threshold.
- **That block is held only by words on the main fiber's stack**
  (`PoisonHolders.search` from `post_stw_hook` at collection 12: four stack
  slots, no heap holder), and it is dead by the end of the run. After two
  explicit collections at exit, both builds hold 3.2 MB of large blocks, with
  the same live holder. This is conservative stack retention of a dead
  setup-phase buffer: a stale word in a frame whose layout differs between
  the two builds. The claim's semantics are not involved [INFERENCE: frame
  layout of the inlined allocation path; not proven which frame].

So a fix would not be in the claim protocol: mark-without-scan already
holds. What would help is a stack-retention fix, or a placement experiment
(`pads`) to confirm the frame-layout attribution. The change stays unshipped
until the RSS budget holds on every row.

## Rebased onto `01b184a6` (atomic live bytes count a quarter): still not shipped

The branch was rebased onto `origin/release-0.37.0` at `01b184a6`, which
includes `fa51f65f` (atomic live bytes count a quarter in the threshold) and
`272d73e5`. `272d73e5` fixes the in-stop chunk-list loss that `claim_stress`
found above, so the harness now fails on any drift and on any unlisted chunk.

`Perf A/B`
[38966029947](https://github.com/sdogruyol/gcry/actions/runs/38966029947)
(var `4464f56e`, base `01b184a6`, nine rows, 15 reps, Boehm, Kemal 15 trials,
`stats=3`; `rebased-<runner>/`). Three runners were finished when this was
written; `macos-latest` and `macos-15-intel` were still running. Var
against base, median [IQR]:

| runner | Binarytrees, % of Boehm | wall | slower beyond spread | peak worse beyond spread |
|---|---:|---:|---|---|
| ubuntu-24.04-arm | 84% → 97% | −14.3% | none | **Knuckeotide 1.09× → 1.43×** (+18%, crosses 1.1×); JsonParseSerializable, JsonParsePull +8% (0.92×) |
| ubuntu-latest | 95% → 99% | −3.3% | **JsonParsePure +3.0% [+2.7, +4.0], JsonParseSerializable +4.4% [+3.4, +4.8], JsonParsePull +4.5% [+4.0, +4.9], Knuckeotide +2.0% [+1.5, +2.6], JsonGenerate +1.2% [+0.6, +2.2]** | Knuckeotide 1.30× → 1.47× (+20%); JsonParseSerializable +7.6%, JsonParsePull +7.8% |
| windows-latest | 94% → 110% | −16.8% | JsonParsePull +3.2% [+0.9, +6.4] | none |

Kemal `/json`, % of Boehm: ubuntu-latest 105.3% → 100.0% (IQRs
[100.2, 108.9] and [98.8, 105.1] overlap), arm 102.2% → 105.6%; peaks
unchanged.

The keep rule fails twice:
- **Speed:** rows on ubuntu-latest and windows-latest are slower beyond
  their spread. On `e8c0327e` (run 38949411941) the same x86 rows were
  within it. Whether this is runner variance or a schedule effect of the
  atomic quarter has not been separated [INFERENCE: a repeat run would say].
- **RSS:** Knuckeotide's peak still rises about 18–20% on both Linux runners
  with the atomic quarter in. On arm64 that takes the row from inside the
  1.1× budget (1.09×) to over it, which the rule does not allow, and it has
  not been shown to be the stack-pinning effect.

Branch `occupancy-plain-or` carries the change for review; nothing is in
CHANGELOG.

Stress on the rebased release build (`bench/run_bounded.sh`, one heavy-lock
hold per run):
- `stw_mt_property_test`, seeds 5001–5200: 198 passed, 0 failed, 2 stalls
  classified as the Crystal Parallel-scheduler deadlock (exit 3).
- `claim_stress` lazy arm, 100 of 100 passed.
- `claim_stress` in-stop arm, 50 of 50 passed.
- `mt_property_test --workers=2,4,8`, 50 of 50 passed.
- All local gates exit 0: both spec suites, both `process_spec` arms,
  `make lint`, `make windows-typecheck`, darwin cross-compile, and the eight
  stress make targets.

CI [38966033174](https://github.com/sdogruyol/gcry/actions/runs/38966033174)
on `4464f56e`: `specs (x86_64, crystal 1.22.0)` failed in `make
bitmap-marks-freelist`. `pattern_fuzz` hit SIGSEGV at 0x20 in its own
`compute_phase_stats`, built with `-Dgcry_block_headers` and run with
`GCRY_BITMAP_ALLOC=0`, i.e. the header allocator. That arm runs none of the
claim code: the settle returns early, there is no CURSOR chunk, and
`block_allocated_exact?` falls through to `block_allocated?`. It did not
reproduce in 20 runs each of var and `01b184a6` built with Crystal 1.22.0
locally, nor in 10 runs of var on 1.21. Treated as unattributed.

## Ported to 0.38 (2026-10-19): still not shipped

Branch `occupancy-claim-038` carries the change on `release-0.38.0`. On that
base it is still sound: claim_stress 100 + 50 runs, 196 of 200 `stw-mt` with
4 scheduler deadlocks, 50 `mt_property_test` runs, and all five red arms
caught. It was measured on all five runners
(`bench/log/linux/2026-10-19-occupancy-claim-038/`).

Knuckeotide's peak is now shown to be stack pinning: one word at
`Benchmark::run`'s rsp+0x40, whose frame is 32 bytes larger on var, holds
the dead 6.1 MB Fasta string. The x86 Linux JSON and Revcomp wall cost
survives a pinned schedule, and placement probes of the same source cover
it.

Two things still fail the rule. The JSON rows' +8% Linux peak is the pace
answering a different timing input; with pacing off it is +0.8–0.9%. That
remainder is a 25 MB unmap/remap churn, not attributed.
