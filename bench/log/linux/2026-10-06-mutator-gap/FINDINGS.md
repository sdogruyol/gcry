# The mutator gap: Revcomp, JsonParsePull, Binarytrees

Host: the 12-vCPU QEMU guest, Linux 7.0, Crystal 1.21.0, crystal-metric
`--release`, process-fresh. Every build and run under `taskset -c 0-7`
(gcry counts 8 CPUs). Base is `readiness` at `29d1bc6`. A/B harness:
`../2026-10-05-alloc-storm-mark/ab.py`. `perf` is not permitted; phase splits
come from a scratch copy of `metric.cr` that prints `getrusage` deltas
(minor faults, user, sys, wall) plus `Gcry.metrics` collections and pause
for setup, the pre-run `GC.collect` and the timed run. `rsswatch.c` here
samples `/proc/<pid>/statm` every 200 µs to place the RSS peak against
`GCRY_TRACE=1 GCRY_TRACE_LARGE=1` events. Profiles: the SIGPROF sampler of
`../2026-10-06-mark-cost/` (`sampler.c`, `pcprof.py`).

Nothing here is committed as code. The large-object recycling below is a
measured win on Revcomp and is in `large-recycle.patch` (against
`29d1bc6`); it has not been through the gates. The unlocked occupancy OR is
a measured win on Binarytrees and is described in full below; it was
reverted from the tree to keep the two changes apart.

## Where the time goes

### Revcomp

Timed run, three runs each (wall s, minor faults, user/sys s):

| | wall | minflt | user | sys |
|---|---|---|---|---|
| Boehm | 0.496–0.502 | 70–84k | 0.46 | 0.038–0.046 |
| gcry base | 0.563–0.572 | 164.7k | 0.48–0.49 | 0.090–0.099 |
| Boehm, `GC_DONT_GC=1` | 0.574–0.585 | 236k | 0.46 | 0.117–0.124 |
| gcry, `GCRY_DISABLE_AUTO=1` | 0.588–0.590 | 229k | 0.47–0.49 | 0.109–0.120 |

- With collections suppressed the two are equal: the mutator code, the
  small-allocation path and the large-allocation path cost the same. The
  gap is what each collector does with freed memory.
- gcry's run has 9 majors and ~1 ms of pause in total; Boehm 3 collections.
- The extra ~90k faults are large objects. Every `to_s`, `reverse` and `tr`
  string (3 × 26 + 3 × 39 + 3 × 65 MB) and every growth tail of the `seq`
  and `@result` `IO::Memory` buffers lands in a fresh mapping
  (`GCRY_TRACE_LARGE`: 756 MiB mapped in the run). Size-class churn is not
  it: `GCRY_EMPTY_CHUNK_RETAIN=256 MiB` moved the run 164.7k → 164.2k.
- Boehm's heap after the pre-run collect is 528 MB with ~330 MB of it free
  and resident (`GC_PRINT_STATS`, 0 KiB unmapped), and its run reuses those
  pages. `GC_FORCE_UNMAP_ON_GCOLLECT=1` and `GC_UNMAP_THRESHOLD=1` did not
  change that (still 0 KiB unmapped, 75–94k faults).
- gcry on Linux keeps no freed large chunk (`large_cache_retain = 0`): each
  major unmaps what it freed, and the next large allocation maps and faults
  in fresh pages. `madvfree.c` on this host: first touch of 64 MiB is
  16.4k faults and 9.3 ms, rewriting resident pages 2.2 ms, after
  `MADV_FREE` 4.1 ms plus 1.2 ms for the `madvise`; `mremap` growth of a
  resident mapping 0.025 ms.

### JsonParsePull

Timed run: gcry 0.274–0.286 s, Boehm 0.258–0.273 (two runs each), one major
of 0.28 ms in gcry's run. Faults 16.6k against 7–16k, sys 0.014–0.017
against 0.005–0.010. The run is small-object churn into size-class chunks
mapped after the pre-run `GC.collect` released the setup's memory (by
policy, `MADV_POPULATE_WRITE` already batching them). No large-object
change applies. Neither change below moved it (on/off within ±1%).

### Binarytrees

Timed run 0.553–0.563 s against Boehm's 0.545–0.549, with 213–216 majors
and 34–47 ms of pause. Collections suppressed, gcry runs 0.77 s and Boehm
1.07–1.16 (Boehm's 32-byte granule against gcry's 24-byte class). The
prior profile (`../2026-10-06-mark-cost/`) put 22% of samples on the
cursor's `lock or` into `occ`; see "The occupancy OR" below.

## Code placement

Same source, different gcry code size, different speed of stdlib loops:

- Knuckeotide: base 0.623 s, two candidate builds 0.61–0.63, a third
  0.717 s on every run, with recycling on or off. Its profile is the same
  in all builds (`Hash#[]` 32–34%, `String#hash` 17%, `malloc_atomic`
  10–12%); every function is just slower. The hot functions sit at
  48/48/32 mod 64 in base, 16/16/0 in the fast build, 0/0/48 in the slow one.
- Revcomp with recycling off: base 0.561, `p4` 0.526, `p2` 0.567. 6% from
  layout alone.
- Revcomp `PHASE` builds (the instrumented metric) run 0.02–0.04 s faster
  than the plain metric for the same gcry tree.

So a base-against-new A/B on these rows carries ±6% (Revcomp) to ±14%
(Knuckeotide) of placement. Every claim below is a same-binary toggle.

## Change 1: recycle freed large chunks (`large-recycle.patch`)

A large allocation that misses the exact-size cache takes a cached chunk
the last major freed: the front of the smallest one that holds it (the
remainder registered and cached as a chunk of its own, or unmapped below
64 KiB), else the largest one grown by `mremap(MREMAP_MAYMOVE)` (page
tables move, nothing is copied or faulted). The chunk leaves the list and
the index first; the result is registered as a new chunk with a zeroed
block header, as a fresh mapping is. Only the bytes a previous object wrote
are cleared for a pointerful block.

Policy (process GC, Linux):

- A major keeps what it freed, without `MADV_FREE`; the next major releases
  whatever is still cached before its own frees join. A releasing collection
  (`GC.collect`, idle, emergency) releases everything, as before.
- Budget: what the cache holds at the end of the major, less every byte
  mapped fresh since (size-class chunks included). When the cache exceeds
  it, `allocate` trims to it. Without recycling those bytes would have gone
  back at the sweep, so the heap does not grow past where it stood at the
  major while the cache holds anything.
- A `realloc` that will move its pages (`move_large_contents`) does not
  take a cached chunk: the move unmaps the destination under them.
- A chunk whose pages a `realloc` moved out is flagged (`ChunkHeader::MOVED`)
  and released at the end of the major: nothing is resident there.
- Refused (falls back to a fresh map) during a live chunk walk, a stopped
  world, a collection, an incremental cycle, with a page barrier, under the
  release audits, and on threads the stop does not signal.
- `trim_large_cache` built a closure (a heap allocation) per call; it is a
  method now, since `allocate` calls it.
- `GCRY_LARGE_RECYCLE=0` turns it off.

### Revcomp

| | minflt (run) | sys | wall |
|---|---|---|---|
| recycling off | 164.7k | 0.082–0.085 | 0.563–0.572 |
| on, first prototype (shrink, no split) | 126.6k | 0.052–0.066 | 0.518–0.525 |
| on, split + budget (patch) | 109.3k | 0.047–0.059 | 0.521–0.522 |

(`PHASE` build of the patch, same binary, three runs each.)

`ab-p4-summary.txt` (7 trials, the plain metric, the patch with the budget
but before the MOVED release and the cleanups):

| bench | Boehm | base | patch, off | patch, on |
|---|---|---|---|---|
| Revcomp | 0.501 / 970 MiB | 0.561 / 527 | 0.526 / 527 | **0.505** / 527 |
| JsonParseSerializable | 0.267 / 573 | 0.282 / 421 | 0.278 / 421 | 0.281 / 405 |
| JsonParsePull | 0.259 / 547 | 0.281 / 420 | 0.276 / 409 | 0.271 / 411 |
| JsonGenerate | 0.628 / 1304 | 0.562 / 763 | 0.553 / 763 | 0.552 / 763 |
| RegexDna | 1.702 / 510 | 1.706 / 272 | 1.716 / 272 | 1.712 / 276 |
| Primes | 0.613 / 659 | 0.614 / 618 | 0.613 / 619 | 0.631 / 611 |
| Knuckeotide | 0.589 / 43 | 0.624 / 60 | 0.709 / 59 | 0.714 / 59 |

- Revcomp on against off in one binary: −4.0% (every on-run but one below
  every off-run); `ab-p2-onoff-summary.txt`, the earlier prototype: −3.2%.
  Against base the same binary is −10%, of which ~6% is placement.
- Primes +2.9% (+4.7% in `ab-p2-onoff`): its run has no large allocation;
  it collects 5 or 6 times depending on where the pacing lands, in either
  arm (6 runs each: on 5,5,5,6,6,6 / off 5,5,5,6,6,6 majors). Not resolved
  at 7 trials; needs 15+.
- Knuckeotide is the placement case above (off and on identical).
- Everything else within spread.

### What did not work

- **Shrinking instead of splitting** (first prototype): a 26 MB string
  took the setup's 128 MiB chunk and unmapped the other 102 MiB, and a
  64 KiB `realloc` step took a whole 26 MB chunk. 126.6k faults against
  109.3k.
- **No budget**: RegexDna peak RSS 272 → 333 MiB on every run. The setup
  frees ~200 MB of large objects at one major and then allocates 65 MB of
  small strings before the next; small chunks cannot use the cache, so both
  were resident. With the budget: 278.6 → 282.5 MiB (+1.4%).
- **Evicting only for `realloc` growth** (before the budget): RegexDna
  unchanged at 341 MiB. The excess was small-chunk growth, not `realloc`.
- **Keeping chunks two majors** (`IDLE`-flag aging): 109.38k faults against
  109.33k. The budget evicts them first anyway.

### Risk: a bimodal peak on Revcomp

Peak RSS of Revcomp, 16 runs each: base 16 × 526 MiB; patch off 15 × 526,
1 × 652; patch on 11 × 526, 5 × 588–652 (another 20 on: 19 × 526, 1 × 652;
20 with one marker: 18 × 523–526, 2 × 652; 16 with pacing off: 15 × 509,
1 × 635). The extra memory is the setup's 128 MiB `IO::Memory` buffer kept
alive through most of the run. `PoisonHolders.search` at the end of a high
run finds no heap or root holder, only stack slots of the main fiber ~2.7 KB
below its top (`Benchmark.run`'s frame) holding `buffer + 8144` and
`+ 8160`: a stale pointer from early in the setup, into a range the final
buffer happens to occupy when the address space is reused. Conservative
retention by address coincidence; recycling changes how addresses are
reused and, on these counts, makes the coincidence more frequent. The
median is unchanged; the worst case is +24%.

## Change 2: the occupancy OR on the hit path

`fast_alloc` marks the block allocated with `lock or` on the cursor's `occ`
word. The only writer that can race it with the world running is a
`GC.free` from another thread (the after-world sweep skips pinned chunks
and the hit path is closed while it runs). On x86-64 a plain
`orq reg, (mem)` is one instruction, so a stop signal still sees the word
before or after, never between; what is lost is atomicity against that
cross-thread free, whose bit can be set again: the block stays occupied
until the next sweep reclaims it, and `live_objects` is decremented twice
for it. Experiment (in the hit path, toggled by an env flag for a
same-binary A/B):

```crystal
{% if flag?(:x86_64) %}
  ow = s.value.occ_word
  ob = 1_u64 << bit
  asm("orq $1, ($0)" :: "r"(ow), "r"(ob) : "memory" : "volatile")
{% else %}
  Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Or, s.value.occ_word, 1_u64 << bit,
    LLVM::AtomicOrdering::Monotonic, false)
{% end %}
```

(`s.value.occ_word` must go through a local: passed straight into the
`asm` input it took the slot's address, and the first build crashed.
`atomicrmw` with `singlethread` still emits `lock or` on x86-64.)

Same binary, three runs each, lock → plain: Binarytrees 0.529–0.556 →
0.479–0.495 s (−10%; Boehm 0.508–0.525), Knuckeotide 0.617–0.628 →
0.604–0.610 (−2.5%), JsonParsePull and Revcomp unchanged. Not run: 7+
trials, the gates, and a multi-threaded cross-thread-free test of the
counter drift.

## State

- Tree at `29d1bc6` plus `large-recycle.patch`, uncommitted in the
  worktree. Gates not run (format check started).
- Next: apply the patch, run the gates, a final 9-trial A/B with
  `GCRY_LARGE_RECYCLE=0` as the same-binary control, Primes at 15 trials;
  then change 2 as its own commit with the same.
- Change 1 finished in `../2026-10-06-large-recycle/`: the Revcomp
  bimodal peak was the recycler handing a dead string's address back (fixed
  by moving the pages to a fresh mapping), and the Primes delta was the pace
  timing the unmap (fixed by keeping no more than the large bytes allocated
  since the previous major). Change 2 is still open.
