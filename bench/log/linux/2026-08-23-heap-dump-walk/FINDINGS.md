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

    6 of 6 failed

Two threads fault at once, eight bytes apart, in `update_heap_bounds_after_unmap`
(reached from a mutator's `trim_large_cache` -> `Heap#free`) and in
`revive_dormant_chunk`. Both of those walk `@chunks` holding `@alloc_lock`; the
releasing side did not hold it, so the lock excluded nothing.

**Not wired into `make`.** It is red, and a red target in CI is noise, not
evidence. Wire it when it passes.

## The attempt that was backed out

Not committed. The approach: give `@chunks` one discipline — every
release of chunk memory under `@alloc_lock`, plus a `@chunk_walkers` count for
the dumps, which cannot hold the lock because they allocate while they walk
(`each_chunk_guarded`). Releases that see a walker leave their chunks queued.

That took the dump race from 6 of 6 to 1 of 6, with the survivor now attributed:
a large-object release, written to 8 bytes into the chunk header.

It also took `make dormant-flush-race` from 0 of 6 to **2 of 6**, in the
null-`mmap` shape (`SIGSEGV at 0x18`) that means something stopped draining.
Trading a green gate for a partial fix is not a trade, so it was reverted rather
than committed. The cause of the drain regression was not found before backing
out — that is the first thing the next attempt has to explain.

## What the next attempt should know

- `with_alloc_lock` is `Crystal::SpinLock#sync` and returns the block's value,
  so `return if with_alloc_lock { ... }` is sound. That was suspected and
  cleared.
- The lock is a spinlock on purpose: `tlab.cr` records that a `pthread_mutex`
  deadlocks against STW suspend-while-holding. Holding it across `munmap` and
  `madvise` runs is therefore a real cost, and aarch64 CI is where that would
  show first.
- `relink_chunks_after_world?` is `!multi_mutator_threads?`, so the lazy relink
  of `@chunks` is not what a multi-threaded gate hits.
