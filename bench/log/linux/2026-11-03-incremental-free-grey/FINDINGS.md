# A block freed grey keeps its incremental mark-stack entry (regression 102)

Branch `inc-free-grey-040`, on `release-0.40.0` at `b1cfbba0`. The ROADMAP
item "`free` of a grey large block mid-cycle leaves its mark-stack entry
behind" (`../2026-11-02-incremental-stack-rescan/FINDINGS.md`, found in
review) was a reading. It is real, on more than large blocks, and in every
release.

## The hole

An incremental cycle (`GCRY_INCREMENTAL=1`, `collect_a_little`) pushes the
roots' blocks in its begin stop and drains the mark stack a budget at a time
in later stops (`mark_loop_budget`, its only drain). Between stops the
program runs. A block it frees there may be grey: marked, its entry still on
the stack. `GC.free` does not touch the stack, and `scan_object` trusts the
entry when a slice pops it:

- a tagged entry (a small, non-atomic block of a known class) is read with
  no chunk lookup at all: payload at the entry, length from the class;
- an untagged one (a large block, or a barrier-rescan push) is resolved, but
  on the header layout (`-Dgcry_block_headers`) its header is read first
  (`BlockHeader.atomic?`, kept ahead of the lookup for the mark's cost).

So the slice scans whatever is at that address by then. The free of a large
block runs the cache trim, and a 4 MiB block is over the cache's retention:
`GC.free` alone unmaps its chunk. A smaller large block stays cached, a small
one goes back to its chunk; the address can be handed out again, or another
mapping can take it.

`GC.realloc` is not a source: it copies and leaves the old block to the
sweep (probe, *large-realloc* below: the old chunk still indexed and mapped
after the realloc and a trim), and its page move is off while a barrier is
armed (`move_large_contents`). Nothing else deallocates a block between
stops: sweeps run inside collections, and minors and majors abort an open
cycle first (which clears the stack).

## Probes

`probe.cr` (kept out of the tree, `/home/naruto/playground/.scratch/
IncFreeGrey/probe/`): G held by a class variable, `collect_a_little(0)` (the
begin stop and a slice of no work), G checked marked and its entry on the
mark stack, the class variable cleared, the case's action, then the cycle
run out. The mprotect barrier; Z and Y are 64 atomic bytes.

| case | action | headerless | header layout |
|---|---|---|---|
| *large-unmap* | 4 MiB G freed, cache trimmed: not indexed, not in `/proc/self/maps` | survives (the lookup finds no chunk) | **SIGSEGV** in `scan_object` ← `mark_loop_budget`, at G's header + 4 (the flags) |
| *large-cached* | 40 000-byte G with Z a page into it, freed, still cached | Z kept | Z kept |
| *small-free* | 16 000-byte G with Z a page into it, freed | Z kept | Z kept |
| *small-reuse* | 64-byte G freed and handed out again; Y moved into the new block, the slices run until G's entry is popped, then the field cleared | Y marked by the slice that popped the entry; kept through the cycle | same |
| *large-remap* | 4 MiB G freed, unmapped, a new 4 MiB block at the same address | survives | survives (the address mapped again) |
| *large-realloc* | 4 MiB G realloc'ed to 8 MiB, cache trimmed | survives: the old block is not freed | same |

On `b1cfbba0`, each run once per layout (the regression's counts are
below); *large-cached* first used 4 MiB, and the free's own trim unmapped
it, so the header layout died as in *large-unmap* with no explicit trim. Z
is a word in a page of G's payload past the one the free writes (the
header, or a link), so the termination's dirty-page scan does not read it:
Z was kept by the stale entry, and the control arms below show nothing else
keeps it.

The releases, the same probe on worktrees of the tags:

| tag, layout | backend | large-unmap | large-cached | small-free | small-reuse |
|---|---|---|---|---|---|
| v0.39.0 headerless | soft-dirty | survives | Z kept | Z kept | Y kept |
| v0.39.0 headers | soft-dirty | **SIGSEGV** in `scan_object` | Z kept | Z kept | Y kept |
| v0.38.0 headerless | soft-dirty | survives | Z kept | Z kept | Y kept |
| v0.38.0 headers | soft-dirty | **SIGSEGV** in `scan_object` | Z kept | Z kept | Y kept |
| v0.38.0, v0.39.0, both | mprotect | dies first in the dirty-page scan or the finishing sweep (the card defects regression 99 fixes, `../2026-11-02-nursery-mprotect/`); header layout *large-unmap* in `scan_object` | | | |

`mark_loop_budget` scans every popped entry unchecked in every tag from
v0.1.0 to v0.39.0 (read with `git show <tag>:src/gcry/…`). Opt-in only: the
stop-the-world mark pushes and pops within one stop.

## Fix

`mark_loop_budget` resolves each entry before anything at its address is
read, and scans it only if it still names an allocated block's start in a
chunk of its kind; otherwise it counts it (`Heap.inc_stale_entries_skipped`,
a class getter) and pops the next. A tagged entry needs the chunk's class to
be the tag's; a large one the chunk's large header; a rest entry (a large
payload's unscanned tail, parallel mark only) an allocated large block
around it. The common entry, tagged on a bitmap chunk, is checked inline —
the radix entry, the class and data range, the block's start and its `occ`
bit, the reads `resolve_candidate` makes — and anything else through
`find_object_with_chunk`, the mark's own resolution.

A block handed out again at the address is allocated black and passes: its
scan marks what it holds when popped (*small-reuse*: Y marked, kept through
the cycle) — floating garbage, as any live block's referents dropped
mid-cycle are, and the next cycle sweeps it (probe: Y swept by a second
cycle, both layouts, with the check on and off). Telling it from the block
the entry was pushed for needs a per-block birth stamp the allocator would
write; not worth a hot-path change for one cycle's retention.

The options weighed:

- **`GC.free` drops the entry.** Finding it is a search of the stack, per
  free of a marked block while a cycle is open: O(stack) on a path zlib and
  GMP call per buffer. It also changes `free_result`, a hot default path.
- **Free defers releasing a grey block's chunk to the cycle's end.** Covers
  only the unmap, not the dead contents, and every release path would need
  it (the free's trim, the allocator's trims, recycling).
- **Gate the check on an explicit free having happened since the begin
  stop** (`@expl_freed_bytes_since_gc` moved). Zero cost in a cycle without
  frees, but a free's count and its deallocation are separate steps (the
  large arm counts first, the small ones after), and a thread the stop
  freezes between them defeats the gate in one direction or the other.
  Taken: the check on every pop, which needs no reasoning about the
  mutator's order.

`Heap.inc_scan_checks_entries = false` (class property; no `Heap` field)
scans every entry unchecked, the code before: the control arm.

## Cost

`cost.cr` (out of the tree), `--release`: 1 000 chains of 200 48-byte
nodes from a static array, 40 cycles alternating the check on and off,
`collect_a_little(4096)` slices on the mprotect barrier; medians of 20
cycles each, µs, three runs (two for `GCRY_BITMAP_ALLOC=0`).

| layout | check | marking slices | whole cycle |
|---|---|---|---|
| headerless | off | 2 472 / 2 793 / 2 464 | 3 537 / 3 911 / 3 520 |
| headerless | on | 2 615 / 2 932 / 2 597 (+5.0–5.8%) | 3 705 / 4 016 / 3 669 (+2.7–4.8%) |
| headers | off | 2 635 / 2 641 / 2 601 | 4 080 / 3 996 / 3 974 |
| headers | on | 2 848 / 2 827 / 2 761 (+6.2–8.1%) | 4 246 / 4 196 / 4 142 (+4.1–5.0%) |
| headers, `GCRY_BITMAP_ALLOC=0` (all through `find_object_with_chunk`) | off / on | 8 677 → 9 505, 8 308 → 9 470 (+9.5%, +14%) | |

The first version resolved every entry through `find_object_with_chunk`:
+27–30% of the marking slices on both layouts (headerless 2 546 → 3 209,
2 458 → 3 178, 2 493 → 3 227), the same with the entry's payload prefetched
ahead of the check. The inline path for tagged bitmap entries took it to
the table above.

## Machine code

`samples/json_churn.cr`, `--release`, on `b1cfbba0` and on this branch, both
layouts: every function's disassembly, addresses and branch targets
normalized, compared by name. 1 124 functions headerless and 1 128 headers,
none added or removed, one differs: `Heap#mark_loop_budget` (28 → 128
instructions). `scan_object`, `mark_loop`, the serial and parallel drains,
`mark_impl_unlocked`, `free_result` and every allocation path are
unchanged, so the keep rule's benches and `make alloc-entry-frame` measure
nothing this change touches.

## Regression 102

`process_spec/regression/102_incremental_free_grey_spec.cr`, three windows —
*unmapped* (4 MiB), *cached* (40 000 bytes), *small* (16 000 bytes), the
probe's rows — each a fixed and a control arm in a process of its own.
Fixed: the entry counted skipped and, for *cached* and *small*, Z swept.
Control (`inc_scan_checks_entries = false`): Z kept; *unmapped* dies of
SIGSEGV at G's header on the header layout (the parent checks the reported
address against G's header), and prints the skip mark headerless, where the
code before was already safe. Each window also checks G's entry on the
stack and Z unmarked after the begin slice, G not allocated after the
free, and no lost-barrier full collection (it clears the stack and would
pass any arm). Linux only (the mprotect barrier), as regressions 85, 91, 95
and 100.

A false root marking Z in the begin stop would leave no window; the arm
then runs the cycle out and builds again (at most three times). It never
happened here. *unmapped* lost its window two other ways, both now
retried the same way:

- something mapped G's address again between the trim and the check (1 in
  1 906 runs, the check failed the arm then): built again, and nothing
  allocates between the check and the slices;
- another thread mapped it after the check, before the slice popped the
  entry, and the header-layout control survived (5 in 4 000, then 1 in
  3 114; the mapping each time an anonymous 8 MiB `rw-p` one, read from
  `/proc/self/maps` by the failing child): when the control survives with
  G's address mapped it builds the window again.

Runs on the final tree, each a parent and its child processes:

| arm | headerless | headers | headers, `GCRY_BITMAP_ALLOC=0` | headerless, `GCRY_BITMAP_ALLOC=0` |
|---|---|---|---|---|
| all six arms, parent | 200/200 | 200/200 | 200/200 | 200/200 |
| each *cached* / *small* child alone, fixed and control | 500/500 each, 0 retries | 500/500 each, 0 retries | | |
| *unmapped* fixed child alone | 6 000/6 000, 3 retries | 6 000/6 000, 3 retries | | |
| *unmapped* control child alone | 6 000/6 000 skip mark, 1 retry | 6 000/6 000 SIGSEGV at G's header, 6 retries | | |

Before the inline path (every entry through `find_object_with_chunk`), 230
parent runs per configuration (headerless, headers, headers with
`GCRY_BITMAP_ALLOC=0`) and 200 of each *cached* and *small* child alone:
all passing, 0 retries.

## Checks on the final tree

| check | result |
|---|---|
| format, lint | clean, 254 inspected |
| `spec/all_specs.cr` (plain / headers / invariants) | 307 / 330 / 307, 0 failures |
| `process_spec` (plain / headers / headers with `GCRY_BITMAP_ALLOC=0`) | 400 / 401 / 401, 0 failures |
| `process_spec` on Crystal 1.22.2 (headerless / headers) | 400 / 401, 0 failures |
| windows and darwin typechecks | ok |
| `make alloc-entry-frame` | 5 examples, 0 failures |
| stress at 0.5 | nursery-mprotect 10/10, incremental-mprotect 5/5, claim-stress-lazy 100/100, in-stop 150/150, gate 2/2 |
