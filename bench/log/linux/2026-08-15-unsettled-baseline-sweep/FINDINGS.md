# Looking for the same defect everywhere else, and not finding it

**Date:** 2026-08-15 · host: WSL2 x86_64 **idle**, Crystal 1.22.0-dev

Three separate things went wrong the same way today:

- `process_spec/regression/1_live_objects_dormant_spec.cr` asserted a bound on a
  drift that included the first collection's cleanup of ambient garbage — red on
  aarch64 and Darwin at 1005, ≤4 on x86_64.
- `bench/scheduler_roots.cr` baselined `ec_root_pins` on the first collection,
  which sometimes reads 23 where every later one reads 25 — red three times, and
  silently discounting the hold arm's threshold by 2 the rest of the time.
- The Darwin soak smoke asserted a ceiling nobody had measured on Darwin.

One shape: **a threshold measured against a quantity that has not settled.** It
is worth knowing whether there is a fourth, so this is the search.

## Method

Two passes, because the first one was not sensitive enough.

**Symptom pass.** Every gate that runs locally, looped: `greg-roots`,
`ivar-layout-roots`, `poison-freed`, `segv-report` (12 each),
`ec-queue-audit`, `scheduler-roots` (15 each), `soak-smoke` (6). **All clean.**
That is weaker evidence than it looks: `scheduler-roots` was 1-in-25 here before
the fix, so 12 runs would have missed it about 60% of the time.

**Mechanism pass.** The seven counters those gates assert on, read into plain
locals immediately after the first collection and again after six more, 60 runs.
The first version of this probe built a metrics struct and a `Hash` before
reading, and caught nothing in 30 runs — its own warm-up was settling the thing
it was trying to observe. The lean version:

```
59  settled
 1  MOVED ec_root_pins 23->25
```

## Result

| counter | asserted on by | settled at collection #1? |
|---|---|---|
| `ec_root_pins` | `scheduler_roots` | **no** — 1 run in 60 |
| `ec_root_unpinned_ivars` | `scheduler_roots` | yes, 60/60 |
| `thread_greg_candidates` | `greg_roots` | yes, 60/60 |
| `ec_queue_audit_faults` | `ec_queue_audit` | yes, 60/60 |
| `ec_queue_audit_ring_slots` | `ec_queue_audit` | yes, 60/60 |
| `ec_queue_audit_list_slots` | `ec_queue_audit` | yes, 60/60 |
| `poisoned_blocks` | `poison_freed` | yes, 60/60 |

**The only unsettled counter among them is the one already fixed.** Two others
move at the first collection and are *not* asserted on, so they are noted rather
than changed:

- `layout_precise_scans` — 2 at collection #1, 5 settled, in **30 of 30** runs.
  Deterministic, not a race. `bench/ivar_layout_roots.cr` only `puts` it.
- `live_objects` — moves in every run; this is the drift the regression spec now
  collects past before taking its baseline.

## What this does not settle

- **Sensitivity is 1-in-60.** A rarer instance survives this sweep. The number
  bounds the search; it does not close it.
- **x86_64 only.** Every instance of this defect found today was *more frequent*
  on Darwin and aarch64 than here — `ec_root_pins` went red three times there and
  never once in CI on x86_64. A counter that reads settled in 60 runs on this
  host is not thereby settled on those.
- **Only counters the gates assert on** were swept. A gate that asserts on
  something not in the table above is not covered by it.
