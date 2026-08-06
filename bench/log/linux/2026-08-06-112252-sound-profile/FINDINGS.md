# The throughput channel was broken by a clock bug, not by the host

Host: AMD Ryzen 9 9950X (16C/32T), WSL2, Crystal 1.21.0, `--release`, EC1.
Kemal `/json`, `wrk -c100 -d10`, 7 runs per config, min/max discarded.

This is the first cut taken after `bench/sound_profile_ab.sh` stopped trusting
wrk's own `Requests/sec`. It supersedes the reasoning — not yet the numbers —
in `2026-08-06-081512-root-phase/FINDINGS.md`, which concluded the throughput
channel was unusable on this host class.

## The bug

**WSL2 steps `CLOCK_REALTIME` backwards by ~1.6 s roughly every 32 s**,
syncing the guest to the Windows host. Measured directly:

```
60 s window: realtime advanced 56.823 s, monotonic 60.045 s (drift -3.222 s)
  discrete steps: t=21.4 s  -1.6025 s
                  t=53.6 s  -1.6192 s
```

wrk derives its duration from that clock. A 10 s pass containing a step divides
its request count by ~8.4 s instead of ~10 and reports **~19% high**. Caught in
the act — the same pass measured three ways:

| | wrk's duration | CLOCK_REALTIME | CLOCK_MONOTONIC |
|---|---:|---:|---:|
| unaffected pass | 10.02 s | 10.05 s | 10.03 s |
| stepped pass | **8.48 s** | 8.49 s | **10.10 s** |

A 10 s pass has roughly a 1-in-3 chance of containing a step, which matches the
observed hit rate (2 of 8, then 8 of 22 in the runs below).

**This biases rather than merely widens.** Which config gets hit is random, so
one config's median can be inflated ~19% while another's is not. That is
exactly how a configuration doing strictly more work ends up "ahead" — the
impossibility that invalidated session 2 (`…-052109-sound-profile/`) and forced
the ~1pp retraction now has a mechanism.

## The fix

`timed_wrk` measures the interval with `CLOCK_MONOTONIC`, takes wrk's request
*count* (which no clock can distort), computes the rate itself, and redoes any
pass where the two clocks disagree by more than 1%. Three consecutive stepped
passes abort the run rather than silently reporting.

## Result

| Config | req/s | % of Boehm | RSS × | pause p50 | spread |
|--------|------:|-----------:|------:|----------:|-------:|
| Boehm | 41102 | — | — | — | 4.76% |
| gcry tuned | 33110 | **80.6%** | 0.56× | 0.48 ms | 7.23% |
| gcry sound roots | 32390 | **78.8%** | 0.53× | 0.52 ms | 4.42% |

Two things that had never both held before:

1. **`sound` is below `tuned`** (−2.18%) — the physically correct direction,
   since sound does strictly more work. Every prior cut had it above.
2. **`tuned` lands at 80.6%**, inside this box's historical 80.0–85.0% band, so
   the handover's §5 sanity gate passes.

## What this does and does not establish

It does **not** establish that the sound profile costs 2.18% of throughput. The
gap is smaller than the per-config spread (4.4–7.2%), so with 7 runs it is a
candidate, not a result.

What it does establish is that the channel is **usable**, and that the earlier
"unresolvable on this host class" conclusion was substantially an instrument
defect rather than a property of the host. The proper cut — 9 runs at 30 s, the
`docs/PERF.md` methodology — is now worth running and was not before.

Note the 30 s question this raises: a 30 s pass will almost always contain a
step, so the redo loop may thrash. If it does, the fix is to subtract stepped
intervals rather than redo whole passes, or to shorten passes and take more of
them.

The residual spread is still unattributed. Candidates not ruled out: the
9950X's two CCDs (a single-threaded server migrating between them crosses an L3
boundary), boost behaviour, and Windows-side activity invisible from the guest.

## Unaffected

Every pause-composition result stands. The collector timestamps its phases with
`monotonic_ns`, so the EC4 (141.7 ms) and acik (213 ms) findings and the whole
per-knob decomposition never touched the stepping clock.
