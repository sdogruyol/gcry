# EC4 post-STW Parallel munmap (excess empties) — REJECT

Tip: lazy gate **78.8%** `/json`; dormant+lazy opt-in **75.1%** @ ~55k
(retain 32). Goal: shrink `@chunks` walk by munmapping excess empties
under lazy (dormant alone does not — freelist revive churn).
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever (reverted)

1. Allow `sweep_after_world?` with `GCRY_PARALLEL_RELEASE=1`.
2. Mark excess empties `PENDING_UNMAP`, unlink freelist under class lock,
   flush unlink+munmap under all freelist locks + `@alloc_lock`.
3. Avoid GC `Array` for pending list (inline `StaticArray`) — `Array#clear`
   SEGV'd after munmap when the buffer lived in an unmapped chunk.

## Soft soak (retain 32 MiB, `wrk -c100 -d8`)

| OK | soft | thr med | pause p50 | Notes |
|---:|-----:|--------:|----------:|-------|
| **abort** | 0 | **~31.6k** (n=4) | ~11.5 ms | run 5 SEGV @ `0x4`; earlier smokes SEGV in `Array#clear` |

Quiet thr not completed (thr already ≪ 78.8% / 75.1% bars).

## Lessons

- Post-STW munmap cannot park pending targets in a **GC-managed** buffer.
- Even after StaticArray fix: intermittent SEGV + thr cliff (~17–32k vs
  ~69k lazy / ~55k dormant). Holding all freelist locks across munmap
  serializes mutators; mmap/munmap churn dominates.
- Removing chunks from the walk still needs a design that does not
  munmap while the world runs (or accepts in-STW munmap pause).

## Verdict

**REJECT** (code reverted). Keep dormant+lazy opt-in; `PARALLEL_RELEASE`
again forces in-STW sweep. Stretch ~80% / walk-cut still open.
