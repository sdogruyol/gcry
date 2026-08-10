# The collector called libc with the world stopped, and hung

**Date:** 2026-08-10 · host: R9-9950X (16C/32T), WSL2, Crystal `c361ac6e7`,
`-Dgc_none -Dpreview_mt -Dexecution_context`, EC parallelism 4 · found on tip
@ `d36effe`, fixed the same day

Found while building `bench/scrub_midswap.cr`, whose flakiness was this bug.
It is **not** a scrub bug and it is **not** the acikturkiye SIGSEGV — it hangs,
it does not crash.

## Cause

`scan_other_thread_stacks` asked `pthread_getattr_np` for each thread's stack
bounds **after** STW had frozen those threads. That call:

- takes the *target* thread's descriptor lock, and
- for the main thread, glibc has no recorded `stackblock`, so it parses
  `/proc/self/maps` through stdio — which **mallocs**.

Either lock can be held by a thread the collector has just suspended. Then the
collector waits for it forever: no crash, no output, no diagnostic. Textbook —
a collector must not call into libc while the world is stopped.

## How it was located

By marker, after two wrong readings (below). The world stops fine; the hang is
inside one call:

```
DBG pass2 done, world stopped        <- suspension completes normally
DBG post-stw … static-done
DBG scan_other_thread_stacks begin
DBG about to getattr_np / returned   (thread 1)
DBG about to getattr_np / returned   (thread 2)
DBG about to getattr_np              (thread 3 — never returns)
```

## Fix

`Heap#stop_world` snapshots every thread's bounds under `Thread.lock`, before the
first suspend signal; the scan under STW does a table lookup
(`Platform.snapshotted_stack_bounds`, `src/gcry/platform/linux_stack.cr`).

- Same number of `pthread_getattr_np` calls per collection — they move out of the
  suspension window, so the `/proc` parse is no longer inside the pause. No pause
  number is claimed here; it was not measured.
- `Thread.lock` is already held across the snapshot and the scan, so the set
  snapshotted is exactly the set scanned.
- Entries are dropped every collection: a `pthread_t` can be reused after a
  thread exits, and a stale entry would hand the scan another thread's range.
- A lookup miss (thread list outgrows the 64 slots) costs the pthread-mapping
  half of that thread's root coverage, so it is counted rather than silent:
  `pthread_bounds_misses` on `/gc-stats`.
- Darwin needs none of this — `pthread_get_stackaddr_np` only reads the
  descriptor. The API is stubbed there so the scan stays platform-free, and the
  divergence is written down at both definition sites.

## Measurements

`bench/stw_startup_hang.cr` (`make stw-startup-hang`), N child processes, 6 s
ceiling each:

| child body | hung |
|------------|-----:|
| `resize(4)` + `GC.collect` | 0 of 200 |
| `resize(4)` + a fiber that never yields + `GC.collect` | **18 of 150 (12%)** |
| the same, **with the fix** | **0 of 500** |
| the same, fix reverted (both hunks) | **12 of 150 (8%)** |
| + `--scrub` | no additional effect |

The trigger is a fiber that holds a worker across the first collection: it keeps
another thread busy during the window where startup is still malloc-heavy, which
is what leaves a frozen thread inside the arena lock.

Reverting only the *scan* hunk and leaving the snapshot in place still passed
150/150 — because the snapshot warms glibc, so the call inside STW no longer
needs to allocate. That is not the guarantee; the guarantee is not calling libc
under STW at all. Recorded because it made a first break-gate attempt look green.

Independent confirmation: `bench/scrub_midswap.cr` needed a retry on ~8% of runs
before the fix and 0 of 15 after, with no change to that harness.

## Two wrong readings, kept

Both looked convincing and neither had anything to do with the cause.

1. **"`utime=0` means the thread has never been scheduled."** It means under one
   10 ms tick. That thread had already run `Thread#start` — which is provable
   from the same dump, because its `comm` was already set, and `Thread#start`
   sets the name after pushing itself to the thread list.
2. **"Two threads are named SYSMON, so the exemption is broken."** Linux gives a
   new thread its creator's name until it sets its own, so a worker spawned by the
   Monitor reports `comm=SYSMON`. `stw_signal_exempt?` reads Crystal's
   `Thread#@name`, not `comm`.

A third hypothesis — a stale pending `SIG_RESUME` making the next `sigsuspend`
return early — was killed by measurement: the hanging collection is the process's
**first**, with 0 prior collections, so no resume had ever been sent.

## Regression run after the fix

`crystal spec` 156/156 · `spec -Dgc_none process_spec` 13/13 ·
`stw-mt-property-test-short` PASS · `thread-storm-short` PASS · `fork-test` 3/3 ·
`stw-lag-pause` PASS (lag0 1.04×, sound 1.68×, default-path skip 5/5) ·
`scrub-midswap` 15/15 with no retries.

## Next

- **Audit the rest of the STW body for libc calls.** This was one instance of a
  class. `scan_static_roots` reaches `dl_iterate_phdr` (loader lock) — it is
  cached, and it did not hang here, but the same argument applies to it.
- **A hang under STW is currently silent.** The ack spin in `stop_world` and the
  phase sequence have no watchdog, which is why locating this took markers and a
  rebuild. A phase watchdog that prints "stopped for N s in phase X" would have
  made it minutes. Note that re-signalling is *not* the fix to reach for:
  `Thread#suspend` clears `@suspended` before signalling, so a re-signal can
  clobber an ack that was in flight and create the hang it is meant to break.
