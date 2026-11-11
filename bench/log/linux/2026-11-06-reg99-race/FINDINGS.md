# Regression 99's *race* control, and a full collection that dropped the cycle outside the section (2026-11-07)

Branch `reg99-race-040`, on `release-0.40.0` (`b339f533`). Local x86-64
Linux, every heavy step under the shared lock, one per hold.

## 1. The flake

`2026-11-06-spec-harden/` § 1: the *race* control arm of regression 99
(`process_spec/regression/99_mprotect_protect_outside_cards_spec.cr`) failed
"the queued slice returned false" (`Expected: 2, got: 1`) in 1 of 100 and 3
of 74 suite-order runs on Crystal 1.22.2 headerless and 2 of 50 on headers
with `GCRY_BITMAP_ALLOC=0`; the fixed arm never failed. The three old-arm
failures were runs 26, 27 and 28 in a row, which reads as host load rather
than suite order [INFERENCE].

The arm: the main thread's window slice (`Int32::MAX` marks, cards refused)
loses the mprotect barrier in its termination scan. `Heap.inc_slice_locked_hook`
runs inside it, holding the collection section, releases a second thread
into `collect_a_little(4096)` and waits until `@post_stw_next` moves (its
ticket). The control (`inc_lost_cycle_ends_in_stop = false`) leaves the
cycle open; the losing slice releases the section and calls `collect`. The
arm asserts the ticket (`queued?`) and then the queued slice's result.

## 2. Cause: `collect` dropped the cycle before it queued

The flake reproduces on demand with the child pinned to one CPU (`taskset
-c 0`): 300 of 300 with the spec-harden prefix binary (57 files,
`2026-11-06-spec-harden/reg1/prefix-entry.cr`, built from `b339f533`),
and with the single-file binary (`quick-entry.cr`, 99 alone) 298 of 300
headerless on 1.22.2 and 299 of 300 on headers + `GCRY_BITMAP_ALLOC=0`
(`quick_loop.sh`; one failing child's output in
`old-hl122-1cpu-race-control.txt`, every failure that signature). Unpinned,
the prefix binary's child passed 2 000 of 2 000 and its parent example
1 000 of 1 000.

A probe (`probe.diff` over `b339f533`: a static event log from the hook's
slices and from `collect`'s `abort_incremental`) shows two orders
(`probe-runs.txt`, five runs each, identical within a mode). Per slice:
`-1 <thread> <@inc_active> <stack at lock> <before marking> <after
marking> <100 + lost|empty·2|none·4> [<200 + stack after the root
rescan>]`; `-21` is `collect`'s drop of an open cycle:

```
unpinned: … -1 1984 1 81 81 0 105  -21  -1 1728 0 0 0 0 106 200   → true
pinned:   … -1 1984 1 81 81 0 105  -1 1728 1 124 124 121 104  -21 → false
```

- The losing slice (thread 1984) drains its stack, and its termination
  scan reads the dirty pages — the holder's page among them, so the white
  20 000-block chain's head goes grey — before the card rebuild is refused
  and the backend goes `None`: `105` (lost, entries left, backend `None`).
  In the control the cycle stays open with those entries on the stack.
- Its `collect` then called `abort_incremental` **before** queueing for
  the section (`collect.cr`, ahead of `run_collection`): `@inc_active`
  false, the stack cleared.
- Unpinned, the losing thread runs straight on into that drop while the
  queued thread is still waking from its condition wait: the queued slice
  (thread 1728) holds the section with the cycle already gone (`0`, stack
  `0`), sees no lost barrier (backend `None`, `106`), rescans the roots,
  finds nothing (`200`) and sweeps: true. The control "passed", on a cycle
  the full collection had already dropped.
- Pinned (as under load), the woken thread runs first: the cycle is open
  with the losing slice's 124 entries, its 4 096 marks do not get through
  the chain (`121` left, `104`), it returns false, and only then does the
  drop run (`-21`).

So the ticket assertion was right every time — the second thread did
queue while the losing slice held the section — and the result still
depended on whether the losing thread's own `collect` reached its drop
before the queued thread ran.

## 3. The defect: regression 108

The early drop is unsafe on its own. A slice that has taken the section and
re-read `@inc_active` (the 2026-11-02 re-check) goes on to set
`@collecting` and stop the world; `collect` on another thread checks
`@collecting` only to skip a re-entrant call, so it dropped the cycle in
that window: the slice then ran with no grey entry and the backend `None`,
reported no lost barrier (`armed` false), rescanned roots that were all
marked, and swept every object only the cleared entries reached, though a
root held them. The full collection queued behind it marks from the roots
again and stops at the freed blocks. With the re-check off the same
happened to a slice queued ahead of the collection — the unpinned order in
§ 2. `minor_collect` dropped the cycle the same way. Boehm finishes the
cycle in progress under the allocation lock before a full collection
(`GC_try_to_collect_inner`), so no slice is in between.

**Fix** (`src/gcry/collect.cr`): `run_collection_body` drops the cycle
right after `acquire_post_stw` succeeds — inside the section, where no
slice can be inside its own — and `collect` / `minor_collect` no longer do
before queueing. A request answered by a peer's collection drops nothing
(the peer did, inside the section). Research knob
`Heap.collect_drops_cycle_in_section` (class property, so no `Heap` field
moves); false restores the drop before queueing.
`Heap.inc_slice_locked_hook` now runs after the re-check, in the window;
regression 99's losing slice reaches it the same way as before.

**Regression 108** (`process_spec/regression/108_collect_drops_cycle_in_section_spec.cr`),
each arm in its own process. A 20 000-block chain whose head is an explicit
root (`add_root`), pushed first at the begin stop so the drain reaches it
last; slices of 256 marks until one entry is left on the mark stack (the
chain's frontier, everything else black); then the hook releases a second
thread into `collect` and waits for its ticket. Fixed: the cycle is open
when the slice goes on and 20 000 of 20 000 blocks are alive. Control:
the cycle was dropped before the ticket and 141 of 20 000 are alive (the
marked prefix). A first version left every root's entry grey at the drop;
its control died in the second thread's teardown (`Thread::LinkedList`,
`pthread_mutex_unlock: Invalid argument`), the runtime's own objects
swept, so the construction narrows the loss to the chain.

## 4. Regression 99's *race* control

The control's queued slice now always holds the section before the drop
(the drop waits for the section), so it always meets the open cycle with
the losing slice's entries. Its budget is `Int32::MAX` (as the losing
slice's), so it drains them, finds the backend `None` and no lost barrier,
and sweeps — the old path the arm names. The hook also records, at the
queued slice, whether the cycle was open; the control asserts open and
true, the fixed arm asserts the slice returned at the re-check before the
hook and false. Nothing is loosened: both assertions the arm had stay, and
each arm gains one.

### Rates

Children (`quick_loop.sh`, single-file binary `quick-entry.cr`: 99 and
108), 300 per arm, every arm 0 failures:

| binary | pinned to CPU 0 | race fixed | race control | 108 fixed | 108 control |
|---|---|---:|---:|---:|---:|
| new, 1.22.2 headerless | yes | 0 / 300 | 0 / 300 | 0 / 300 | 0 / 300 |
| new, 1.22.2 headerless | no | 0 / 300 | 0 / 300 | 0 / 300 | 0 / 300 |
| new, headers + `GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0` | yes | 0 / 300 | 0 / 300 | 0 / 300 | 0 / 300 |
| new, headers + `GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0` | no | 0 / 300 | 0 / 300 | 0 / 300 | 0 / 300 |
| old (`b339f533`), 1.22.2 headerless | yes | 0 / 300 | **298 / 300** | — | — |
| old (`b339f533`), headers + `GCRY_BITMAP_ALLOC=0` | yes | 0 / 300 | **299 / 300** | — | — |

Suite order (`cut_run.sh`): the tree's `process_spec` glob order (the same
as `2026-11-06-spec-harden/`) cut after regression 99, 12 files
(`cut99-entry.cr`), the whole binary per run, new and old interleaved run
by run. `PIN=1` pins the binary and so its children to CPU 0 (the whole
cut suite passes pinned).

| config | pinned | new: runs, failures | old: runs, failures |
|---|---|---:|---:|
| Crystal 1.22.2 headerless | no | 300, **0** | 300, 0 |
| 1.21 headers + `GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0` | no | 300, **0** | 300, 0 |
| Crystal 1.22.2 headerless | yes | 200, **0** | 200, 200 |
| 1.21 headers + `GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0` | yes | 200, **0** | 200, 199 |

Every old failure is the *race* control (`:628`, `Expected: 2, got: 1`;
`old-hl122-pin1-suite.txt`); no other example failed in any of the 2 000
runs. Unpinned on this idle host the old tree did not flake in 600 runs
either, so the unpinned rows alone separate nothing; the pinned rows are
the comparison, and there the new control finished the cycle on the open
cycle's blind marks in all 400 runs (the arm asserts it).

## 5. Open, not examined

`collect_a_little` begins a cycle (`begin_incremental`) before it takes the
section: it sets `@collecting`, stops the world and clears it again without
holding it. A slice that read `@collecting` false just before a full
collection set it could stop the world during that collection's post-stop
passes (the large-cache releases, the dormant walks), which the section
exists to keep a stop out of, and clear its `@collecting` early
[INFERENCE: read from the code, no reproduction]. ROADMAP carries it.

## 6. Checks

`checks.txt` (`checks.sh` → `/home/naruto/playground/.scratch/verify.sh`,
after `rm -rf lib/ameba bin/ameba`): format, lint, `spec/all_specs.cr`
(headerless, headers, `GCRY_DEBUG_INVARIANTS=1`), `process_spec`
(headerless, headers, headers + `GCRY_BITMAP_ALLOC=0`), `make
windows-typecheck`, `make darwin-typecheck`, `make alloc-entry-frame`,
`process_spec` on Crystal 1.22.2 (447 examples, 0 failures, 2 pending):
every step exit 0, on `4ff77768` (over `b339f533`). Rebased onto
`cdecf905` (regression 109's `bitmap_alloc.cr` / `oom_reserve.cr` change;
nothing in `collect.cr`), `checks-rebased.txt`: every step exit 0 again
(`process_spec` 453 / 454 / 454, 1.22.2 453, 0 failures, 2 pending), and
the children rebuilt from it: 0 failures in 200 pinned and 200 unpinned
runs of each of the four arms on both layouts.

Keep rule (`collect` is on the default path): Perf A/B, `base` =
`v0.39.0`, var = `reg99-race-040` at `4ff77768`, nine benches, 15 reps,
pads `p16 p64 bp16 bp64`, Boehm. One run per runner: 42309740029
(`ubuntu-latest`), 42309743863 (`ubuntu-24.04-arm`), 42309747555
(`windows-latest`), 42309750974 (`macos-latest`), 42309754613
(`macos-15-intel`). `keep.py` over all five (`ab/keep.txt`): 45 rows, 33
`ok`, 12 `placement`, **none unexcused**.

## Files

- `probe.diff`, `probe-runs.txt`: the event-log probe and its runs (§ 2).
- `old-hl122-1cpu-race-control.txt`: a pinned old child's failure;
  `old-hl122-pin1-suite.txt`: a pinned old suite-order run's.
- `quick-entry.cr`, `quick_loop.sh`: the children's loop (§ 4).
- `cut99-entry.cr`, `cut_run.sh`, `rates-*.txt`: suite order (§ 4); the
  entries are built from the tree's root (copy them there).
- `checks.sh`, `checks.txt`, `checks-rebased.txt`, `ab/keep.txt` (§ 6).
