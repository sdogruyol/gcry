# `GCRY_DISABLE_SCRUB_FIBERS` was an orphan, and `sound_profile` could not see it

2026-09-20, this host (x86_64, Linux, Crystal 1.21.0), `-Dgc_none`,
headerless default.

The orphan-knob census (`../2026-09-16-orphan-break-knobs/`) left
`GCRY_DISABLE_SCRUB_FIBERS` among the knobs `src/` reads and no spec, recipe
or CI step exercises. `samples/sound_profile.cr` already asserts the flag
under `GCRY_SCRUB_FIBERS=1`, which looks like coverage. It is not.

## Why that sample cannot see the knob

The sample asserts default-off, and that `GCRY_SCRUB_FIBERS=1` overrides
`GCRY_SOUND`. `GCRY_DISABLE_SCRUB_FIBERS=1` agrees with the default, so the
sample never asks whether the disable still turns the opt-in back off.
`spec/stack_scrub_spec.cr` sets `heap.scrub_fibers_enabled` as a property
and never reads either env var. A survival assertion would not discriminate
anyway: the parked-fiber wipe is a false-retention heuristic, not a root.

## Measured

`bench/scrub_fibers.cr`, three child arms of one process, same binary.
Each child parks eight fibers on a channel and `GC.collect`s once.

| arm | knobs | `scrub_fibers_enabled` | `fiber_scrub_runs` |
|---|---|---|---|
| default | (none) | **false** | **0** |
| on | `GCRY_SCRUB_FIBERS=1` | **true** | **1** |
| disabled | both | **false** | **0** |

`fiber_scrub_runs` is how many times `scrub_parked_fiber_stacks` ran, not
how many bytes it wiped. The function increments the counter after the
walk even if every parked fiber was skipped, so a zero with the flag on
is "collect never entered the wipe", not "nothing to wipe". That is the
second counter: a flag that is true while the collect path never calls
the function is not the opt-in doing what `docs/HARDENING.md` says.

## Red direction, observed

The disabled arm's env with `GCRY_DISABLE_SCRUB_FIBERS` dropped, same
binary, same assertions:

    FAIL: disabled: … scrub_fibers_enabled=true — the knob no longer turns the opt-in back off
    FAIL: disabled: … fiber_scrub_runs=1 — the wipe still ran

Both counters, both red. Restored, the gate exits 0 again.

## What this does not claim

It does not say parked-fiber scrub is load-bearing for a root. It is
opt-in because nothing measured kept the default alive
(`docs/SOUND-DEFAULTS.md`). This gate asserts that the opt-in *runs*
what it claims and that the disable *undoes* it. Rot of either is a knob
that silently does nothing, which is this census item's disease.

The remaining orphans `GCRY_POOLED_STACK_NOROOT`,
`GCRY_MAPS_INFLIGHT_NOROOT`, `GCRY_BIRTH_GRACE_NOROOT` are default-off
research paths. Their rot is not production soundness; they are not called
root loss here.

Census after this gate: **99 / 34 per run / 65 by hand** (was 98 / 33 / 65).
