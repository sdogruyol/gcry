# The soak gave the queue audit nothing to look at

**Date:** 2026-08-15 · host: WSL2 x86_64, 20 CPU, Crystal 1.21.0 (`57cf7da50`),
`-Dgc_none` · tip @ `77187de`

The queue audit landed the same day and its own findings closed on an admission:
the soak's `queue_slots` read 0–1 per collection, so the instrument had almost
nothing to inspect. This measures that properly, fixes it with an opt-in knob,
and takes the other handle the board named — more arms, concurrently.

## How often is a run queue non-empty when the world stops?

That number bounds everything the audit can ever catch: a corrupt slot is only
seen if a collection lands while the slot is inside `head..tail`. Measured over
25 s runs, counted at the soak's own 1 Hz collections (not sampled from the
telemetry loop, which reads whichever collection happened to be last):

| `--fiber-churn` | slots total | max per collect | collections non-empty |
|---|---|---|---|
| 0 (baseline) | 2 | 2 | **1 / 24** |
| 32 | 200 | 32 | 9 / 24 |
| 128 | 537 | 128 | 7 / 24 |
| 512 | 2486 | 508 | **23 / 24** |

The baseline workload spawns at ~10 Hz against ~1 collection/s, and each fiber
returns immediately, so the ring is empty almost every time the world stops. One
collection in twenty-four could have caught anything at all.

`--fiber-churn=N` spawns N fibers per 1 ms burst, each of which yields four times
and exits. Four, not one: a fiber that returns immediately is drained by a worker
in microseconds and the ring is empty again before any collection can see it;
yielding puts it back on the queue, so a burst holds depth for as long as it
takes to round-robin. Nothing else about the workload changes, and the default is
**0** — the baseline every earlier soak ran on, and the one the open 2026-08-10
SEGV is measured against.

## What the audit costs once there is something to walk

Pause p50 at `--fiber-churn=512`, n=3 per arm, ~500 slots walked per collection:

| audit | p50 |
|---|---|
| on | 8.41 / 8.34 / 8.77 ms |
| off | 8.29 / 8.58 / 8.67 ms |

Overlapping. The walk is a few hundred pointer validations against an 8 ms
pause, so this is what it should look like — but it was worth measuring at
occupancy rather than at the zero-occupancy baseline, where "no cost" would have
meant "no work". Default stays **off**: the measurement says the cost is below
the noise floor on this workload, not that it is free on a Kemal-class pause of
3.6 ms with four busy rings.

## Churn breaks the RSS gate, so the run refuses rather than fails

`--fiber-churn=512` for 25 s moved RSS **+44.7 MB** (7.1 → 51.8 MB): 6.2 M fibers
spawned, and the stack pool holds their stacks. The soak's ceiling is +4 MB, so a
churn arm would fail on a bound nobody chose, for a reason unrelated to what it
was run to find. `--fiber-churn=N` with `--rss-limit-kb` at or below the default
now exits 64 with that number in the message — the same call
`--rss-limit` → `--rss-limit-kb` already made in this file.

## Three arms, concurrently

The CI soak is now a `fail-fast: false` matrix of three arms. One 5 h arm a week
cannot chase a crash that took 1h24m to arrive; three tripled the sample rate for
the same wall clock, and `fail-fast: false` is the substance rather than a
detail — an arm that crashes must not cancel the two that might have crashed
differently. Telemetry uploads per arm (`soak-telemetry-arm-N`).

`workflow_dispatch` gained `fiber_churn` and `soak_rss_limit_kb`, both defaulting
to the baseline, so a scheduled run stays comparable to every earlier one and a
hunting run is one dialog away.

## Still open

No fault has been reproduced. Nothing here explains the 2026-08-10 SEGV — it
raises the rate at which a run could catch it (1/24 collections → 23/24, ×3
arms) and shortens the report from "an hour later, in the consumer" to "the next
collection". Whether that is enough is the next scheduled run's answer.
