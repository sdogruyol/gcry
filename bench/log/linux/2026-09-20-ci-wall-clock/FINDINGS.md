# The x86_64 job doubled in twelve days and was walking into its cap again

2026-09-20. GitHub Actions history for `test (x86_64, crystal 1.21.0)`, the
199 jobs of the 200 most recent CI runs, 2026-09-08 → 2026-09-20.

## Why this was looked at

`ci.yml` carries this comment on that job's `timeout-minutes: 45`:

> This job takes ~30 minutes, and the comment here claimed ~7 until
> 2026-09-15, when the cap it was attached to started cancelling green runs:
> 29m44s passing, then 30m05s killed on the last step with 17 s of work left.
> The gate list had grown into the cap.

It has grown again.

## The measurement

    successful jobs   166
    min  11.4 min     p50 25.7     p90 31.6     max 33.1
    cap  45 min

| date | duration |
|---|---|
| 2026-09-08 | 15.1 – 16.1 min |
| 2026-09-20 | 32.0 – 33.1 min |

**2.1× in twelve days**, or about +1.4 min a day. At that rate the cap is
reached in roughly nine more days, and the failure it produces is a *green*
tree reported red on its last step — the least legible kind.

## Where it came from

Diffing a 2026-09-08 job against a 2026-09-20 one, step by step:

    old   16.0 min over  78 steps
    new   33.0 min over 104 steps

    steps that did not exist then : 31, worth 17.1 min
    existing steps that grew >20s :  0, worth  0.0 min

So the growth is **purely additive** and nothing regressed. That is the shape
that walks into a cap without anyone noticing: every individual addition is
cheap and justified, and the sum is not visible from any one pull request.

The ten most expensive additions:

    6.6 min  Live-object release under thread churn
    1.6 min  Chunk-list divergence stays rare
    1.6 min  STW stop epoch
    1.3 min  Windows type-check (cross-compile)
    1.2 min  Marks in the chunk with the freelist allocator
    1.0 min  Heap counters agree with the walk
    0.9 min  Refill indexing stays per version
    0.5 min  STW capture slot precision
    0.3 min  The index-lock wedge stays unreachable
    0.3 min  Unit specs (header layout, freelist)

The distribution is long-tailed: the top step is 20% of the job and the other
103 share the rest, most of them a `crystal build` plus a run of a few
seconds. There is no fat to trim — the cost is the gate list, which is the
point of it.

## What changed

Raising the cap was the other option and it is the wrong one: it buys days,
and the thing the cap exists for — a hang failing in minutes rather than at
GitHub's 6 h ceiling — gets weaker every time. Splitting costs nothing real,
because runner minutes are the same work either way and only the wall clock
moves.

The four heaviest **sampling** gates moved to a new `sampling gates (x86_64)`
job. They are a real category rather than an arbitrary cut: each drives a rare
window many times over, so its cost is the sample size and not the assertion.

| | before | after |
|---|---|---|
| `test (x86_64)` | 33.0 min | ~20.7 min |
| `sampling gates (x86_64)` | — | ~13.5 min |

Every moved step is a bare `make` target that builds what it runs, so none of
them depended on anything the other job had done — checked before moving, and
all four re-run standalone here:

    chunk-list-drift   28 s   ok — shipped 0.0 per 1000 mappings (cap 5.0) …
    find-block-race    32 s   ok — a mutator inside `find_block` survives 200 …
    stw-epoch          64 s   ok
    stw-ack-window     13 s   ok
    thread-churn-uaf   88 s   ok — with the pre-fix shape restored the defect
                                   still reproduces

## What this does not fix

Nothing stops the same drift from happening to either job. The headroom is
back to roughly 2× on both, which buys months rather than days at the current
rate, and the re-derivation is one API query:

    gh api repos/sdogruyol/gcry/actions/runs/<id>/jobs

with each step's `started_at` / `completed_at`. Recorded here so the next
person measures rather than raises the cap.
