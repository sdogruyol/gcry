# A bitmap `free`'s `mark` clear wipes a lock-free claim's mark (regression 91)

Branch `claim-mark-040`, off `release-0.40.0` at `bf607374`. The ROADMAP
item "A bitmap `free`'s `mark` clear can wipe a concurrent claim's mark"
(`../2026-10-22-frozen-class-gaps/FINDINGS.md`, "Found in passing") was a
reading. It is real, but only through the incremental cycle, and it is
worse than the reading said: the mark wiped can be the mark of a block
already handed out, so the block is freed under the program.

## The two clears and who can land between them

`Heap#bitmap_free_block` (`src/gcry/bitmap_alloc.cr`) clears the block's
`occ` bit, then its `mark` bit, two atomics, under the class lock
(`Heap#free_result` takes `with_freelist_lock(class_index, false)`). Between
them the block is free in `occ` and its mark clear is still to come. Who can
write the block's bits in that gap:

- **A locked claim** (`bitmap_refill_pool` → `cursor_claim_word`) holds the
  same class lock. Never between the clears.
- **The chunk's cursor owner on the hit path** (`fast_alloc` →
  `cursor_advance_word` → `cursor_claim_word`) holds no lock. It finds the
  block in `~occ`, claims the word (mark OR when a flag says a sweep can run
  before the next stop, then occ OR), and pops the lowest bit as the
  allocation, marking it allocate-black when a flag is set. Free to run in
  the gap.
- **A stop** (signals; the free's thread is frozen anywhere, including
  between the clears, holding the class lock). The settle premarks a pinned
  set's claim (`cursor_premark_claim`), the root phase marks `in_flight`,
  the trace marks what the stacks and the heap reach. If the owner claimed
  the block before the stop, all three can mark it, and the frozen free's
  mark clear runs after the restart.

So the mark the free's clear removes can belong to a claim, to a block
handed out of that claim, or to a stop that saw either.

## Which sweeps consume such a mark

A wiped mark matters only to a sweep that runs on marks set before the
wipe, with no settle and no `clear_all_marks` in between.

- **Stop-the-world major, in-stop sweep** (`run_collection_body`,
  `GCRY_DISABLE_LAZY_SWEEP=1` or a frozen class): marks are cleared, the
  settle runs and the trace marks, all inside the stop; a frozen free's
  clear lands after the sweep. Its mark is stale, zeroed by the next stop
  (`clear_all_marks`, and the settle's zeroing of pinned chunks). No harm.
- **Stop-the-world major, after-world (lazy) sweep**: `@lazy_sweep_pending`
  and `@collecting` stay true until it ends (`collect.cr`, the `ensure`
  then the post-stop block), and the hit path refuses while either is set
  (`fast_alloc`). A claim after the restart is either a locked one (the
  class lock; the sweep takes the same lock per class) or the hit path of a
  set the stop pinned mid-allocation, on a PINNED chunk the after-world
  sweep skips (`sweep_small_bitmap`, `!@world_stopped && pinned?`), whose
  marks the next stop zeroes. A frozen free whose block was claimed before
  the stop wipes a mark on a pinned chunk (skipped) or on a released claim
  (both bits already clear). **Not reachable** — the reading's "lazy sweep
  pending" case is closed by the hit path's flag check and the pin.
- **The incremental finishing slice** (`collect_a_little`): a stop that
  runs `sweep(major: true)` on the marks of the whole cycle, with no settle
  and no clear — the cycle's marks were cleared at `begin_incremental`. It
  sweeps pinned chunks too (the world is stopped). **Reachable.** The
  owner's set is pinned at `begin_incremental` if it was mid-allocation, or
  its claim was made before that stop; either way the begin stop or the
  claim itself marks the block, and the free's clear afterwards removes the
  mark the finishing slice needs.

## What breaks

The finishing slice's `occ = mark` takes the block out of `occ`. If the
owner still holds it in its claim, it hands it out later with `occ` clear;
if it already handed it out, the program holds it with `occ` clear. Either
way the next claim of that word hands it out again, `free` of it is refused
as not allocated, and the trace marks nothing behind it (it marks no block
whose `occ` bit is clear), so what it references can be freed too.

## Reproduction (regression 91)

`process_spec/regression/91_free_mark_clear_claim_spec.cr`, each arm a
child process, Linux (mprotect barrier for the sliced cycle; skip marker
elsewhere and without the bitmap allocator or the hit path):

1. Thread A fills a chunk of the 24 KiB class (nothing else allocates it)
   until its cursor stands on it with nothing left to claim, holding every
   block but the last.
2. Thread F frees A's last block; `bitmap_free_split_hook` parks it between
   the two clears, under the class lock.
3. A allocates once more.
4. `collect_a_little(1)`: the begin stop and one unit of marking.
5. F finishes; the cycle finishes; the class allocates 64 more blocks.

Control arm (`bitmap_free_claim_guard = false`, the code before): A's
allocation takes the hit path (`cursor_word_advances` moves) and returns
the block F is freeing; after the begin stop it is `occ=1 mark=1`; after
the cycle it is free in `occ` while A holds it, and one of the next 64
allocations is that same block — **handed out twice, 30 of 30 runs**.
Fixed arm: A's hit path finds FREEING, counts `cursor_free_deferrals`, and
takes the locked path, which waits on the class lock until F is done; A's
block is occupied after the cycle and none of the next 64 is it, **30 of
30 runs**.

## Fix

`ChunkHeader::Flags::FREEING` (`src/gcry/block.cr`). `bitmap_free_block`
sets it before the `occ` clear and clears it after the `mark` clear, under
the class lock it already holds; `cursor_advance_word` claims no word of a
chunk that carries it and returns 0, so the allocation takes the locked
path and claims after the free. Orderings: the `occ` clear is a release
(carries the FREEING set), the hit path's acquire fence after its `occ`
loads and its acquire load of the flags pair with it, and the FREEING
clear is a release after the `mark` clear. Across a stop the flag stays
set with the free frozen, so no claim of the block can precede the free's
mark clear even then. The locked claim needs nothing: it holds the lock.

Rejected:

- **Reversing the clears** (`mark` then `occ`). A free frozen between them
  leaves the block occupied and unmarked; the stop's sweep frees it and
  counts it, and the free counts it again; a trace that marks it from the
  freeing thread's stack keeps it marked, and the free's later `occ` clear
  leaves `occ=0, mark=1` for the after-world sweep to resurrect.
- **Taking the class lock in the hit path's claim when a flag is set.**
  Closes the concurrent case, not the one where the claim was made with no
  flag set before a stop and the free was frozen across that stop.
- **The free restoring the mark when it finds the bit re-occupied.** The
  claim ORs `mark` before `occ`, so the free can read `occ` clear after
  wiping the claim's mark; and a restore after a stop that released the
  claim leaves a stray mark the next `occ = mark` resurrects.

Cost on the default path: one acquire fence (a compiler barrier on x86-64,
`dmb ishld` on arm64) and one load of the chunk header's flags per word
advance of the hit path, not per allocation; two RMWs on the chunk header
per bitmap `GC.free`.

## Keep rule

`perf-ab.yml` from this branch (`43fe0980`) against `bf607374`, 15 reps.

**Run 41203821072**, all five runners, nine benches, Boehm on. Time
(timed section, var against base, median [IQR]) slower beyond its spread:
`ubuntu-latest` JsonParsePull +0.7% [+0.2, +1.4]; `ubuntu-24.04-arm`
JsonGenerate +1.5% [+1.4, +1.9], Knuckeotide +1.0% [+0.3, +2.0];
`windows-latest` Binarytrees +3.3% [+2.1, +3.6], Revcomp +5.6% [+4.8,
+6.9]; `macos-15-intel` Primes +7.7% [+1.8, +12.6] (with collections
+11% and Σ mark +104%: one collection more, not the mutator).
`macos-latest`: none. Peak rows above their spread: `macos-latest`
JsonGenerate +15.8% [+8.8, +18.4] (0.88× of Boehm's; the bimodal
JsonGenerate peak regression 92 addresses on macOS, which this branch's
base predates), `macos-15-intel` JsonParsePull +5.6% [+2.1, +9.7] and
JsonParseSerializable +3.3% [+0.5, +6.1], `ubuntu-latest`
JsonParseSerializable +2.2% [+1.8, +2.8] (collections +6.7%) — all
0.73–0.88× of Boehm's. Every peak ≤ 1.1× Boehm's except Knuckeotide, as
on base.

**Run 41210728957**, same session shape, the four runners with a flagged
row, six benches, pads `p16 p64 bp16 bp64` (var and base each moved by
16 and 64 bytes of code). Each flagged row is inside the band code
placement alone makes on the same runner:

| runner | bench | var vs base | var padded (p16, p64) vs var | base padded (bp16, bp64) vs var |
|---|---|---:|---:|---:|
| windows-latest | Binarytrees | +3.0% [+2.0, +3.3] | −2.7%, −3.1% | −2.7%, −2.5% |
| windows-latest | Revcomp | +5.9% [+5.1, +6.2] | −5.4%, +3.6% | −5.2%, +3.5% |
| ubuntu-24.04-arm | JsonGenerate | +1.5% [+1.0, +2.4] | +0.3%, −0.5% | −1.5%, +0.3% |
| ubuntu-24.04-arm | Knuckeotide | +0.7% [+0.4, +1.2] | −1.0%, −1.1% | −1.1%, −1.3% |
| ubuntu-latest | JsonParsePull | +0.9% [+0.2, +2.5] | −3.9%, +1.1% | −3.7%, +1.2% |
| macos-15-intel | Primes | +3.8% [−4.5, +9.9] | — | — |

Windows Binarytrees padded by 16 or 64 bytes runs at base's time; Revcomp
moves ±5% with 16 vs 64 bytes of padding on either binary; the arm rows
move by as much with padding of either. [INFERENCE] The flagged rows are
code placement: the change adds a fence (a compiler barrier on x86-64), one
flags load and a cold branch at the word advance, and the hit path's
per-allocation code is unchanged.

## claim_stress

`bench/claim_stress.cr` built `--release` at `364e4018`, 200 bounded runs
per arm (`bench/run_bounded.sh 90`, 5 s, 4 workers, seeds 1–200), on a
push-triggered probe (run **41221456395**, branch deleted after):

| runner | lazy sweep | in-stop sweep (`GCRY_DISABLE_LAZY_SWEEP=1`) |
|---|---:|---:|
| ubuntu-latest | 200 pass, 0 fail, 0 stall | 200 pass, 0 fail, 0 stall |
| ubuntu-24.04-arm | 200 pass, 0 fail, 0 stall | 200 pass, 0 fail, 0 stall |

arm64 is the runner where the new orderings are instructions rather than
compiler barriers. Locally the lazy arm ran its first 50 seeds clean
before the shared lock's queue made 400 runs a two-day job and it was
stopped for the probe. claim_stress runs no incremental cycle, so it
guards the changed hit and free paths, not the window regression 91 forces.
