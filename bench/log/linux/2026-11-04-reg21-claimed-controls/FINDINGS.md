# Regression 21's "controls kept 8 > 1" again: freed blocks a cursor's claim made read live (regression 106)

Branch `reg21c-040`, on `release-0.40.0` at `2b3626b9`. Reg1 saw regression
21 fail once on that tip (`../2026-11-04-reg1-drift/rates/tip-hdr-2-regression21.txt`):
`-Dgcry_block_headers`, Crystal 1.21.0, its local glob order (21 at position
16), the main fiber moved off the initial thread (21's `GC_stackbottom`
example pending), and **all eight** controls counted live after three
collections. Regression 103 (`21462240`,
`../2026-11-03-reg21-marked-unmarked/`), which clamps the pthread-stack scan
of a moved main fiber's mapping, is on that tip.

**It was not retention.** The eight controls were freed by the collections,
and `GC_base` answered them live afterwards: a bitmap cursor had claimed
their word.

## 1. The defect

The bitmap allocator claims a word's free blocks at once
(`Heap#cursor_claim_word`, "Occupancy is claimed a word at a time" in
`bitmap_alloc.cr`): it ORs all of them into `occ` and hands them out later
by popping them from its mask. The raw lookup, `find_object_with_chunk`,
reads `occ`, so it answers a claimed block as allocated. That is right for a
pointer a program holds — a claim never covers a block that was handed out
and not freed — and the mark and the sweep rely on it. It is wrong for a
pointer kept after the block was freed: `GC_base`, `GC_size`
(`Heap#usable_size`) and `GC_register_finalizer` used it, and each is
documented as answering for the *live* block only. `Heap#live?` and `free`
already used `block_allocated_exact?`, which subtracts the claim.

Regression 21 asks `GC_base(p) == p` and the 256-byte pattern of each
control (`live_and_intact?`). The eight controls are consecutive 256-byte
atomic blocks of one chunk (336-byte stride with the header), usually in
one 64-block word, with the eight `kept` blocks after them. When the three
collections free the controls, the next 257–320-byte atomic allocation, on
any thread, can take that chunk from the pool and claim the word: every
freed control is then occupied in `occ` again, its bytes untouched, and
`live_and_intact?` is true for each — eight, or seven when the claim hands
the first of them out at once and its owner writes it. No other mechanism
seen in regression 21's history keeps all eight: a stale word keeps one or
two (`../2026-11-03-reg21-marked-unmarked/`).

Exposure: every build with the bitmap allocator (the default in both
layouts since 0.24.0); `GCRY_BITMAP_ALLOC=0` (CI's third `process_spec`
step) makes no claims. Since the claim (`20cbb8f2`, 2026-10-16;
`../2026-10-17-occupancy-claim/`). The earlier sighting of "8 > 1", on
2026-11-01 (an instrumented `87ccf4f4` prefix run, headers;
`../2026-11-02-scrub-band/` § 3, which guessed "the controls' chunk left
unswept so `GC_base` still answered for it"), had this signature too, and
the main fiber moved as in Reg1's; CI21b's reproduction in CI's
`GCRY_BITMAP_ALLOC=0` step kept two, the stale-word signature regression
103 fixed. Both "8" sightings had the main fiber moved; why the move makes
a claiming allocation in the window likelier is not established
[INFERENCE: after the move more threads run code — the initial thread's
loop, a pool thread — and any of them can allocate there].

## 2. How it was found

Reproduction as CI21b's (`../2026-11-03-reg21-marked-unmarked/`): its
`mover.cr` (a 60 ms `Fiber.syscall` first, which the monitor hands away) in
front of the spec files in order, `loop.sh` one run at a time under the
shared lock. Two orders: this tree's local glob order cut after 21
(`local_move_main.cr`, 16 spec files, Reg1's construction) on 1.21.0
headers, and CI's runner order (`ci_move_main.cr`: the 99-file order of
probe `Reg100Remap`'s artifacts, where 21 is 96th, cut after 21, with
regression 104 — absent from that order — put first [INFERENCE: its runner
position is unknown]; 97 spec files) on 1.22.2 headers.

Unforced, the tip did not fail: 0 of 20 moved runs in the local order,
0 of 8 in CI's order with `GCRY_BITMAP_ALLOC=0` (which makes no claims;
CI21b's configuration), 0 of 13 more under the
diagnostic below (which counts before it allocates).

The diagnostic (`diag/d21.cr`, `diag/d21-spec.diff`) hooks every root
candidate that lands in a control block (`mark_root_candidate`, with its
scan range, the slot, the stack the slot lies in, and a raw unwind), every
header and bitmap mark write on one (`BlockHeader.set_mark`,
`cas_mark_gen`, `chunk_set_mark`, unwind), every claim of a word covering
one (`cursor_claim_word`, `cursor_premark_claim`, unwind), and each
control's occupancy, exact allocation, claim, mark and `GC_base` answer
right after the three collections. Its report allocates, and with it both
of its first runs failed — 7 and 6 controls live (`runs/ld121-1-d21.txt`,
`runs/ld121-2-d21.txt`):

- No root candidate reached any control in any of the three collections
  (`records=0`, of 110 865 candidates), and no mark write on one was
  recorded (the mark hooks fired 1 040 times on other blocks; [INFERENCE]
  a mark written by an inlined path would not pass them, which the reading
  below makes moot).
- Right after the collections, and again when the report began, every
  control read free: not in `occ`, not allocated, not marked, `GC_base`
  null (`after_collect=0b0 at_report=0b0`).
- Then one claim covered all eight: `mask=0xfffffffffffe01fe` (ordinals
  1–8 the controls, 9–16 the kept blocks, 17–63 free), made outside the
  collection by the report's own `String::Builder` (`malloc_atomic` →
  `alloc_old_small` → `bitmap_refill_pool` → `cursor_claim_word`). The
  claim handed ordinal 1 (control 0) to the builder at once; the other
  seven read live.

So the diagnostic's report was the claiming allocation there. In the spec
proper, nothing on the main fiber allocates between the last `collect` and
the count; what made the claim in Reg1's run is not identified — a
finalizer run by `@finalizers.run_pending` at the end of the third
collection, or an allocation on another thread, both reach it
[INFERENCE]. The mechanism needs neither the moved main fiber nor any
particular thread (§ 4, unmoved).

## 3. Fix

`Heap#find_live_object_with_chunk`: `find_object_with_chunk` less a block
the chunk's cursor has claimed and not handed out (`block_allocated_exact?`).
`CAbi.base` (`GC_base`, and `GC_register_disappearing_link`'s
`GC_base(link)`), `CAbi.register_finalizer` and `Heap#usable_size`
(`GC_size`, `Gcry.usable_size`) use it. The mark, the sweep, `free` and
`find_object` are unchanged.

Cost: on a cursor chunk, `cursor_claim` reads this thread's slot first and
otherwise walks the cursor sets (`slot_claim`, no lock); none of the three
is on an allocation or collection path. `Heap#usable_size` also serves the
crash report's `realloc` and `free`, which take 0 for "not gcry's": a
stale pointer into a claimed block now goes the way one into a freed,
unclaimed block already went. `Heap#live_lookup_exact = false`
restores the raw answer (regression 106's control arm; no environment
knob).

## 4. Proof

### Forced claim

`diag/forced-claim-spec.diff`: regression 21 with one
`LibGC.malloc_atomic(256)` (cleared) between `collect` and the count — what
a finalizer or another thread can do there. Local order, mover first,
headers, 1.21.0:

| tree | runs | regression 21 failed |
|---|---:|---|
| base `2b3626b9` | 10 | 10 (7 live each: "Expected 7 to be LessOrEqual 1") |
| base, no mover (main fiber not moved) | 3 | 3 (7 live each) |
| fix | 20 | 0 |

### Unforced, main fiber moved

The fix tree, the spec files unchanged, mover first:

| order, build | runs | moved | regression 21 failed | other failures |
|---|---:|---:|---:|---|
| local (16 spec files), headers, 1.21.0 | 40 | 40 | 0 | none |
| CI's (97 spec files), headers, 1.22.2 | 25 | 25 | 0 | none |

65 moved runs, 0 failures — plus the forced arm's 20. On its own that is
no evidence: the tip passed 41 unforced moved runs above, and the natural
rate is under this resolution (Reg1: 1 in 28; two sightings in all the
runs logged since 2026-11-01). The forced claim is the A/B.

`runs/*.txt`: one line per run (`loop.sh`'s summary): `lm121`, `cm122`,
`ld121b` the tip unforced; `ld121` the diagnostic's first two runs;
`fb121`, `fbnm121`, `ff121` the forced claim; `lf121`, `cf122` the fix.

## 5. Regression 106

`process_spec/regression/106_claimed_block_not_live_spec.cr`. In a child
process per arm: eight 256-byte atomic blocks made on a fiber that scrubs
its frames (addresses masked in libc memory), three collections, then
256-byte atomic allocations with collection disabled until a freed block
reads occupied and not live (`find_object` and `Heap#live?`): claimed.
Every claimed block must answer free through `GC_base` and `GC_size` in the
fixed arm and live in the control arm (`live_lookup_exact = false`). No
block freed, or no claim reaching one in 4 096 allocations (always so under
`GCRY_BITMAP_ALLOC=0`), prints `CLAIM106_SKIP_MARK`.

| build | fixed | control |
|---|---|---|
| headers, 1.21.0 | 8 freed, 7 claimed, 0 answered live | 8 freed, 7 claimed, 7 answered live |
| headers + `GCRY_BITMAP_ALLOC=0` | skipped (no claim) | skipped (no claim) |
| headerless | 8 freed, 7 claimed, 0 answered live | 8 freed, 7 claimed, 7 answered live |

The same in every `process_spec` run of the checks below, on 1.21.0 and
1.22.2. The claim hands one freed block out at once (the lowest), so seven
stay claimed — as in regression 21, where the eighth control is the one
the claiming allocation takes, unless a free block below them is taken
first and all eight read live, as in both natural sightings.

## 6. Keep rule and checks

Perf A/B, `base` = `v0.39.0`, var = `reg21c-040` at `2721f940` (the fix
and regression 106 on `2b3626b9`), nine benches, 15 reps, pads `p16 p64
bp16 bp64`, Boehm. One run per runner: 41519048415 (`ubuntu-latest`),
41519061728 (`ubuntu-24.04-arm`), 41519073505 (`windows-latest`),
41519085944 (`macos-latest`), 41519098230 (`macos-15-intel`). `keep.py`
over all five (`ab/keep.txt`, summaries in `ab/`): **12 rows flagged, all
12 excused as placement**, none unexcused. The largest: macos-15-intel
Revcomp +8.5% time (prepad16 1.964 inside base's 1.956..2.084),
ubuntu-latest JsonParsePull +4.1% (prepad64 0.706 inside base's
0.704..0.729), macos-15-intel JsonGenerate +3.9% (prepad64 1.838 inside
base's 1.828..1.899). None of the changed lookups runs in these benches
[INFERENCE: no stdlib path they take calls `GC_base`, `GC_size` or
`GC_register_finalizer`].

On the branch's tree:

- `verify.sh` (after `rm -rf lib/ameba bin/ameba`), Crystal 1.21.0: format,
  lint (257 inspected, 0 failures), `spec/all_specs` three ways (307, 330,
  307 examples, 0 failures), `process_spec` three ways (426, 427, 427
  examples, 0 failures, 2 pending).
- `process_spec` on Crystal 1.22.2, all three configurations: 426, 427, 427
  examples, 0 failures, 2 pending.
- `make windows-typecheck`, `make darwin-typecheck`: pass.
- `make alloc-entry-frame`: 5 examples, 0 failures.

## Files

- `diag/d21.cr`, `diag/d21-spec.diff`: the diagnostic and its changes to
  regression 21 (against `2b3626b9`); `diag/forced-claim-spec.diff`: the
  forced claim.
- `local_move_main.cr`, `ci_move_main.cr`, `build.sh`, `loop.sh`: the
  reproduction (`mover.cr` is `../2026-11-03-reg21-marked-unmarked/mover.cr`).
- `runs/`: per-run summaries; the diagnostic's two failing runs,
  symbolised.
