# "prose claims of a hand break: 19 (nothing re-checks these)" was three claims in a trenchcoat

**Date:** 2026-09-22 · `python3 bench/gate_arm_census.py`

The census's last line counted every ROADMAP sentence saying a gate was
*"broken on purpose"* or *"observed red"* and declared that nothing
re-checks them. That was true when it was written and stopped being true
as the arms were built — but the line kept printing the same number, so
the one statistic this file exists to keep honest was itself stale.

Classified instead of counted:

| | |
|---|---|
| total claims | **14** (19 was counting *occurrences*; a line with both phrases counted twice) |
| name a gate that now builds its red arm every run | **6** |
| name a script gate the census cannot judge (`ci/*.py`, no bench harness — still runs and still fails the build) | **1** |
| rest on a `process_spec` assertion that runs on every push | **6** |
| rest on nothing | **1** |

The one is line 56: the `Current` section's opening paragraph,
describing v0.19.0's history — *"a counter was wired to a gate and the
gate was broken on purpose"*. It is narrative about a closed item, not a
claim about a live gate, and it is correctly reported as backed by
nothing.

Two bugs found in writing the classifier, both of the kind that makes an
instrument flatter itself:

- **Wrapped gate names.** The context regex wanted `make <name>` with a
  single space; ROADMAP wraps at 78 columns, so a claim naming
  `` `make\n      raw-buf-check` `` went into the unbacked pile for the
  width of the column it was typed in.
- **Script gates had no bucket.** `raw-buf-check` has no bench harness,
  so the census has no row for it and the claim naming it read as
  unbacked — while that gate runs on every push and fails the build.

`--list` prints the line numbers of the unbacked, so the next one is a
place in the file rather than a number to argue with.
