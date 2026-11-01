# The incremental finish misses a pointer moved out of a heap field (regression 100)

Branch `inc-stack-040`, on `release-0.40.0` once that carried the
nursery-mprotect fixes (the mprotect card fixes and the lost-barrier full
collection, regression 99; written on `nursery-mprotect-040` before they
were cherry-picked). The ROADMAP item "The incremental cycle never scans a
stack after its first stop" (`../2026-11-02-nursery-mprotect/FINDINGS.md`)
was a reading. It is real, on both barrier backends and in every release,
and probing the same termination found a second hole of the same shape on
the mprotect backend; the review of both fixes found a third, the second
hole through a chunk mapped where one was unmapped mid-cycle.

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

## A chunk mapped where one was unmapped (review)

The review of the two fixes (IncReview) found the untracked-page scan's
gap. Nothing clears a page's protected bit when its chunk leaves the heap:
`mprotect_unprotect_range` runs only from `disarm_mprotect_barrier` and
`drop_mprotect_without_cards`, and the release paths (`release_large_chain`
from `trim_large_cache`, the trim and guard releases) unmap without
touching the cards. So:

1. the arm protects a large chunk L (its bits: protected, clean);
2. mid-cycle the program frees L, and the cache trim unmaps it;
3. a later large allocation N gets a mapping of its own at L's address
   (Linux gave the same address in every run);
4. N's pages are writable, and the cards still call them protected and
   clean: a store into N sets no dirty bit, and both the dirty scan and the
   untracked scan pass over them.

X moved from a heap field into N, the field cleared, is swept — the
*newchunk* defect again, with the fixes on and default settings. IncReview's
probe (`remap_probe_spec.cr`, kept out of the tree: regression 100's
construction, L dropped from the roots before the begin stop, X stored at
`N[2048]`): X unmarked at the end of the finishing mark, swept and handed
out again in 4 of 4 runs, with the rescan on or off; with a fresh address
(`FRESH=1`) the untracked scan finds it.

**Fix.** `ChunkHeader::Flags::BARRIER_ARMED` (bit 8192, free in `flags`):
set on a chunk when the barrier itself protects it under cards that cover
it — the arm (`arm_mprotect_on_old_chunks`) and the re-protect after a
dirty-page scan, each before its `mprotect_protect_range` and only when the
value changes, so the header write never meets a protected page (the arm
runs after `disarm_mprotect_barrier`; in the re-protect a chunk's cover is
what it was at the arm, so only a chunk the barrier has not protected
changes). A chunk mapped since has a fresh header without the flag, wherever
it was mapped. The incremental termination reads such a chunk whole instead
of trusting the bits; a flagged chunk keeps the untracked-page scan. The
re-protect that follows protects it and flags it, so each is read whole
once. Allocation code is untouched; nursery chunks, never protected, are
read whole at every termination, as the untracked scan already read every
page of them. The alternative the review offered, clearing the protected
bits when a range leaves the heap mid-cycle, needs the mutator writing the
cards under the fault handler's in-flight and generation protocol on every
release path; the flag needs neither. Control knob
`Platform.mprotect_scan_unarmed_chunks` (class property, default true): no
`Heap` field.

**Probe on the fix** (IncStack's tree): X alive 3 of 3; with the knob off,
swept 3 of 3, handed out again, unmarked at the end of marking.

**The regression arm's first control kept X.** Regression 100's first
*remap* window held L in a class variable until after the begin slice. Its
control found X alive in 10 of 10 runs (IncStack). The stop trace the arm
now prints (a collection event hook reading X's and L's mark bits at each
stop), run on that construction (kept as `tmp_probe/r100_oldremap_spec.cr`,
out of the tree), control child, 3 of 3 runs alike: 4 stops; at the begin
stop's end L marked, X not; X marked on entering stop 3, the one that
swept — so by an earlier slice's marking, not by the termination's scans —
and alive after. The same trace on the arm as committed: L unmarked at the
begin stop's end, X marked entering no stop; marked at the finishing mark's
end in the fixed arm, unmarked in the control. L's root pushed it at the
begin stop, it was still on the mark stack when the program freed it, and
the slice that popped it read N at its address and found X: the grey free
the review lists as not caused by this patch. The arm now keeps only L's
address, complemented, from before the begin stop, as the probe does
(allocated, collected and dropped in a `NoInline` helper of its own,
`rescan100_old_block`, whose frame the stack scrub then zeroes), and checks
L unmarked after the begin slice.

That check then fired, rarely, on the header layout: L marked after the
begin slice in 1 of 30 control runs after the first rebase (L set up inline
then), and 1 of 30 fixed runs after the second (in the helper). A
diagnostic copy of the arm (out of the tree) wrote a sentinel type id into
L's first word and watched it with the first-mark attribution
(`live_attr_watch_tid`), and scanned this thread's stack from the hook's
frame to 4 KiB above the window's for words into L's 4 MiB: in 150 control
runs, L was marked once, and that once the attribution said *static* — a
word in the scanned writable mappings, not the stack (the stack scan found
one word into L, 2 MiB in at an odd address, not the one that marked it).
A false root, as conservative scanning has; its address moves with ASLR,
hence the rate. Nothing in the fix is involved: the begin stop is the code
before. Neither moving L into a helper nor any scrub can reach static data,
so the arm, when L is found marked, runs that cycle out, keeps L held (so
the next L is mapped elsewhere, not under the same stale word) and builds
the window again, at most three times before failing as "window not
reached". Every outcome check is unchanged. How often it retries is in the
tables below.

That stale entry is its own question, left open in the ROADMAP: with
nothing mapped at the address when it is popped, [INFERENCE, code reading]
the headerless layout finds no chunk and skips it (`scan_object` resolves
the chunk first), while the header layout reads the entry's header
(`BlockHeader.atomic?`) before the lookup — a read of unmapped memory. Not
probed here.

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

`process_spec/regression/100_incremental_stack_rescan_spec.cr`, five
windows by where X goes — *stack* (a stack slot of the frame driving the
slices), *static* (a class variable), *thread* (a stack slot of a second
thread spinning until the cycle has finished), *newchunk* (the first word
of a 4 MiB block allocated after the arm, its page checked untracked),
*remap* (a word 16 KiB into a 4 MiB block mapped mid-cycle at the address of
one the arm protected and the program then freed, the cache trimmed; the
same address and the cards calling the page protected checked) — each a
fixed and a control arm in a process of its own. Fixed: X allocated,
pattern intact, never handed out again, and no lost-barrier full
collection during the cycle (`inc_barrier_lost_collections` unchanged, the
review's nit: that collection marks from every root and would pass any
arm). Control (`inc_finish_rescan_roots = false` for the root windows,
`mprotect_scan_untracked = false` for *newchunk*,
`mprotect_scan_unarmed_chunks = false` for *remap*): X swept. Linux only
(the mprotect barrier); elsewhere the child prints the skip marker and the
parent asks for no control mark.

Each run is a parent and its child process. On `c51890f8` (the remap fix
and arm, on `release-0.40.0` at `bd9f7531`):

| arm | headerless | `-Dgcry_block_headers` |
|---|---|---|
| each of the five fixed arms, parent | 30/30 alive, intact | 30/30 |
| each of the five control arms, parent | 30/30 swept | 30/30 |
| *remap* fixed, child alone | 100/100, 0 retries | 100/100, 0 retries |
| *remap* control, child alone | 100/100, 0 retries | 100/100, 0 retries |
| *remap* with a static word planted into the first old block (copy out of the tree), fixed / control | 10/10 / 10/10, each retried once | 10/10 / 10/10, each retried once |

The planted copy forces the retry path the false root takes (3 times in
about 530 header-layout *remap* runs over all trees here, 150 of them the
diagnostic's, and in none of about 380 headerless): it runs the first cycle
out, builds again on a new old block and gives
the arm's outcome. Each child printed the stop trace: X marked entering no
stop and L unmarked at the begin stop's end, in both arms; X marked at the
finishing mark's end in the fixed arm, not in the control.

Earlier trees, all windows 30 per arm: before the first rebase (`179d318a`,
L inline, the window's then form) every arm 30/30 on both layouts; on
`0106c59b` (after it) the header layout's *remap* control 29/30, and on
`f8eb688b` (L in its helper, no retry) its *remap* fixed 29/30 — the false
root above, each failing as "window not reached", every other arm 30/30.

Regression 99 (24 examples a run), 10 runs of the file per layout on
`c51890f8` and on each earlier tree: 0 failures.

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
access", 2 of 2), its old-chunk twin keeps X (2 of 2). The remap hole needs
no scan of untracked pages to exist: there a remapped chunk is one more
chunk the barrier never protected, the *newchunk* case (not probed on the
releases). All are opt-in only: `GCRY_INCREMENTAL=1` (or calling
`collect_a_little`), the second and third with the mprotect backend
(`GCRY_MPROTECT_BARRIER=1`, or aarch64 Linux, which has no soft-dirty). The
default stop-the-world collector marks every root and traces the heap
inside one stop and runs no incremental slice.

## Checks

On `c51890f8` (code; these docs on top), x86-64 Linux host, under the
shared lock (`/home/naruto/playground/.scratch/verify.sh`, after
`rm -rf lib/ameba bin/ameba`):

| check | result |
|---|---|
| `crystal tool format --check src spec process_spec bench samples` | clean |
| `make lint` | 253 inspected, 0 failures |
| `crystal spec -Dgc_none spec/all_specs.cr` | 307 examples, 0 failures |
| the same, `-Dgcry_block_headers` | 330 examples, 0 failures |
| the same, `GCRY_DEBUG_INVARIANTS=1` | 307 examples, 0 failures |
| `crystal spec -Dgc_none process_spec` | 388 examples, 0 failures, 2 pending |
| the same, `-Dgcry_block_headers` | 389 examples, 0 failures, 2 pending |
| the same, `GCRY_BITMAP_ALLOC=0` | 389 examples, 0 failures, 2 pending |
| `process_spec` on Crystal 1.22.2, headerless / headers | 388 / 389 examples, 0 failures, 2 pending |
| `make windows-typecheck`, `make darwin-typecheck` | ok |
| `make alloc-entry-frame` | 5 examples, 0 failures |
| `bench/stress_overnight.sh --only='pattern-fuzz-(nursery\|incremental)-mprotect\|claim-stress.*' … 0.5` | nursery-mprotect 10/10, incremental-mprotect 5/5, claim-stress-lazy 100/100, claim-stress-in-stop 150/150, claim-stress-gate 2/2 |
| `GCRY_INCREMENTAL=1 bin/pattern_fuzz --phases=100 --objects-per-phase=5000` (soft-dirty), seeds 11, 22, 33, 44, 55 | 5/5 |

Regression 61 (header layout, a WeakRef example with no incremental code)
failed in two of the three header-layout `process_spec` runs on `0106c59b`
(the plain one and Crystal 1.22.2's; `GCRY_BITMAP_ALLOC=0` passed), before
`release-0.40.0` took reg61-040's scrub (`16a6804b`): the header-layout
`process_spec` up to 61 in this tree's glob order (regression 100 runs
before it) failed at 61 in 7 of 15 runs as it was and 0 of 15 with that
scrub applied — the conservative-retention flake
`../2026-11-02-reg61-flake/` explains. On `c51890f8`, which has it, every
`process_spec` run above passed.

Keep rule: not run. The default path's machine code does not change: the
changed functions (`collect_a_little`, `begin_incremental`,
`mark_incremental_roots`, `scan_mprotect_pages`'s incremental branch,
`each_mprotect_untracked_page`) run only inside an incremental cycle, the
`BARRIER_ARMED` writes only where the mprotect barrier protects chunks
(`arm_mprotect_on_old_chunks`, the re-protect), which a heap with neither
the nursery nor incremental collection never arms, and no `Heap` field
was added or moved (the knobs are `Platform` class properties, the flag a
free bit of `ChunkHeader#flags`).
