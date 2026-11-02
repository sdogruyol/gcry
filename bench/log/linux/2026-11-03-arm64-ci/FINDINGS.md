# The aarch64 native job's red runs on release-0.40.0 (2026-11-03)

`test (aarch64 native)` (ubuntu-24.04-arm; no soft-dirty in its kernel, so
the page barrier is mprotect) failed in every PR run from `87ccf4f4` on:

| run | head | failing `process_spec` step | failures |
|---|---|---|---|
| 41306580879 | `87ccf4f4` | `-Dgcry_block_headers` | 95 *minor fixed* (`:196`), 74 (`:49`) |
| 41315851564 | `551acbfc` | `-Dgcry_block_headers` | 95 *minor fixed* (`:250`), 74 |
| 41323054114 | `f3ccc4dc` | `-Dgcry_block_headers` | 95 *minor fixed* (`:250`), 74 |
| 41330687873, 41344711745, 41355236210 | `16a6804b`, `23b6689a`, `bd9f7531` | — | job green |
| 41360733235 | `b1cfbba0` | `GCRY_BITMAP_ALLOC=0 -Dgcry_block_headers` | 100 *remap* fixed and control |

Branch `ci-arm64-040`. Probes on `probe/arm64-040` (runs 41366021478 and
41367317248), Crystal 1.21.0, ubuntu-24.04-arm, full SHAs.

## Regression 100 *remap*: the stop trace's own copy of X

**Failure.** Both arms' children: "X was marked before the move: the window
was not reached" — X marked by the begin slice, before anything moved it.

**Rate.** On `b1cfbba0`, each *remap* arm run 20 times on each of two
runners, parent and child as the suite runs them:

| layout, allocator | fixed | control |
|---|---:|---:|
| header, freelist (`GCRY_BITMAP_ALLOC=0`) | 40 of 40 red | 40 of 40 red |
| header, bitmap | 0 of 40 | 0 of 40 |
| headerless | 0 of 40 | 0 of 40 |

Deterministic on that configuration; the job's four other `process_spec`
runs (headerless three times, header bitmap once) passed it. The x86-64
Linux jobs (`test`, `test-crystal-next`) ran the same freelist step green in
that run, and so did 10 local x86-64 runs of each arm.

**Cause.** *remap* alone installs a collection event hook (the stop trace,
added with the arm in `c51890f8`) that reads X's mark bit at every
`PostStopWorld`: `x = Pointer(Void).new(~Rescan100Roots.x_inv)` in the
closure, then `heap.rescan100_marked?(x)` → `find_object`. In
`begin_incremental` that event fires inside the stop just before
`mark_incremental_roots`, whose `scan_mutator_stack` reads this thread's
stack from its own frames up — the same depth the hook's frames had just
used. A copy of X's address left in one of those dead slots is a stack root.

A diagnostic copy of the child (out of the tree, `diag100_probe.cr` in the
first probe) watched X's first mark with the first-mark attribution (X's
pattern word, `0x5A5A5A5A`, as `live_attr_watch_tid`) and searched the band
below the window's frame for words into X after the begin slice; 20 runs of
each arm on each of two runners, freelist:

| hook | X marked by the begin slice | first mark | words into X below the window frame |
|---|---:|---|---|
| on | 40 of 40 (fixed; the control the same) | stack root, every run | 5: at window −2944, −2776, −2344, −2328 (below the hook's frame at −1388) and −160 |
| off (`DIAG_NOHOOK=1`) | 0 of 40 | — | 1: at −160 |

The words below the hook's frame are the hook's reads' frames; with the hook
off they are not there and X is white after the begin slice. Why the
freelist and aarch64 alone put one of them above the scan's stack pointer is
frame layout: the header allocator's lookup and the begin stop's frames
differ from the bitmap allocator's (no cursor settle, no in-flight marks),
and aarch64's frames from x86-64's [INFERENCE: not traced frame by frame].
Not page size, cards or allocate-black: the first mark is a stack root, and
without the hook nothing marks X.

The same residue reaches the terminating stop: its `PostStopWorld` hook runs
just before the root rescan (`mark_incremental_roots` again), so a control
could keep X through the trace's copy rather than any scan of the chunk
[INFERENCE, code reading: the begin stop's mark failed first in every run].

**Fix** (`process_spec/regression/100_incremental_stack_rescan_spec.cr`,
construction only). The hook's reads move to a `NoInline` helper,
`rescan100_trace_event`, so X's and the old block's addresses exist only in
its frame and the lookups below it; the hook then calls
`rescan100_scrub_stack`, which zeroes 64 KiB below the hook's frame — the
same scrub the window already uses for its own dead frames. The hook
allocates nothing still. No check changed; the arm's checks and the trace's
output are as before.

**After** (`a2b68fe3`, run 41367317248):

| | runs | red |
|---|---:|---:|
| whole spec 100 file (all five windows, both arms), freelist | 40 | 0 |
| whole file, header bitmap | 30 | 0 |
| whole file, headerless | 30 | 0 |
| *remap* fixed child alone, freelist | 40 | 0 |
| *remap* control child alone, freelist | 40 | 0 |

Each *remap* child printed the trace: X unmarked at the begin stop's end,
marked entering no stop; marked at the finishing mark's end in the fixed
arm, unmarked in the control.

## Regression 95 *minor fixed*: fixed by `dafe2830`

**Failure.** The child died with SIGSEGV in `Heap#minor_collect` →
`Heap#sweep` → `ChunkHeader.link`/`set_next`, at a page-aligned address.

**Cause.** The nursery-mprotect defect: the mprotect dirty-page scan's
re-protect reached chunks outside the cards, and the sweep then wrote a
large chunk's header on a page it had protected. On aarch64 the mprotect
barrier is the only one, so every minor of 95's *minor* window runs that
scan; on x86-64 the arm takes soft-dirty
(`bench/log/linux/2026-11-02-nursery-mprotect/FINDINGS.md`, whose table
already lists the arm runner crashing on the base).

**Bisect** (95's file alone, header layout, 30 runs per commit; and the
header-layout `process_spec` twice):

| commit | 95 alone | suite |
|---|---:|---|
| `f3ccc4dc` | 30 of 30 red | 2 of 2 red (95) |
| `dafe2830` and every later one through `367c3707`, and `b1cfbba0` | 0 of 30 | 0 of 2 |

`dafe2830` ("the mprotect dirty-page scan reads and protects only what the
cards and the chunks cover") is the fix.

## Regression 74: 95's failure message in its size class

**Failure.** `heap.chunk_occupied_count(chunk).should eq(1)`: got 2.

**Cause.** Not a defect of its own. Regression 74 allocates 2 900-byte
atomic blocks, "an atomic class nothing in the spec runner allocates", and
counts the chunk's allocated blocks. When 95's *minor* child crashes, its
parent fails with `"child #{status.inspect}:\n#{text}"`, the child's output:
2 864–2 954 bytes in the three red logs, an atomic `String` in the same
class (2 561–3 072 bytes). The spec runner keeps the failure, and the string
with it, until the end of the run; 74, run after 95, finds it in the chunk
it allocates from. In all three red runs 95 is failure 1 and 74 failure 2:
on those runners the suite ran 95 first.

**Order probe** (95's and 74's files in one binary, both orders, header
layout):

| commit | order | 95 red | 74 red |
|---|---|---:|---:|
| `f3ccc4dc` | 95, then 74 | 5 of 5 | 5 of 5 |
| `f3ccc4dc` | 74, then 95 | 5 of 5 | 0 of 5 |
| `a2b68fe3` | 95, then 74 | 0 of 30 | 0 of 30 |
| `a2b68fe3` | 74, then 95 | 0 of 30 | 0 of 30 |

74 alone: 0 of 30 at `f3ccc4dc` and at every commit after. It went green
with 95, at `dafe2830`.

## The job

The aarch64 native job's whole step, read out of `ci.yml` at `a2b68fe3` (the
fix on `782e7510`) and run as the job runs it, with its
`GCRY_STW_WATCHDOG_MS=10000`, on three runners (run 41367317248): green 3 of
3 — 41 commands, 1 160–1 188 s accounted, every `process_spec` run
(headerless three times, header bitmap, header freelist) 0 failures, 15 of
15. The branch is rebased since on `9dc170e4`, which changes regression 86's
spec alone.

Checks on the branch: `crystal tool format --check src spec process_spec`,
`make lint` (ameba rebuilt, 254 inspected, 0 failures),
`make windows-typecheck`, `make darwin-typecheck`; regression 100's file
locally (x86-64), 3 runs each of freelist, header bitmap and headerless,
green. No `src` change, so no keep rule and no `alloc-entry-frame`.
