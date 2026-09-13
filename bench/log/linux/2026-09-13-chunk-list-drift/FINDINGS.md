# What the chunk-list divergence costs: it rides mappings, not uptime

Date: 2026-09-13 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree: `3aa73a8` + this
change · instruments `GCRY_CHUNK_LIST_AUDIT=1`, `chunks_mapped`,
`chunk_index_only_now`

The last open piece of the 2026-08-23 live-object release. Since yesterday the
marks of a stranded chunk are cleared anyway (`clear_all_marks` walks the
index), so this is an RSS question: a chunk the sweep's rebuild leaves off
`@chunks` is never swept and can never rejoin the list — the rebuild walks from
`@chunks` and nothing re-links what the head no longer reaches — so every byte
in it is retained for the life of the process. What was never measured is the
**rate**, and the rate decides whether restructuring the rebuild (the splice,
written and retracted twice, in code with a hang history) is worth its risk.

## The axis was wrong twice before the number meant anything

**First attempt: collections.** 180 collections of thread churn, both arms zero.
Then 6 000: shipped zero, and the pre-fix arm climbing 8 → 28 → 49 → 55 → 57
chunks while its heap tracked it 4.26 → 8.85 MB. Reading that as "1.2 KiB
retained per collection" was wrong in a way the plateau in the middle should
have given away: buckets 3000 and 4000 were identical, in chunks *and* in heap
bytes.

**Second: uptime.** Three children, 30 000 collections each — 90 000 collections,
nothing stranded, heap flat at 3.477 MB in all three. Published as a bound it
would have been a lie, and the counter that caught it was the one added next:
those runs mapped **32 chunks in 1200 collections**. "Nothing in 90 000
collections" was nothing in about forty mappings.

**The axis is mappings.** A chunk is stranded by a *prepend* that lands during
the sweep's walk, and a prepend happens in `map_chunk`. No mapping, no event —
which is why a steady-state heap stops losing chunks entirely, and why the leak
is bounded by how much a workload grows and releases rather than by how long it
runs. `chunks_mapped` (cumulative, one increment beside an `mmap`) is the
denominator; `chunk_index_only_now` is the numerator as a snapshot rather than a
sum, since a sum cannot tell one chunk stuck forever from a fresh one lost every
collection.

Driving the denominator needs the *live set* to move, not the garbage: garbage is
reused inside chunks that already exist, while a chunk is mapped only when peak
demand grows. So the harness grows a live set by 64 blocks of 8 KiB a round and
drops it whole every 20 rounds, with eight threads born per collection doing a
little allocating each — the prepend has to come from a mutator racing the walk,
not from the thread running the collection.

## The measurement

| arm | stranded | chunks mapped | per 1000 | heap stranded |
|---|---|---|---|---|
| shipped, steady state (3 × 6 000 collections) | **0** | 532 716 | — | 0% |
| shipped, steady state (1 × 6 000, gate shape) | **0** | 160 175 | — | 0% |
| shipped, startup regime (200 processes × 240) | **0** | 6 280 | — | 0% |
| `sweep_mutator_latch = false` (the pre-fix reads) | 3 208-8 133 | 40 002-44 917 | **80-181** | **97.0-99.3%** |

Combined shipped: **0 stranded in 699 171 mappings**, which is a 95% upper bound
of 4.3 per million mappings, i.e. below 0.6 bytes retained per chunk mapped.

The single shipped sighting behind this item (1 run in 14 of the churn
reproducer, 2026-09-12) does not survive as a rate: the identical command, 60
more runs, strands nothing — one event in 74 runs, which is a sighting and not a
measurement.

## And the pre-fix arm is the finding

`sweep_mutator_latch = false` restores half of the shape that shipped until
2026-09-13: the mutator count read per decision instead of latched in the stop.
Under a workload that maps, it strands 80-181 chunks per 1000 mapped and ends
with **97-99.3% of the heap in chunks no sweep will ever visit** — 1 GiB in 1368
collections, where the same workload on the shipped tree sits at 15 MB.

So the latch fix (`da01ae7`) did not only close a rare use-after-free. It closed
a near-total heap leak that needed nothing rarer than allocation plus threads,
and that is very likely the "fat app" RSS the roadmap has carried since
2026-08-23 as a separate mystery.

## Verdict

The rebuild stays as it is. Restructuring it — the prefix-splice that was
written and retracted twice — buys at most 0.6 bytes per mapping against a hang
history in that exact code. The instrument is what ships instead:
`make chunk-list-drift`, three arms in ~35 s, capped at 5 stranded per 1000
mappings. Not zero, because the race is still open and a gate on zero would red
CI on the real event; three orders of magnitude below the pre-fix rate, so
reopening the race fails it. 4 of 4 runs green locally.

## The same mistake was already in a shipped gate (2026-09-13, later)

`make mark-clear-index` went red on CI the same day, on its **control** arm:
"every one of 6 children walked the list, found nothing and did not crash". Not
a regression — the arm had been passing on luck for exactly the reason this log
is about. Its workload was thread churn and nothing else, which maps about
thirty chunks per child, so the control was asking a 1-in-1000-mappings question
of a 30-mapping sample. It found residue 6 of 6 times locally and 0 of 6 on the
two-core runner.

Two changes, both from the measurement above:

1. **Drive mappings.** A live set that grows for 20 rounds and is dropped whole,
   so chunks are released and mapped again.
2. **The born threads have to allocate.** Threads that only start and stop are
   usually gone by the time the after-world sweep walks the list, so no prepend
   ever races it. Measured as a bimodal control before this: 82 stranded chunks
   in one child, zero in the next two.

After: 6 of 6 children with mark residue (1-11 chunks each) and 18-91 stranded
chunks, in ~4 s of children; `make mark-clear-index` 0 failures in 6 runs.

## The bound, tightened overnight (2026-09-13/14)

Two children, 200 000 collections each, on the shipped tree:

| child | collections | chunks mapped | stranded | heap at the end |
|---|---|---|---|---|
| 1 | 199 998 | 5 328 755 | **0** | 13.8 MB |
| 2 | 199 998 | 6 061 154 | **0** | 13.0 MB |

**11,389,909 mappings, nothing stranded.** The 95% Poisson bound is
2.6e-07 per mapping, i.e. **under 0.03 bytes retained per chunk
mapped** — sixteen times tighter than the 4.3 per million this log opened with,
and two orders of magnitude below the pre-fix arm's 80-181 per 1000.

Both heaps ended where they started (13-14 MB against 15 MB in the shorter
runs), which is the same statement from the other side: nothing accumulated over
200 000 collections because nothing was lost.

