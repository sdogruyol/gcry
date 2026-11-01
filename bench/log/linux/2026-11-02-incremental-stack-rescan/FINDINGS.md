# The incremental finish misses a pointer moved out of a heap field (regression 100)

Branch `inc-stack-040`, on `nursery-mprotect-040` (the mprotect card fixes
and the lost-barrier full collection, regression 99), itself off
`release-0.40.0`. The ROADMAP item "The incremental cycle never scans a
stack after its first stop" (`../2026-11-02-nursery-mprotect/FINDINGS.md`)
was a reading. It is real, on both barrier backends and in every release,
and probing the same termination found a second hole of the same shape on
the mprotect backend.

## The termination, as it was

`collect_a_little` (`src/gcry/collect.cr`) begins a cycle with
`begin_incremental`: one stop clears the marks, marks the roots — the
before-collect callbacks (Boehm's `GC_add_roots` ranges and
push-other-roots), `@roots`, the in-flight allocations, the finalizer
metadata, every fiber and thread stack with its registers, static data —
and arms the page barrier. Every later slice is a stop of its own that
marks the in-flight allocations, runs `work_units` of marking, and, when the
mark stack is empty, rescans the dirty pages (`scan_dirty_pages_for_pointers`)
and marks again. If the stack is still empty it sweeps.

Allocation while the cycle is open is black (`heap_set_mark_allocating if
@incremental_marking`), and black objects are never scanned.

The barrier is an insertion (card) barrier: it records that a heap page was
written and the termination rescans the page. It sees the store that clears
a field; it knows nothing of where the old value went. A deletion (SATB)
barrier would have greyed the old value at the clear; this one relies on
the termination seeing every place the value can be. Two such places it did
not see:

1. **A root.** No stop after `begin_incremental` scanned a stack, a register
   or static data. A mutator that loads a pointer to a white object into a
   local (or a static, or does so on another thread) and then clears or
   overwrites the field leaves the object held by a root alone.
2. **A black object in a page the barrier does not watch.** With the
   mprotect backend the arm protects the chunks that exist then
   (`arm_mprotect_on_old_chunks`, nursery and dormant chunks skipped). A
   chunk mapped after it — a large allocation's own mapping, a size class's
   next chunk — or revived from dormant stays writable with no protected
   bit, so a store into a black object there sets no dirty bit, and the
   termination reads only dirty pages. (Soft-dirty sees new mappings: the
   kernel reports their pages dirty.)

Boehm's incremental mode ends in `GC_stopped_mark` (`alloc.c`), which calls
`GC_initiate_gc` and then `GC_mark_some` with the world stopped; in the
`MS_PUSH_RESCUERS` state that pushes the marked objects on dirty pages and
then `push_roots_and_advance` (`mark.c`), every root again.

## Reproduction

Deterministic, API-driven (`collect_a_little`, as regressions 85, 91 and 95;
`GCRY_INCREMENTAL=1` drives the same function from the allocation path). An
object X, 64 bytes of a pattern, held only by a field of a holder at the end
of a 4 000-node chain from a static root. `collect_a_little(1)`: the begin
stop and one unit of marking; X is unmarked (checked through the heap's mark
reader). Then X's pointer moves out of the field and the field is cleared,
and slices run until the cycle finishes. Then: is X still an allocated
block, does its pattern survive 4 096 more allocations of 64 bytes, and is
one of them X?

The probe used on the releases, `probe_src.cr` (kept out of the tree; the
regression is the same construction), on the mprotect backend:

| tree | stack slot | class variable | 2nd thread's stack |
|---|---|---|---|
| `nursery-mprotect-040` (`b2f6c098`) | swept, handed out again | swept, handed out again | swept, handed out again |
| v0.39.0 | swept, handed out again | swept, handed out again | dies in the finishing sweep (the card defect regression 99 fixes) |
| v0.38.0 | swept, handed out again | swept, handed out again | dies in the finishing sweep (same) |

On the soft-dirty backend (`b2f6c098` plus the rescan, rescan off): swept.
Every tagged release's `collect_a_little`, v0.1.0 to v0.39.0, has no root
scan in it (read with `git show <tag>:src/gcry/collect.cr`).

The second hole, probe on `b2f6c098` plus the rescan, X moved into the
first word of a block N allocated after the arm and held by a static, 4 runs
each:

| N | mprotect | soft-dirty |
|---|---|---|
| 16 bytes, in an existing chunk | alive 4/4 (its page dirty) | swept 4/4 |
| 4 MiB, a new mapping | swept 4/4 (1 dirty rescan, 11 dirty pages, N's not among them) | swept 4/4 |

The soft-dirty rows are a third defect, not this one: every one of those
terminations hit the too-dirty fallback (`scan_softdirty_pages`, 241–460 of
538 pages dirty — the mark's own writes dirty the chunk metadata), which
returns false and leaves the backend `SoftDirty`, so the lost-barrier check
(`armed && @barrier_backend.none?`) did not see it and the slice swept on an
unscanned dirty set. Reported to the owner of `nursery-mprotect-040`, which
now ends such a cycle in a full collection as well.

## Fix

**Roots.** The begin stop's root marking moved into
`Heap#mark_incremental_roots`, and the terminating stop calls it again after
the dirty-page scan, then runs one more budget of marking
(`collect_a_little`). It sweeps only if the mark stack is empty after that:
every root rescanned, every dirty page rescanned and everything they found
traced, inside one stop. A slice that cannot drain it within its budget
leaves the cycle open; the next slice to empty the stack rescans both again.
That converges: what the rescan can push is an object white since the begin
stop (new ones are black), and each attempt blackens what it finds. Not
rescanned: `bitmap_settle_cursor_sets` (it zeroes pinned chunks' marks, a
begin-stop-only step).

**Untracked pages.** `Platform.each_mprotect_untracked_page` yields each
page of a range the cards cannot vouch for: outside them, or inside them and
neither protected nor dirty. `scan_mprotect_pages`, for an incremental
termination only (`nursery_only` false), reads those pages of every
non-dormant chunk after the dirty ones and before the dirty bits are
cleared. The re-protect that follows (with `nursery-mprotect-040`'s card
rebuild for a heap that outgrew the cards) brings such a chunk under the
barrier, so each is read once; nursery chunks, never protected, are read at
every termination, bounded by the nursery's size. With no cards at all every
page is untracked and the scan reads the heap — sound, where the blind
barrier was not. Minors are untouched: they walk every old object for
nursery pointers whatever the barrier says (`scan_old_for_nursery_pointers`).

The alternative for the second hole, protecting a chunk when it is mapped
during a cycle, was not taken: a chunk mapped outside the cards cannot be
protected (no card can claim its fault, and new cards are made in a stop),
dormant revives and the nursery would need the same at their own sites, and
the allocator's first writes to the new chunk would fault at once and dirty
every page it carves anyway — a fault per page on the allocation path, to
reach the same scan.

**Cost per slice.** Unchanged for a slice whose mark stack does not empty.
A terminating slice adds one root scan (what the begin stop does) and one
budget of marking, plus the untracked pages of chunks mapped since the last
scan (mprotect). Measured under "Cost".

**Research knobs** for the control arms: `Heap.inc_finish_rescan_roots` and
`Platform.mprotect_scan_untracked`, both class properties, default true, so
no `Heap` field is added or moved: `instance_sizeof(Gcry::Heap)` and every
field's offset are the same on `nursery-mprotect-040` and on this branch
(all offsets printed with `offsetof` over `Heap.instance_vars` and diffed).

## Cost

`pause_src.cr` (kept out of the tree), `--release`, on the rescan alone
before the rebase: 200 000 live 48-byte buffers, 40 cycles alternating the
rescan on and off, `collect_a_little(4096)` slices, the pause of the slice
that finishes; medians, µs.

| backend, extra stacks | begin stop | finishing, rescan | finishing, no rescan |
|---|---|---|---|
| mprotect, none | 392 | 3 071 | 3 201 |
| mprotect, 200 parked fibers + 8 threads | 1 668 | 4 616 | 3 304 |
| soft-dirty, none | 89 | 494 | 427 |
| soft-dirty, 200 parked fibers + 8 threads | 1 482 | 1 648 | 702 |

With few stacks the rescan is inside the finishing slice's noise (its sweep
dominates). With many it costs what the begin stop's root scan costs,
0.9–1.3 ms here, once per terminating stop — the bound the fix claims.
Slices that do not finish are unchanged.

## The final tree

The probe on `e13c9ee8` (both fixes, on `39c96a15`), every window on both
backends, 4 runs each: X alive in all 40 (stack, static, thread, newchunk,
oldchunk; mprotect and soft-dirty). Soft-dirty terminations that took the
too-dirty fallback now end in a full collection (`39c96a15`).

## Regression 100

`process_spec/regression/100_incremental_stack_rescan_spec.cr`, four
windows by where X goes — *stack* (a stack slot of the frame driving the
slices), *static* (a class variable), *thread* (a stack slot of a second
thread spinning until the cycle has finished), *newchunk* (the first word
of a 4 MiB block allocated after the arm, its page checked untracked) —
each a fixed and a control arm in a process of its own. Fixed: X allocated,
pattern intact, never handed out again. Control (`inc_finish_rescan_roots =
false` for the root windows, `mprotect_scan_untracked = false` for
*newchunk*): X swept. Linux only (the mprotect barrier); elsewhere the child
prints the skip marker and the parent asks for no control mark.

| arm | headerless | `-Dgcry_block_headers` |
|---|---|---|
| each of the four fixed arms | 30/30 alive, intact | 30/30 |
| each of the four control arms | 30/30 swept and handed out again | 30/30 |

Two existing regressions name their block from a root and so would no
longer show their own defect: regression 91 (a static-held block whose mark
a bitmap `free` wipes; the rescan marks it again) turns the rescan off in
both arms, so its window measures the claim guard alone; regression 99
*nocards*' control (an object pinned on the stack and stored into a black
block after the cards were lost) turns off both the rescan and the
untracked scan, each of which would find it. Their fixed arms are as they
were.

## Releases and the default configuration

0.38.0 and 0.39.0 reproduce the root hole (table above); no release since
0.1.0 scanned a root after the first stop. The untracked-page hole is in the
same code path there, behind the card defect that crashes first: the
*newchunk* probe on v0.39.0 dies in the finishing slice ("Invalid memory
access", 2 of 2), its old-chunk twin keeps X (2 of 2). Both are
opt-in only: `GCRY_INCREMENTAL=1` (or calling `collect_a_little`), the second
with the mprotect backend (`GCRY_MPROTECT_BARRIER=1`, or aarch64 Linux,
which has no soft-dirty). The default stop-the-world collector marks every
root and traces the heap inside one stop and runs no incremental slice.

## Checks

On `e13c9ee8` (code) with these docs, x86-64 Linux host, under the shared
lock (`/home/naruto/playground/.scratch/verify.sh`, after
`rm -rf lib/ameba bin/ameba`):

| check | result |
|---|---|
| `crystal tool format --check src spec process_spec bench samples` | clean |
| `make lint` | 250 inspected, 0 failures |
| `crystal spec -Dgc_none spec/all_specs.cr` | 303 examples, 0 failures |
| the same, `-Dgcry_block_headers` | 325 examples, 0 failures |
| the same, `GCRY_DEBUG_INVARIANTS=1` | 303 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 382 examples, 0 failures, 2 pending |
| the same, `-Dgcry_block_headers` | 383 examples, 0 failures, 2 pending |
| the same, `GCRY_BITMAP_ALLOC=0` | 383 examples, 0 failures, 2 pending |
| `make windows-typecheck`, `make darwin-typecheck` | ok |

Regressions 27, 83, 85, 87, 91, 95, 99 and 100 together, before the
rebase onto `39c96a15`: 93 examples, 0 failures with headers; headerless
the same set passed once 99 *nocards*' control turned the untracked scan
off.

Keep rule: not run. The default path's machine code does not change: the
changed functions (`collect_a_little`, `begin_incremental`,
`mark_incremental_roots`, `scan_mprotect_pages`'s incremental branch,
`each_mprotect_untracked_page`) run only inside an incremental cycle, and no
`Heap` field moved.
