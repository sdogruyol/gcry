# The aarch64 `pthread_getattr_np` SEGV: 0 in 511 runs since the birth root

**Date:** 2026-09-26 · source: GitHub Actions history of the CI workflow,
2026-08-18 → 2026-09-26

## Question

Two ROADMAP items are open on one CI signature: a SIGSEGV inside
`pthread_getattr_np` under `stop_world`, faulting on gcry's own freed-block
poison (`0xdeadff…`) — a `Thread`'s `@system_handle` read out of a freed
block. It was last *written up* on 2026-08-17. Has it been seen since?

## Method

Every CI run created since 2026-08-18 (537), every completed aarch64 job in
them (2 562), and for each of the 32 that failed, the job log searched for
`pthread_getattr_np` together with `SIGSEGV` / `Invalid memory access`.
Each hit read by hand.

## Result

Six sightings, all the real signature — `gcry: SIGSEGV at 0xdeadff… — gcry's
freed-block poison is in the faulting context`, top frame
`pthread_getattr_np +84` — all in `test (aarch64 native)`:

| run | created (UTC) | commit |
|---|---|---|
| 32099490744 | 2026-08-18 04:32 | 7a7dd05 |
| 32334070200 | 2026-08-20 05:02 | 4c78d6c |
| 32335707948 | 2026-08-20 05:28 | 23c5681 |
| 32335710766 | 2026-08-20 05:28 | 23c5681 |
| 32336570626 | 2026-08-20 05:41 | 51d817d |
| 32336573288 | 2026-08-20 05:41 | 51d817d |

`10289b3` — "root the Thread object until it publishes itself", the birth
root (`src/gcry/thread_birth_root.cr`) — landed at 06:45 UTC the same morning.

| window | CI runs | sightings |
|---|---:|---:|
| 2026-08-18 → 2026-08-20 06:00 | 26 | 6 |
| 2026-08-20 06:00 → 2026-09-26 | **511** | **0** |

One-sided Fisher exact p = 7·10⁻⁹. Even at a 1%-per-run rate — well below the
rate it showed — 511 quiet runs happen with probability 0.006.

## What this does and does not close

It closes the *observed* defect: the poisoned-handle read inside
`pthread_getattr_np`, on the platform and in the job it was seen on. It does
not prove the mechanism the birth root was built on (the ROADMAP's own
"still an inference"), and it says nothing about the theoretical windows the
unheard-thread item keeps open — a dying thread between `Thread.threads.delete`
and `detach`, the interval inside `pthread_create`. Those stay open there.
