# The soak has never run more than one worker, including the arm labelled "EC4"

**Date:** 2026-09-16 · host: AMD Ryzen AI 9 465 (Zen 5, 20 threads), Linux 7.2.4
Tree `a861d20` (post-v0.26.0) · Crystal 1.21.0 · `bench/soak.cr`

The soak exists to catch one thing: the 2026-08-10 SEGV in `quick_dequeue?`, on a
run-queue slot whose pointer had been partly overwritten. That is a **cross-thread**
corruption. This file is the measurement that the harness had no second thread.

## What was measured

Crystal's default execution context is `Parallel`, but
`ExecutionContext.init_default_context` calls `Parallel.default(1)` — capacity
**1**. It grows only if the program calls `Parallel#resize`. `bench/soak.cr`
contains no `resize`, no `ExecutionContext`, no `CRYSTAL_WORKERS` and no
`EC_PARALLELISM`.

A probe built exactly the way the soak arms are built, spawning 256 fibers that
each yield four times:

| build | env | capacity | size | OS threads |
|---|---|---|---|---|
| `-Dgc_none` | — | **1** | 1 | 2 |
| `-Dgc_none` | `CRYSTAL_WORKERS=8` | **1** | 1 | 2 |
| `-Dgc_none -Dpreview_mt -Dexecution_context` | `EC_PARALLELISM=4` | **1** | 1 | 2 |

The third row is the configuration recorded as the **"EC4 + fiber churn"** arm in
`../2026-09-10-headerless-default-soak/FINDINGS.md`. It got one worker. Neither
env var can move it: `CRYSTAL_WORKERS` only feeds
`ExecutionContext.default_workers_count`, a helper for callers that resize, and
`EC_PARALLELISM` is this repo's own name for the argument
`bench/kemal/src/server.cr` passes to `resize` — which that file does call, so the
**Kemal** EC4 numbers and `bench/soft_soak_ec4.sh` are unaffected. This is a
`bench/soak.cr` defect only.

`bench/log/linux/2026-08-11-sysmon-runs-during-stw/FINDINGS.md` already recorded
that a plain `-Dgc_none` build "stays at 2 threads (worker + SYSMON)" and that
`default_workers_count` "is *not* used for the default context". What was missed
is that the soak therefore could not create the fault it was hunting, and that an
arm was later labelled EC4 anyway.

## `--workers=N`, and what it buys

`Fiber::ExecutionContext.default.resize(N)` before the first `spawn`, default
**1** — the baseline every earlier arm ran, kept so a comparison against any
recorded run stays a comparison. 90 s arms, `--fiber-churn=512`,
`GCRY_EC_QUEUE_AUDIT=1`, run sequentially:

| `--workers` | ec_parallelism | OS threads | collections | non-empty | slots walked | slots/collect | churn ops | stw_waits | faults | end RSS |
|---|---|---|---|---|---|---|---|---|---|---|
| **1** (baseline) | 1 | 2 | 88 | 80 (90.9%) | 6 088 | 69.2 | 15.34 M | **0** | 0 | 23 220 kB |
| **4** | 4 | 5 | 84 | 82 (97.6%) | 5 733 | 68.2 | 11.80 M | **1** (max 89.6 µs) | 0 | 26 256 kB |

- **Occupancy is not diluted.** This is the difference from `--collect-hz`, whose
  5 h arms bought ×14.6 collections for only ×2.56 slot walks because occupancy
  fell 24.2% → 3.4%. Four workers drain the queues four times faster *and* fill
  them four times faster: slots per collection is flat (69.2 → 68.2) and
  non-empty collections rise (90.9% → 97.6%).
- **The cross-worker STW interaction now exists at all.** `stw_waits` 0 → 1: the
  MonitorGate had to wait for a mutator. With one worker that number had nowhere
  to come from.
- **Cost:** workload throughput −23% on churn ops and −21% on allocations (this
  workload holds two mutexes, so four workers contend), RSS +13%.

Workers alone are not a substitute for churn. At `--workers=4 --fiber-churn=0`,
60 s: non-empty **1 of 59** collections, RSS +2 224 kB against the baseline
+4 096 kB ceiling — inside it, which is why no `--workers` RSS guard was added
(the churn guard already covers the arm that needs one). The two knobs are
complementary: churn fills the queues, workers make more than one thread touch
them.

## What this does not claim

**No fault was reproduced.** Both arms above are 0 faults, and two 90 s runs are
not a rate measurement. What changed is that the soak can now be pointed at the
creation side of the product at all, and that every future arm records what it
actually booted:

    config: … fiber_churn=512 collect_hz=1 workers_requested=4 ec_parallelism=4 os_threads=5

`ec_parallelism` is read from the context, not from the flag, for the reason the
`config:` line was added in the first place — a flag is a request, and the "EC4"
arm above is what a request that nothing honoured looks like six weeks later.

Whether one worker is *why* no soak fault has been reproduced since 2026-08-10 is
not settled here either. The 2026-08-10 run crashed, so a fault of this family
did occur on some configuration; what that run's parallelism was is not recorded
anywhere, which is itself the argument for the `config:` line.
