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
  wrapper when a second thread appears — and the runtime's SYSMON thread is
  created at boot, so every program is on the atomic path from its first
  allocation. An exemption for SYSMON was tried and withdrawn: it *does*
  allocate (`Thread#start` builds its main `Fiber` on it), and two threads
  on the unlocked path popped one freelist head — `make scheduler-roots`
  hung under load with that fiber pushed twice onto `Fiber.fibers`, `next`
  pointing at itself. `process_spec/regression/7_sysmon_alloc_race_spec.cr`
  reproduces it in under a second. The regime therefore ends at boot under
  execution contexts, and the numbers below for the fast path are what a
  library heap or a monitor-less program gets; the Kemal numbers were
  re-measured without it (next section).
- The "plain" counter branch used `Atomic#set`, which is an `xchg` — locked
  whether asked or not — which is why an earlier measurement found it "never
  cheaper". `lazy_get`/`lazy_set` are the plain loads and stores.

## The single-mutator fast path, and why it was withdrawn

The first version of the hit path was gated on a process-wide flag,
`Gcry.single_mutator?`, true until the first thread was created, that
skipped the class locks and the atomics outright. It measured well
(headerless 48-byte `malloc` 50.5 → 21.6 ns, `malloc_atomic` 34.0 → 8.8 ns)
and it was unsound: the runtime's monitor thread allocates its main `Fiber`
at start-up, so the exemption that kept the flag true under execution
contexts let two threads pop one freelist head. `make scheduler-roots` hung
under load, 1 in 22 contended runs, with that fiber pushed twice onto
`Fiber.fibers` and `next` pointing at itself; the Darwin hello sample crashed
the same way at boot. `process_spec/regression/7_sysmon_alloc_race_spec.cr`
drives the shape on purpose and found 4 892–8 518 shared blocks per 200 000
before the fix.

## Per-thread cursor sets

The replacement is ownership rather than a flag. Each thread that allocates
from a bitmap heap owns a `Gcry::CursorSet` — one cursor per (class, kind),
reached through a thread-local cache — and `Heap#fast_alloc` pops from that
thread's own free mask with no lock, on any thread. A chunk under a cursor
carries `ChunkHeader::Flags::CURSOR` so no other cursor takes it; the `occ`
store is an atomic OR because a `free` on another thread shares the word;
per-set counters are credited to the heap by compare-and-swap; a
stop-the-world retires every idle set and pins the chunks of one frozen
mid-allocation, which the after-world sweep then leaves alone. Sets are
reclaimed at thread exit through a pthread key destructor, and a process
past 64 threads shares a fallback set under the class lock. The commit
message on `perf-single-mutator` carries the full argument.

Two boot-time traps cost a build each and are worth recording: a
thread-local class variable initialised by a call (`Pointer.null`) and a
constant built by a call both go through `__crystal_once`, which asks for
`Thread.current`, which allocates, which reads the variable — a spin on the
once-lock before the first thread exists. Integers with literal initialisers
and a method in place of the constant. And a `raise` under the class lock
allocates its exception on the same lock: `cursor_set` must never raise,
which is what the fallback set is for.

48-byte `GC.malloc` in a 4 096-slot ring, 5 M per thread, headerless, this
box (`ub/alloc_ns.cr`; the earlier 21.6 ns was a tighter loop without a
ring):

| build | 1 thread | 4 threads | collections (1 / 4) | pause total (1 / 4) |
|---|---|---|---|---|
| upstream `master` (fixed 32 MiB) | 171.4 ns | 1 422.8 ns | 7 / 28 | 64 ms / 401 ms |
| per-thread cursors, locked path pinned (`GCRY_ALLOC_FAST_PATH=0`) | 227.6 ns | 1 489.0 ns | | |
| per-thread cursors | **77.8 ns** | **801.4 ns** | 28 / 111 | 215 ms / 3 014 ms |

(Those rows were taken under a load average of 25 from two processes a
timed-out run had left behind; the retake on a quiet box is the table
that follows this section.) Per allocation the hit path is 2.2× upstream
at one thread and 1.8× at four, and the four-thread number is not the
allocator's: 3.0 s of the 4.0 s
run is stop-the-world pause, 27 ms per collection, of which mark and sweep
are microseconds. That is the multi-mutator stop-the-world scanning whole
thread stacks, on upstream too (14 ms per collection there), and the next
thing to look at for execution-context throughput. With collections
disabled the four-thread cost grows with the heap (292 ns at 96 MB, 1 125 ns
at 960 MB) because `bitmap_take_pool_chunk` walks every chunk of the class
to find capacity — a per-class pool list would make that O(1); also
upstream's shape.

Retake on the quiet box (load average 1.2 → 1.5), same benchmark:

| build | 1 thread | 4 threads | pause total (1 / 4) |
|---|---|---|---|
| upstream `master` (fixed 32 MiB) | 47.6 ns | 977.8 ns | 20 ms / 114 ms |
| per-thread cursors, locked path pinned | 53.2 ns | 973.1 ns | 74 ms / 429 ms |
| withdrawn single-mutator version (a0ec7d7) | 51.8 ns | — | 75 ms / — |
| per-thread cursors | **32.5 ns** | **156.8 ns** | 78 ms / 425 ms |

The per-thread hit path is 1.5× upstream at one thread and 6.2× at four,
and faster than the withdrawn version it replaced. The four-thread pause
anatomy (45 collections, p50 3.7 ms): `phase_roots` 2.2 ms of it, stacks
0.1 ms, static 0.14 ms, mark 0.16 ms, sweep 6 µs, stop/start 0.07/0.1 ms —
the root phase under several mutators, and upstream's per-collection pause
is the same size, so that is an upstream cost to look at next for
execution-context throughput.

Kemal `/json`, headerless with per-thread cursors, quiet box (load average
2 at the end), Boehm interleaved, 9 rounds × 15 s:

| arm | req/s | vs Boehm | t | peak RSS | CPU ms / 10k req | faults / 1k req |
|---|---|---|---|---|---|---|
| Boehm | 48 688 | 100% | | 19.3 MB | 227 | 2.5 |
| headerless, per-thread cursors (defaults) | 49 570 | 101.8% | 0.77 | 22.6 MB | 201 | 5.0 |

Then the attribution run — the withdrawn single-mutator binary (a0ec7d7),
the per-thread cursors, and the per-thread cursors with `realloc` relying
on the conservative frame scan instead of the root list, all interleaved
with Boehm in the same rounds (9 × 15 s, load average 1.2 → 2.2):

| arm | req/s | vs Boehm | t | peak RSS | CPU ms / 10k req | faults / 1k req |
|---|---|---|---|---|---|---|
| Boehm | 48 893 | 100% | | 20.3 MB | 225 | 2.4 |
| headerless, per-thread cursors | 51 202 | **104.7%** | 1.63 | 22.5 MB | 196 | 4.9 |
| headerless, per-thread cursors, realloc without the root list | 51 317 | 105.0% | 1.84 | 22.6 MB | 195 | 4.8 |
| headerless, withdrawn single-mutator version | 51 040 | 104.4% | 1.99 | 22.6 MB | 196 | 4.9 |

The three gcry arms are one number: ownership costs nothing against the
flag it replaced, and the `realloc` change was noise (+0.3%), so it was
reverted. The 111.8% recorded above was the same code on a faster day of
this box (Boehm at 54 k then, 49 k now); the percentage a run reports is
only comparable within that run, which is why every table here carries
its own Boehm row. The honest headline for the branch is therefore
**about 5% past Boehm on throughput at 13% less CPU per request, on every
thread**, with peak RSS 2 MB above Boehm's.

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
