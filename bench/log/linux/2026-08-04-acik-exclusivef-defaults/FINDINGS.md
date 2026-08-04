# exclusive / exclusivef under Linux retain=0 defaults

**Date:** 2026-08-04 · tip+EC stackmap bins · WSL2 9950X  
**Method:** `acik_stackmap_ab.sh`, `VARIANTS="boehm exclusive exclusivef"`, dual `/gc-collect`.  
**Defaults:** no ambient `GCRY_*` — Linux process retain=0 (`9228bb9`).  
**Harness:** `GCRY_COLLECT_TIMEOUT=45` (bare curl was wedging the session).

## Smoke (15s × 1) — clean

Session: `…/2026-08-04-acik-exclusivef-defaults-smoke/`

| variant | thr | % Boehm | RSS KiB | × |
|---------|----:|--------:|--------:|--:|
| boehm | 120.1 | 100% | 53824 | 1.00× |
| exclusive | 110.1 | **91.7%** | 62824 | **1.17×** |
| exclusivef | 106.1 | **88.4%** | 94744 | **1.76×** |

No SEGV, no collect hang. exclusivef `fp_fill` path alive (marked=203).

## Med-of-3 (30s) — flaky

Session: this directory.

| variant | t1 | t2 | t3 |
|---------|----|----|-----|
| boehm | 132 rps / 61 MiB | 140 / 45 MiB | 131 / 45 MiB |
| exclusive | **Non-2xx=1** (ThreadPool `pthread_cond_wait` crash) | wrk OK → **COLLECT_HANG >45s** | 122 rps / 70 MiB / marked=3529 |
| exclusivef | **125 rps / 54 MiB** (marked=177, fp_fill 48 frames / ~10 KiB) | **Non-2xx=1** (same ThreadPool crash) | **Non-2xx=1** (same) |

Boehm med: **132 rps**, RSS **~45 MiB**.  
Only clean exclusive RSS trial: **~1.57×**. Only clean exclusivef: **~1.21×**.

### exclusive collect hang

Reproduced: wrk finishes (~80–120 rps), process stays up (`futex_do_wait`),
HTTP dead — first `/gc-collect` never returns. Earlier orphaned t1 from the
interrupted cut showed the same shape. Not a harness bug; STW / stop-the-world
handshake under `PRECISE_STACK=2` can wedge. Timeout + kill is required.

### exclusivef crashes

Not the old instant UAF-on-start. Mid-wrk: `Fiber::ExecutionContext::ThreadPool#enter_thread_loop`
→ `pthread_cond_wait: Invalid argument` after heap damage (read/write socket
storm in wrk). 2/3 med3 trials. Surviving trial shows **fp_fill ~10 KiB**
(was ~0.57 MiB pre-finalizer) — false-root pressure down with retain=0 +
finalizer fix, but correctness still fails the gate.

## Verdict

1. **Do not promote** exclusivef or exclusive as product defaults.
2. Stable acik path remains tip+EC **without** `PRECISE_STACK` / `PRECISE_FIBERS`
   (~90% thr @ ~1× RSS after finalizer + retain=0).
3. exclusivef is **less wrong on RSS when it lives**, still **unsafe** under
   30s wrk (2/3 crash). exclusive adds **collect hang** risk.
4. Harness now bounds `/gc-collect` (`GCRY_COLLECT_TIMEOUT`, default 45s) and
   records hangs as `non2xx=-2`.

## Next

- exclusive STW hang: trace stop-the-world waiters under `=2` (optional;
  research-only).
- exclusivef: still needs denser/correct parked lives before FP-fill can shrink
  further — not an RSS campaign lever on Linux tip anymore.
