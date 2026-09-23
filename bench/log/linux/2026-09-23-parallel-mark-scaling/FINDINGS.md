# Parallel mark: the named ceiling was a third of it, and it regresses at 2 workers now

**Date:** 2026-09-23 · host: Linux 7.0.0-31-generic x86_64 (QEMU), 12 vCPUs, Crystal 1.21.0
`gc_phases --seconds=3 --survival=0.5 --fanout=6 --shuffle` (78% GC duty
cycle, 2.4 M edges), `GCRY_PARALLEL_MARK=1/2/4`, n=6 per point unless
stated · raw rows beside this file

`tasks/todo.md` recorded 2 workers at **−14.8%** against serial, 4+ as a
regression, and named the cause: the per-object statistics counters in
`scan_object` (`@layout_precise_scans`, `@layout_conservative_scans`),
written by every worker to the same `Heap` fields — false sharing.
"That is the ceiling to break next."

## Measured on the current tree

| pause per collection vs 1 worker | 2 workers | 4 workers |
|---|---|---|
| shared counters (as shipped) | **+34.4%** | **+39.4%** |
| counters deleted (throwaway build) | +21.2% | +35.0% |
| **per-worker counters** (this change) | **+20.4%** | **+28.1%** |

So the recorded −14.8% does not hold on this workload and host: parallel
mark is *slower* than serial at every worker count. The counters are
real and are worth ~14 points at 2 workers and ~11 at 4, and removing
their sharing gets all of that back — but they are about a third of the
regression, not its ceiling. Whatever makes 2 workers 20% slower than
one is still there.

## The change

The two counters are now per worker: one 64-byte line per slot (master
+ up to 16 helpers, the `parallel_mark_workers` clamp), indexed by the
thread-local `Heap.mark_worker`, summed on read. Two properties checked:

- **The sum is right**: 400 050 conservative scans serial, 400 051 at 4
  workers (the 1 is which collection was last). The shared fields were
  plain non-atomic `+=` under concurrent writers, so they were not only
  slow but *lossy* at 2+ workers.
- **The default path does not pay for it**: serial, old vs new build,
  n=10 interleaved — `pause_per_gc` −1.03% (t=−0.66), `ns_per_alloc`
  −0.98% (t=−0.69). Noise. A TLS read per scanned object costs nothing
  measurable.

## What is left, unmeasured

Candidates for the remaining ~20%, each a guess until an arm separates it:
the mark bit is an atomic `OR` on a bitmap word, and on a shuffled graph
workers mark neighbours in the same word (true sharing, not false); the
batched push/steal against the shared stack; and the helpers' busy-spin
between collections (its own open line). The item stays open with the
corrected numbers rather than closed on a third of the answer.

## The remaining 20% has a shape: it is per object, and it loses to small objects

Same graph (`--fanout=6 --shuffle`, 50 000 live slots), object size
swept, n=5 per point, pause per collection against one worker:

| object size | 1 worker | 2 workers | 4 workers |
|---|---|---|---|
| 8 words (64 B) | 7 750 µs | **+30.5%** | **+30.0%** |
| 16 words (128 B) | 11 140 µs | +8.8% | −0.3% |
| 32 words (256 B) | 17 816 µs | −19.1% | −26.7% |
| 64 words (512 B) | 28 580 µs | **−27.7%** | **−50.5%** |

The sign flips between 128 and 256 bytes. At 512 B four workers halve
the pause, which is what a parallel marker is for; at 64 B no worker
count helps. So what is left is a cost paid **per object**, fixed against
the scan work that object brings: amortised by a 64-word body, dominant
behind an 8-word one.

The loop says where it is. `serial_mark_drain` pops and pushes on a
private stack with the prefetch pipeline in front of it. The parallel
path sends **every** object through the shared stack: `scan_object`
pushes children to the worker's push buffer, `flush_pushbuf` moves them
to the shared stack under its lock after each batch, and the next
`pop_mark_batch` takes them back under the same lock — and the batch
scan has no prefetch. Per-object cost is therefore two locked hand-offs
plus a cold miss the serial path hides. Mark-word sharing covaries with
object size too (a mark word covers 64 blocks: 4 KB of 64 B objects,
32 KB of 512 B ones), so this curve alone does not exclude it — but the
loop's own shape makes the hand-off the first thing to try.

**What it means for a Crystal program**: its heap is small objects —
strings, short arrays, hash entries, closures — so the regression side
of this curve is where it lives, which is why `GCRY_PARALLEL_MARK`
regresses HTTP throughput and why its row says to leave it at 1.

**What would change it** (not done here): drain locally first — a worker
scans the children it just pushed from its own buffer, with the prefetch
ring, and spills to the shared stack only above a threshold, so an
object crosses the lock when there is someone idle to take it rather
than every time. The termination argument survives it (a worker stays
busy while it holds unflushed children, which is already the invariant).
The curve above is the measurement that would say whether it worked.

## Two candidates tried, one kept

**Local-first drain — built, measured, rejected.** Workers took their own
newest children back from the push buffer and published only to an idle
peer, so an object crossed the shared stack when someone could take it.
Termination-safe (the worker stays counted busy until its buffer is
empty) and green on every parallel-mark gate. It did not pay:

| object size | 2w flush | 2w local drain | 4w flush | 4w local drain |
|---|---|---|---|---|
| 64 B | +31.3% | +27.5% | +43.8% | +39.6% |
| 128 B | +3.1% | +1.0% | +0.7% | +6.3% |
| 256 B | −18.7% | −20.5% | −22.4% | −25.5% |
| 512 B | −29.4% | −29.3% | −46.4% | −46.1% |

About four points at 64 B, with ±7% per run at n=5: t ≈ 0.9. Not a
measurable win, so it is not in the tree — the loop's shape suggested
the hand-off, and the hand-off is not where the per-object cost is.

**Batch prefetch — kept.** The serial drain has a 16-deep prefetch ring;
the parallel batch scan had nothing. How much that ring is worth where
the regression lives: serial at 64 B objects, `GCRY_PREFETCH=0` is
**+27.6%** (t=+12.9). The batch now prefetches the header and first
payload line of `batch[i+16]` while scanning `batch[i]`, under the same
knob:

| | 64 B, 2 workers | 512 B, 2 workers | 512 B, 4 workers |
|---|---|---|---|
| before | +32.1% | −28.9% | −46.4% |
| batch prefetch | +30.8% | **−33.6%** | **−52.5%** |
| final tree, re-measured (n=6) | — | −32.8% | −49.2% |

A real gain where parallel mark already wins; none where it loses.

## What that leaves

On 64-byte objects two workers with prefetch are still ~30% slower than
one worker with prefetch, and neither the hand-off nor the prefetch
explains it. What is left is the one candidate that scales exactly like
this curve and cannot be tested without a representation change: the
mark bitmap. One 64-bit mark word covers 64 blocks — 4 KB of 64-byte
objects, 32 KB of 512-byte ones — and every mark is an atomic `OR` on
it, so on a shuffled graph two workers marking small neighbours are
bouncing the same cache lines. Separating it needs an arm that spreads
marks across lines (or a per-worker mark buffer merged at the end), and
that is a design change rather than a knob.

**Why it is not measured here**: the instrument that would settle it is
`perf c2c`, which counts loads that hit a line modified by another core
(HITM) and names the lines. This VM exposes no `cpu` PMU
(`/sys/bus/event_source/devices`: breakpoint, kprobe, msr, software,
tracepoint, uprobe), so hardware cache events are unavailable. On bare
metal: `perf c2c record -- env GCRY_PARALLEL_MARK=2 bin/gc_phases
--fanout=6 --shuffle --size=8`, and the mark bitmap's lines at the top of
the report would be the answer.
