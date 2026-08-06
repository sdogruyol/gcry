# EC4 STW lag split: which of the two knobs costs the 19×

Follow-up to `2026-08-06-085309-root-phase/`, which showed that the sound
profile's entire EC4 cost is `GCRY_STW_STACK_LAG=0 GCRY_STW_PTHREAD_LAG=0` and
moved both together. Same host, shape and instrument; 3 configs × 3 reps × 20 s.

| Config | roots µs | stacks µs | work µs | pause µs | Δpause |
|--------|---------:|----------:|--------:|---------:|-------:|
| tuned | 6413.7 | 303.6 | 6738.6 | 7249.4 | — |
| `GCRY_STW_STACK_LAG=0` | 136875.2 | 327.5 | 137204.5 | 137876.3 | **+1801.9%** |
| `GCRY_STW_PTHREAD_LAG=0` | 6593.8 | 4659.0 | 11360.8 | 11915.9 | **+64.4%** |

The two are additive (1802 + 64 ≈ the 1866 the pair produced together) and
both are real, but they act on different phases:

- **`stw_multi_stack_lag`** is the whole story — 19× pause on its own, entirely
  inside `roots_ns` (6.4 ms → 137 ms), `stacks_ns` untouched.
- **`stw_multi_pthread_lag`** is a genuine secondary cost at +64% pause, landing
  entirely in `stacks_ns` (304 µs → 4.7 ms), `roots_ns` flat.

Full interpretation and the defaults consequence live in the parent run's
FINDINGS. The one thing this split adds: the knobs are not two dials on one
mechanism, so making lag 0 affordable is two pieces of work, and
`stw_multi_stack_lag` is the one that matters.

**This split is also why the harness now reports `roots+scrub+stacks` and
Δpause rather than `roots+scrub`.** `pthread-lag-0` leaves `roots_ns` flat and
moves only `stacks_ns`; on the old basis it scored +2.8% and would have been
written off as free, when the pause it causes is 64% higher. The stored
`summary.json` for this run and its parent were recomputed on the corrected
basis (`work_basis` field records it).
