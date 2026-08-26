# A lock the collector takes inside the stopped world — shipped in 0.21.0

2026-08-26, Linux x86_64. **Closed.** A regression introduced the day before
the release and found the day after it.

## What it looks like

`bench/page_release_corruption.cr` children stop making progress. The gate uses
`Process.run` with no deadline, so the parent waits forever and the whole thing
reads as "slow" — which is how it went unnoticed, and how it cost two
measurements that were thrown away as machine noise before anyone looked at a
process.

A stuck child has six threads: **four in `rt_sigsuspend`** — parked in gcry's
suspend handler, so the world is stopped — and **two running**, with `utime`
climbing 1000 ticks in five seconds. Not slow. Spinning.

`GCRY_STW_WATCHDOG_MS=5000` names it, identically on every capture:

    gcry: STOP-THE-WORLD STALLED 5000 ms in phase=sweep — every mutator is
    frozen and the collector is not
    gcry: it is waiting on something a suspended thread holds

## The cause

`sweep` ends with `@chunks = kept`, and 0.21.0 put that store under
`@chunk_list_lock` **unconditionally**, with a comment arguing that "in the
stopped world nothing else can be here and the lock is free".

That argument is wrong. gcry stops the world by **signal**, not at safepoints,
so a mutator can be frozen anywhere — including inside `map_chunk` or
`unlink_chunk`, holding exactly that lock. The collector then spins on it while
every thread that could release it is suspended.

It needs the sweep to run **inside** STW rather than after it, which is what
`sweep_after_world?` decides. `GCRY_PAGE_DONTNEED=1` forces that (it sets
`madvise_free_pages`, and the lazy sweep is skipped when that is on), and so do
`GCRY_TLAB=1` and `GCRY_DISABLE_LAZY_SWEEP=1`. A default single-mutator build
sweeps after the world restarts and never reaches it: **0 of 40 with no knobs**.

## Measured

Children of `page_release_corruption`, `GCRY_PAGE_DONTNEED=1`, 90 s deadline,
arms interleaved child by child:

| Tree | hung | children |
|------|-----:|---------:|
| before the lock (`708ee7b`) | **0** | 40 |
| **v0.21.0** | **9** | 40 |
| v0.21.0 (earlier batches) | 3, 4, 5 | 40 each |
| with the fix | **0** | 40 |
| with the fix (earlier batch) | **0** | 40 |

v0.21.0 totals **21 hangs in 160 children**; the fix, **0 in 80**. Fisher exact
on the paired 40s is p ≈ 0.0009.

## The fix

Take the lock only on the `after_world` path. In the stopped world the store
needs no lock, because the mutators that could race it are the suspended ones;
the lock exists for the post-STW sweep, where they are running and a prepend
racing this store would be lost.

## The hang was hiding the defect the gate exists for

With the hang gone the same 40 children **crash 5 times** instead — on the
page-release corruption this gate was built to catch. Complementary rates, and
a hang with every mutator frozen is the worse of the two.

## A negative result worth keeping

The reason this was found at all was an attempt to close the page-release
window by taking the size-class freelist lock around the re-read and the
`madvise`. That does **not** work: with the lock in place the children still
crash 5 of 40. The window is not closed by serialising the release against the
allocator, so the next attempt should take the pages out of circulation —
unlink the free-only runs from the freelist under the lock, then madvise
outside it — rather than trying to hold the allocator still while the syscall
runs.
