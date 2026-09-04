# The allocation fast path, measured against Boehm's

Branch `perf-single-mutator`, on top of upstream `master` at 2b77240.

## Where the Kemal gap was not

Headerless Kemal `/json` sat at 92% of Boehm with the collector at 0.2–0.5%
of wall time, so the gap is in the mutator. The first guess — that the
allocation fast path's atomics were it — was wrong in an instructive way: a
steady-state microbenchmark (20M allocations, 4096-object ring, collection
on) showed gcry *faster* than Boehm per allocation in every mode, because
Boehm's cost there is its collections on a tiny heap. With collection
disabled Boehm's pure fast path is 15–17 ns for a 48-byte object and 10 ns
for 16 bytes; gcry's was 38–55 ns. That is the number Kemal pays.

## What a 48-byte allocation cost, and why

Under the bitmap allocator, per allocation: the class spinlock (acquire and
release), three atomic adds for `total_bytes`, `bytes_since_gc` and
`live_objects`, a compare-and-swap loop for `free_bytes`, an atomic OR for
the `occ` bit, a `memset` call for the block, and ten-odd branches in
`maybe_collect`. About six lock-prefixed operations at ~20 cycles each on a
path Boehm runs from a thread-local free list with none.

Two findings made a cheaper path possible without touching the multi-thread
case:

- gcry already flips the heap's counters to atomic in its `pthread_create`
  wrapper when a second thread appears — but the runtime's SYSMON thread is
  created at boot, so every program was on the atomic path from its first
  allocation. SYSMON never allocates (gcry already exempts it from the
  stop-the-world by name), so the wrapper now exempts it from the flip too.
- The "plain" counter branch used `Atomic#set`, which is an `xchg` — locked
  whether asked or not — which is why an earlier measurement found it "never
  cheaper". `lazy_get`/`lazy_set` are the plain loads and stores.

## The single-mutator fast path

`Gcry.single_mutator?` is true until the first non-runtime thread is created
(cleared process-wide in the `pthread_create` wrapper, before the thread
exists, never set again; `GCRY_SINGLE_MUTATOR=0` pins the multi-thread path
for A/B). While it holds, the mutator is also the collector, so:

- `with_freelist_lock` yields without locking;
- counters use plain loads and stores;
- the `occ` bit is a plain OR (the cursor owns the word, the sweep runs on
  this thread);
- `realloc` skips the root-list registration around its allocation (a
  `LibC.malloc`, a free and a list walk per call; the root existed for a
  peer thread's collection, and `@suppress_collect` already forbids a
  self-triggered one);
- 16/32/48/64-byte blocks are cleared with unrolled stores instead of a
  `memset` call.

Nothing changes once a second mutator thread exists.

## A correction to the PR #33 table

`bench/kemal/lib/gcry` is an absolute symlink to this checkout, so the
"gcry `master`" arm in that PR's Kemal table — built in a worktree — was in
fact this branch's default mode (header layout, freelist allocator). Its
numbers (43 544 req/s, 0.78× Boehm's RSS) describe the branch, not master.
The table below is measured with each worktree's link pointed at itself,
which the run log records with `readlink -f`.

## The fast path in isolation

Steady state (20M allocations, 4096-object ring, collection on), headerless:

| | before | lock-free counters, inline clear | dedicated hit path |
|---|---|---|---|
| `malloc(48)` | 50.5 ns | 37.8 ns | 21.6 ns |
| `malloc_atomic(48)` | 34.0 ns | 22.4 ns | 8.8 ns |
| `malloc(16)` | 38.6 ns | 27.5 ns | 12.7 ns |
| `malloc_atomic(16)` | 32.9 ns | 20.5 ns | 7.6 ns |

Boehm's pure fast path, collection disabled: 15–17 ns at 48 bytes, ~10 ns
at 16.

## Kemal did not follow, and why: page faults, not compute

A quiet, interleaved run (Boehm, upstream `master` headerless, this branch
headerless; 11 rounds × 15 s; nothing else on the box) put the hit path at
94.6% of Boehm, +6.0% over upstream headerless (t = 1.50). CPU time per
request, from `/proc/<pid>/stat`, told the rest: gcry already used *less*
CPU per 10 000 requests than Boehm (178 ms vs 214) — and took 1 256 minor
page faults per 1 000 requests where Boehm took 2.

The allocator in isolation showed the mechanism: an 8 KiB allocation cost
two page faults every time, zero with `GCRY_KEEP_CHUNKS=1`. Linux released
every emptied chunk at every collection (warm and dormant budgets both 0),
so the next cycle's 24 MB of blocks — Kemal allocates an 8 KiB response
buffer per request — arrived on never-touched pages, at a cost that no pause
metric could show. Under the bitmap allocator an emptied chunk is reusable
in place (pages resident, `occ` zero), so keeping it is free.

## The retention default, measured

`empty_chunk_warm_retain` now defaults to the collection threshold under the
bitmap allocator (knob unchanged; `0` restores release-everything). Quiet,
interleaved, 15 rounds × 15 s:

| arm | req/s | vs Boehm | RSS under load | CPU ms / 10k req | faults / 1k req |
|---|---|---|---|---|---|
| Boehm | 49 471 | 100% | 22.2 MB | 222 | 2.4 |
| headerless, retain (32 MiB threshold) | 55 767 | **112.7%** (t = 5.25) | 44.5 MB | 179 | 11.1 |
| headerless, retain, `GCRY_THRESHOLD=16777216` | 58 698 | **118.7%** (t = 4.41) | 44.5 MB | 170 | 10.6 |

Throughput is past Boehm with margin; RSS under load is twice Boehm's.
(Correction: the `GCRY_THRESHOLD=16777216` row ran the default
configuration — the runner passed the comma-joined environment unquoted and
only its first variable reached the server, which is why both rows show
44.5 MB. Its number is a second sample of the row above it.)

## Why RSS was double, and the adaptive threshold

RSS under load was the fixed process threshold, not a leak: 32 MiB of
allocation between majors plus 32 MiB of warm chunks, for a live set of
~10 MB. `/gc-stats` on an 8 MiB threshold showed the honest shape —
26 MB heap, 10.2 MB live, 6.8 MB fully free chunks, RSS 20.9 MB.

Boehm sizes its heap from the live set: the allocation budget between
collections is roughly the live bytes divided by `GC_free_space_divisor`
(3), so a 10 MB live set gets a ~7 MB budget and a 60 MB one gets 40 MB. The
process heap now does the same after each major: next threshold = live
bytes the sweep measured × `GCRY_THRESHOLD_FACTOR`% (default 100), clamped
to 8–64 MiB, starting at the floor; the warm-retention budget follows it.
`GCRY_THRESHOLD` pins a fixed threshold and turns it off; EC4 keeps its
fixed 64 MiB (unmeasured here).

Quiet, interleaved, 9 rounds × 15 s, factor at 50 / 100 / 200 % and a
fixed 8 MiB for reference (initial threshold still 32 MiB in this run):

| arm | req/s | vs Boehm | t | RSS end | RSS peak | faults / 1k | CPU ms / 10k |
|---|---|---|---|---|---|---|---|
| Boehm | 54 337 | 100% | | 22.8 MB | 22.8 MB | 2.1 | 201 |
| factor 50 | 60 199 | 110.8% | 2.15 | 22.0 MB | 33.6 MB | 7.7 | 166 |
| factor 100 | 58 883 | 108.4% | 1.89 | 23.9 MB | 33.6 MB | 7.9 | 169 |
| factor 200 | 58 241 | 107.2% | 1.28 | 33.7 MB | 33.7 MB | 8.0 | 173 |
| fixed 8 MiB | 59 156 | 108.9% | 1.72 | 20.5 MB | 20.5 MB | 3.6 | 169 |

The factors are within noise of each other on this live set (50% clamps to
the 8 MiB floor, so it *is* the fixed-8 MiB arm); the peak came from the
first cycle's 32 MiB. With the initial threshold at the floor, 11 rounds ×
15 s:

| arm | req/s | vs Boehm | t | RSS peak | faults / 1k | CPU ms / 10k |
|---|---|---|---|---|---|---|
| Boehm | 54 079 | 100% | | 21.1 MB | 2.1 | 201 |
| headerless, adaptive (default) | 60 463 | **111.8%** | 2.98 | 22.5 MB | 4.1 | 165 |
| headerless, `GCRY_THRESHOLD=8388608` | 60 303 | 111.5% | 3.21 | 20.4 MB | 3.5 | 165 |

Throughput 11.8% past Boehm at Boehm's peak RSS (within 1.4 MB), on 18%
less CPU per request. The adaptive default is kept over the fixed 8 MiB
because it is the one that also fits a fat app: a fixed 16 MiB once cost
acikturkiye ~20pp through major cycling, and this threshold grows with that
live set.
