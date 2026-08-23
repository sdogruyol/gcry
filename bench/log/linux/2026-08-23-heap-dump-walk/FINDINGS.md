# The debug dumps walk the chunk list with the world running

2026-08-23, Linux x86_64. **Open.** Proven, not fixed.

## The defect

`Gcry.dump_heap`, `Gcry.dump_heap_addresses` and `Gcry.live_attr_json` are
documented API (`docs/API.md`). All three walk `@chunks` from the calling
thread, holding nothing, dereferencing every chunk header and then every block
inside it. The collector unmaps chunks from `flush_pending_empty_chunks`,
`flush_pending_large_release` and `trim_large_cache` — all outside STW, all
while that walk is in progress.

`unlink_chunk` leaves the removed chunk's `next` intact, so being off `@chunks`
does not put a chunk out of reach: a walker standing on one keeps following it,
and then it is unmapped underneath.

It does not need a second thread either. The walks allocate as they go — a Hash
insert per type id in `json_live_attr`, a String per line in `dump_heap` — and
that allocation can trigger a collection on the walking thread itself.

## The gate

`bench/heap_dump_race.cr`. Three workers churning size classes and 40 KiB large
blocks, one thread dumping in a loop, 20 000 live objects of ballast.

    14 of 16 failed  (GCRY_MOSTLY_EMPTY=0, so only this defect is in play)

Two threads fault at once, eight bytes apart, in `update_heap_bounds_after_unmap`
(reached from a mutator's `trim_large_cache` -> `Heap#free`) and in
`revive_dormant_chunk`. Both of those walk `@chunks` holding `@alloc_lock`; the
releasing side did not hold it, so the lock excluded nothing.

**Not wired into `make`.** It is red, and a red target in CI is noise, not
evidence. Wire it when it passes.

## The attempt, and two readings that were wrong

The approach: give `@chunks` one discipline — every release of chunk memory
under `@alloc_lock`, plus a `@chunk_walkers` count for the dumps, which cannot
hold the lock because they allocate while they walk (`each_chunk_guarded`).
Releases that see a walker leave their chunks queued.

It was first read as 6 of 6 -> 1 of 6, and rejected anyway because it looked
like it regressed `make dormant-flush-race` from 0 of 6 to 2 of 6. Both readings
were six-attempt readings, and both were wrong.

**The regression was not a regression.** Over 24 attempts:

    dormant-flush-race, GCRY_MOSTLY_EMPTY=1
      green (HEAD)   3 of 24
      patched        2 of 24

Indistinguishable. HEAD already fails that workload at about 12 %, for an
unrelated reason (`../2026-08-23-mostly-empty-corruption/`).

**The fix was not a fix.** With the mostly-empty walk out of the way so only
this defect is in play, over 16 attempts:

    heap_dump_race, GCRY_MOSTLY_EMPTY=0
      green (HEAD)   14 of 16
      patched        11 of 16

88 % against 69 % on sixteen samples is not evidence of anything. The earlier
"1 of 6" was luck. The patch was reverted — not for the regression it did not
cause, but because it does not demonstrably fix what it was written for.

## What the next attempt should know

- Six attempts cannot separate 0 % from 12 %, and sixteen cannot separate 69 %
  from 88 %. Size the run to the effect before reading anything into it.
- `GCRY_MOSTLY_EMPTY=0` isolates this defect from the mostly-empty one. Without
  that split, the two are read as one.
- `with_alloc_lock` is `Crystal::SpinLock#sync` and returns the block's value,
  so `return if with_alloc_lock { ... }` is sound. Suspected and cleared.
- The lock is a spinlock on purpose: `tlab.cr` records that a `pthread_mutex`
  deadlocks against STW suspend-while-holding. Holding it across `munmap` and
  `madvise` runs is a real cost, and aarch64 CI is where it would show first.
- `relink_chunks_after_world?` is `!multi_mutator_threads?`, so the lazy relink
  of `@chunks` is not what a multi-threaded gate hits.
- `make dormant-flush-race` is in the Makefile but **not** wired into CI. None
  of today's new gates are.
