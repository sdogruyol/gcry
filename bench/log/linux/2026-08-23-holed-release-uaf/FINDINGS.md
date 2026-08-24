# The HOLED page-release path frees a chunk that still holds a live object

2026-08-23, Linux x86_64. **Open.** Confirmed, not fixed.

`GCRY_PAGE_DONTNEED=1` — the Linux opt-in for the HOLED free-page release, and
the default on Darwin — makes `bench/page_release_corruption.cr` fault about one
run in six. With the same binary and the walk turned off, it does not fault at
all.

    GCRY_PAGE_DONTNEED=1                      7 of 40   (HOLED walk, MADV_DONTNEED)
    GCRY_MOSTLY_EMPTY=1 GCRY_DISABLE_PAGE_RELEASE=1
                                              2 of 40   (mostly-empty walk, MADV_FREE)
    GCRY_DISABLE_MADVISE=1                    0 of 40   (neither walk)

All arms back to back on an otherwise idle machine.

The contrast that holds is **a page-release walk against none**: 9 of 80 with
one of the two running, 0 of 40 with both off, Fisher p ≈ 0.028. The two walks
are not distinguishable from each other — 7 of 40 against 2 of 40 is p ≈ 0.15,
and reading a mechanism into that gap is the mistake this file was rewritten
once already to avoid.

## What faults

    gcry: SIGSEGV at 0x7f4a2043d028 — inside the heap span but in no live chunk
          — the chunk was unmapped, or the address is in a hole between chunks
    ...
    *Pointer(Slice(UInt8)) +9
    *Array(Slice(UInt8))  +31
    ~procProc(Thread, Nil)

The worker's own `kept` array, reading one of its elements. The array is live —
it is on the thread's stack and the worker is mid-loop — and its backing buffer
sits in memory gcry no longer counts as a live chunk.

So this is not the `madvise` hazard the harness was built to look for. Nothing
was zeroed. A chunk holding a reachable object was **released**, which is a
false free.

## What this overturns

Commit `66e248b` is titled "no live object is corrupted by the page-release
walks" and its record says the walks were cleared. The narrow claim survives —
no checksum ever failed, so no page was zeroed under a live object — but the
title is wrong about the path being safe, and the investigation was closed on
17 runs of an arm that fails at 17 %. The chance of missing it in 17 runs is
about 6 %, which is what happened.

## A candidate, tested and eliminated

`rebuild_size_class_freelist` looked like the answer. It is the one thing the
HOLED path adds, it runs in the `after_world` branch with mutators live, it
walks `@chunks` — a sixth live-world chunk-list walker that the earlier sweep of
those walkers missed — and it is the only one that *writes*, overwriting the
header of every block it calls free. A live block wrongly on that freelist is
both relinked and overwritten, and free blocks are not traced during marking, so
whatever it points at is collected. That is exactly the shape seen here.

It is not the cause. The mostly-empty walk is HOLED-less by design and rebuilds
no freelist, and it fails too.

## What the two arms share

`release_free_pages_in_chunk`: build a live-page mask by reading every
`BlockHeader.free?` in the chunk holding no lock, then madvise the runs the mask
calls free. HOLED passes `preserve_content: false` (MADV_DONTNEED, zeroes now),
mostly-empty passes true (MADV_FREE, content survives until the kernel
reclaims). That ordering is consistent with 7 against 2, but the sample does not
carry the claim.

Note what the harness's own checksums say: **not one ever failed.** The
112-byte objects it verifies were never zeroed. What was lost is the *path* to a
2 MB buffer — the object holding the reference, not the leaf. A harness that
checksums only leaves cannot see that, which is why this took a crash to find
rather than a verification failure.

## The ledger names the victim

`GCRY_UNMAP_GUARD=1` could not be used here: it hides this fault (14 clean runs
against roughly 2 in 12 unguarded), which fits a fault that needs the range
reused — the guard prevents reuse by never returning the mapping.
`GCRY_RELEASE_LEDGER=1` keeps the guard's record and unmaps anyway:

    gcry: SIGSEGV at 0x7fef2eb2d050 — in a range gcry RELEASED and unmapped —
    base 0x7fef2eb2d000, 77824 bytes, large-object release, at collection 6;
    the write is 80 bytes into it. Collections since: 0

A 76 KiB **large** chunk, released through `cache_large_chunk` ->
`trim_large_cache`, and **Collections since: 0** — the release and the write are
in the same collection window. Not a stale pointer carried for a while: a race
inside the release itself.

Both victims seen so far are *growing* buffers — this one and the
1 970 176-byte Array buffer in `page_release_corruption`. That pointed at
`Heap#realloc`.

## The realloc window: a real hole that this workload never opens

`realloc` roots the old `pointer` across the copy because the type_id gate
rejects a raw buffer pointer as an ambient stack root. `fresh` is the same kind
of pointer and is **not** rooted; `@suppress_collect` covers the `allocate` and
is dropped before `copy_from`. On paper a peer thread's collection during the
copy is free to reclaim the block being copied into.

Rooting it was tried — and had been tried once before today and reverted as
"indistinguishable on 2 of 24", which was underpowered. With 40 per arm:

    fresh rooted     3 of 40
    fresh unrooted   1 of 40

Still nothing, and this time the reason is measurable rather than statistical.
`realloc_collect_overlaps` counts collections that begin while a thread is
inside the copy: **0**, across runs with 18 collections each. The window exists
in the code and is never entered here, so there is nothing to close, and the
rooting was reverted rather than shipped on an argument.

### And the premise was stale

The comment that justified rooting `pointer` says the type_id gate rejects raw
buffer pointers as ambient stack roots. `GC.init` sets
`type_id_gate_stacks = false` — stacks are **ungated**, and the comment there
says why: gating them dropped Channel/Deque buffers and crashed
`Log::AsyncDispatcher`. So a raw buffer in a register or stack slot is already a
root, and there was never anything for `add_root(fresh)` to add.

That is the mechanism behind the null measurement, and it is worth more than the
measurement: it says the door is shut rather than that nobody was seen going
through it. The comment in `Heap#realloc` has been corrected — its second
reason (a minor may not re-scan an old-gen owner, and Crystal stores the result
only after `realloc` returns) still stands and still justifies rooting
`pointer`.

The counter stays. It answers the question directly in any workload — a
crash-rate A/B cannot separate a 5 % defect from a 2 % one without hundreds of
runs, but a collection starting mid-copy either happens or it does not. A
workload that reallocs hard (Kemal, acikturkiye) is where to ask it again.

## The harness's own diagnostic amplifies it

`live_graph_audit` printed its shadow through `String.build`, which is itself a
growing buffer of the kind the ledger named as the victim. Gated behind
`LIVE_GRAPH_DUMP=1` and measured:

    dump off (no String.build)   1 of 24
    dump on                      5 of 24

p ≈ 0.19, so not conclusive, but the direction is plain and it matters twice
over. The rate is roughly five times higher with one extra growing buffer in
play, which is more evidence that growing buffers are what this defect reaches;
and every rate quoted from this harness before the gate existed was measured
with the diagnostic on. Arm-versus-arm comparisons from that period still hold —
both arms carried it — but the absolute rates were inflated.

It still fires with the diagnostic off, so `String.build` is one instance, not
the cause.

## The victim is the same object every time

`GCRY_TRACE_LARGE=1` writes a line for every large chunk mapped — base, chunk
size, payload, collection. Across a run there are 186 of them, and exactly
**one** is the size the ledger keeps naming:

    gcry: large map base=… mapped=77824 payload=75192 coll=0

Two independent sightings, in two harness configurations, gave the identical
release: 77 824 bytes, `large-object release`, **at collection 6**, the write
**80 bytes in**, `Collections since: 0`. Same size, same collection, same
offset. This is one specific allocation, not a random casualty.

`coll=0` and — with phase markers printed from the harness — **before any
`PHASE worker-start`**. It is allocated during process startup, before the
harness's own threads exist. So it belongs to the Crystal runtime, reached
through `GC.malloc`; 75 192 bytes of payload.

Ruled out as candidates for it:

- **`MarkBitmap`** — `LibC.mmap`, not a gcry heap object, would not appear in
  this trace at all.
- **`@chunk_index`** — `LibC.realloc`, same reason.
- **anything the harness allocates** — the graph's payloads are 96 B and
  40 960 B (chunk 45 056, which is the size `page_release_corruption` saw), the
  shadow and runtime tables are `LibC.malloc`, and the deliberately-grown
  `Array(UInt64)` doubles through 65 536 and 131 072.

## It carries no type_id

The ledger now records the released block's first user word — captured inside
`guard_release`, which runs *before* the unmap, because under the ledger there
is nothing left to read by the time a fault reports on the range.

For the victim that word is **zero**. It is not a Crystal object with a
type_id; it is a raw buffer. That agrees with both sightings being growing
buffers, and it closes off the "print the type_id and read off the class"
route.

What the sightings give, together:

- 75 192 bytes of payload in a 77 824-byte chunk — one such map in 186
- allocated at `coll=0`, **before any worker thread starts**
- first user word zero, so a raw buffer rather than an object
- faulted at user offset 40 — five machine words in
- released through `large-object release`, `Collections since: 0`
- the collection number varies (1 and 6 across sightings); the size and the
  offset do not

Ruled out as its owner, all of them because they do not allocate on the gcry
heap at all: `MarkBitmap` (mmap), the mark stack (mmap), `@chunk_index`
(`LibC.realloc`), the finalizer entry/link tables (`LibC.malloc`, and the file
says why), `Roots::Set` (`LibC.malloc`), and the layout tables (`StaticArray`,
so BSS). Whatever it is, it belongs to the Crystal runtime's own startup.

## When it is allocated

An `init done` marker at the end of `GC.init`, printed only under
`GCRY_TRACE_LARGE=1`, places both startup large maps precisely:

    gcry: init done
    gcry: large map … mapped=69632 payload=65536 coll=0
    gcry: large map … mapped=77824 payload=75192 coll=0
    PHASE toplevel            <- the harness's first statement

Both are **after gcry has finished bringing itself up and before any user
code**. That is Crystal's own runtime startup. One is exactly 64 KiB — a fixed
buffer. The other, the victim, is 75 192: a computed size.

Two readings were tried and neither survived:

- *"it scales with type count"* — `small` (gcry only) shows one map,
  `big` (`+http/server, +json, +uri`) shows two, the second 167 936 bytes. But
  that changed two things at once: the type count **and** the startup work
  those shards do (MIME tables, `Log` registry). The measurement cannot
  separate them, and `register_all_from_reference_subclasses` turns out to be a
  compile-time loop writing into `StaticArray`s, with no heap allocation to
  scale. Withdrawn.
- *"one of the harness's requires brings it"* — a probe requiring exactly what
  the audit requires (`gcry` + `bounded_child`), and another that also touches
  `Process`, show only the 69 632 map. Not the requires.

So: a raw buffer, 75 192 bytes, allocated by the Crystal runtime between
`GC.init` finishing and `main`, released by gcry through `large-object release`
while still being written five words in.

## What is still needed

The identity of that 75 192-byte object. The next instrument is the obvious one:
when the ledger matches a fault, print the block's `type_id` — the release path
has the header in hand, and a type_id turns "a 75 KiB something" into a name.

Note what this does *not* say. The object being a runtime allocation does not
make it the collector's fault or the runtime's; it says the fault is
reproducible against a fixed target, which is the first time in this
investigation that has been true.

## What is established

The arm, the rate, the frame, and that the freed object was live and reachable
from the mutator's own stack. Not the mechanism.

## The harness

`bench/page_release_corruption.cr` verifies a checksum on every live object each
round and reports `dontneed_bytes` per arm, so a run that never marks a chunk
HOLED cannot pass for a clean one. Its engagement floor is `max(4 × control,
8 MiB)` — a purely relative floor went vacuous when the control released 0 B in
one run, because that counter is shared with the dormant flush.

Not wired into CI: it is red.
