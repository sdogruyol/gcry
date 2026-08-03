# Finalizer registry fix (acik RSS)

**Date:** 2026-08-03 · **Host:** WSL2 Ryzen 9 9950X · **App:** acikturkiye `/api/v1/`

## Root cause

Finalizer `Entry` / disappearing-link tables lived in Crystal `Array`s on the
gcry heap. `mark_metadata_roots` marked the array buffer → every
`Entry.object` stayed reachable forever → finalizers never ran → dead
`TCPSocket` / `OpenSSL::Digest` + 32 KiB `IO::Buffered` atomics retained.

Parent/watch probes (`…/acik-parents/`, `…/acik-watch-tcp/`, idle-drain) were
symptoms of this leak, not JWT keep-alive or PG pool sizing.

## Fix

1. **LibC registry** (`src/gcry/finalizer.cr`) — tables outside the GC heap;
   mark only callback `closure_data`.
2. **MT quiesce** — SpinLock on mutator add/notice_reclaim; held across
   `stop_world` (same pattern as `@roots_lock`).
3. **Boehm resurrect** — enqueue unmarked finalizables, then mark +
   `mark_loop` before sweep so `#finalize` does not run on freed memory.
   Next collect reclaims if still unreachable.

Without (3), wrk auto-GC SEGVd in `Socket#finalize` / `OpenSSL::Digest#finalize`
via `run_pending` (~90 rps then crash). Mutex alone did not help.

## Gate sample (`resurrect/`, PRECISE_STACK unset, 20s wrk -c100)

| Metric | Before (idle-drain / leak) | After fix |
|--------|---------------------------:|----------:|
| post-GC live | ~80–100 MiB (atomics) | **15.7 MiB** |
| max atomic size-class | ~80 MiB | **4.7 MiB** |
| `finalizer_entries` | ≈ n(TCPSocket)+n(Digest) sticky | **151** |
| collections under load | (blocked by leak) | **32** majors |
| server | — | **SURVIVED** |

`top_type_id` 1 dominates typed bytes (String-ish); no TCPSocket/Digest flood.

## Harness

`bench/acik_live_attr.sh` preserves `GCRY_THRESHOLD` across GCRY_* scrub.

## Do not claim

- exclusivef / `PRECISE_FIBERS` / AUTO_LAYOUTS / nursery / PAGE_DONTNEED as the RSS lever
- Boehm × ratio until a same-host Boehm med3 re-run
