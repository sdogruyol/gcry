# Sound-roots profile — acikturkiye (fat app) cut

**Verdict: INCONCLUSIVE at N=3.** The measurement is not powered to separate
tuned from sound on this workload/host. Recorded so the next attempt starts
from a known noise floor rather than repeating it.

Host: WSL2 x86_64 (i3-12100F), Crystal 1.21.0, `--release`, EC parallelism 1.
`wrk -c 100 -d 20` on `/api/v1/`, `TRIALS=3` median, `bench/run_all.sh acik`.
Two sessions, Boehm re-measured in each:

- tuned: `bench/log/linux/2026-08-06-043527/`
- sound: `bench/log/linux/2026-08-06-044017/` (`GCRY_FLAGS="GCRY_SOUND=1"`)

Sound confirmed applied from the run's own `/gc-stats`
(`root_soundness=sound`, `type_id_gate=false`, `stw_multi_*_lag=0`,
`scrub_fibers_enabled=false`), tuned likewise (`type_id_root_rejects=3`).

## Medians

| Config | % of Boehm | RSS × | pause p50 | pause p99 |
|--------|-----------:|------:|----------:|----------:|
| tuned | 99.0% | 1.21× | 2.90 ms | 19.35 ms |
| sound (`GCRY_SOUND=1`) | 90.4% | 1.04× | 2.88 ms | 15.66 ms |

## Why this is inconclusive

Per-trial spread swamps the median difference in both directions:

| | trial 1 | trial 2 | trial 3 | median |
|--|--------:|--------:|--------:|-------:|
| tuned % Boehm | 120.3% | 99.0% | 91.7% | 99.0% |
| sound % Boehm | 96.5% | 88.4% | 89.3% | 90.4% |
| tuned RSS × | 1.54× | 0.83× | 1.41× | 1.21× |
| sound RSS × | 0.90× | 1.38× | 1.04× | 1.04× |
| tuned p99 (ms) | 43.55 | 18.86 | 19.35 | 19.35 |
| sound p99 (ms) | 15.66 | 51.59 | 13.50 | 15.66 |

The tuned throughput band (91.7–120.3%) contains the entire sound band
(88.4–96.5%). RSS bands overlap. p99 has a 3–4× outlier trial in *each*
config, in opposite directions — reading either as a signal would be reading
noise. Boehm itself moved 102 → 141 req/s across tuned's three trials.

## What is real

`phase_stacks` is **0.02–0.54 ms** in every trial, tuned and sound alike, and
`phase_roots` is 0.10–11.9 ms with no pattern by config. The STW lag knobs
(`stw_multi_stack_lag` / `stw_multi_pthread_lag`) therefore cost essentially
nothing to disable *here* — which is consistent with their stated rationale:
they were introduced against EC4 `phase_roots` ~100 ms/collect under Parallel
EC, and this run is EC1. This cut cannot retire them; it can only say they are
inert at parallelism 1.

`type_id_root_rejects=3` under tuned: the static-root gate did discard three
candidates in a 20 s run. Small, but the mechanism is live, not theoretical.

Collection counts match across configs (31–33 either way), so the two are
doing comparable amounts of work.

## Next

- `TRIALS=9`+ and a quiet host before quoting any fat-app sound number. The
  Kemal cut (`bench/log/linux/2026-08-06-042555-sound-profile/`) had 0.73% /
  3.96% run spread and *is* quotable; this one is not.
- Re-run at EC4 (`EC_PARALLELISM=4`), where the lag knobs actually do work.
  That is the configuration most likely to show a real sound-profile cost, and
  none of the numbers above touch it.
