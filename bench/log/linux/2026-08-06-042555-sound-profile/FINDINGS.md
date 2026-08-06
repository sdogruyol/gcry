# Sound-roots profile — Kemal `/json` cut

> **SUPERSEDED (sound rows only).** The `sound` and `sound-cons` rows below were
> measured against a profile that still dropped interior edges out of raw
> buffers (`scan_object` marked untyped allocations base-only regardless of
> `allow_interior_pointers`). They under-price sound and must not be quoted.
> Re-cut: `bench/log/linux/2026-08-06-052109-sound-profile/`. The `boehm` and
> `tuned` rows are unaffected and remain the best low-noise cut on this host.

**Question:** what does gcry cost when every root-completeness heuristic is off?

Host: WSL2 x86_64 (i3-12100F), Crystal 1.21.0, `--release`, EC parallelism 1.
`wrk -c 100 -d 20`, 5 runs per config, median with min/max discarded, then
`GET /gc-collect` and post-GC `VmRSS`. Boehm re-measured in the same session.

Harness: `bench/sound_profile_ab.sh` (`make bench-sound-profile`). The run
aborts if a config labelled `sound` does not report `root_soundness=sound`
from its own `/gc-stats` — the numbers below are confirmed applied, not
assumed applied.

## Result

| Config | req/s | % of Boehm | RSS × | pause p50 | run spread |
|--------|------:|-----------:|------:|----------:|-----------:|
| Boehm | 40999 | — | — | — | 3.87% |
| gcry tuned (defaults) | 34796 | **84.9%** | **0.76×** | 0.56 ms | 0.73% |
| gcry sound roots (`GCRY_SOUND=1`) | 34398 | **83.9%** | **0.75×** | 0.55 ms | 3.96% |
| gcry sound + conservative bodies (`+GCRY_DISABLE_LAYOUT=1`) | 34351 | **83.8%** | **0.75×** | 0.56 ms | 11.68% |

Sound config confirmed by `/gc-stats`:

```
allow_interior_pointers=true  scan_unaligned_candidates=true
type_id_gate=false  type_id_gate_stacks=false
stw_multi_stack_lag=0  stw_multi_pthread_lag=0
scrub_fibers_enabled=false  blacklist_enabled=false
```

## Reading

~~The whole root-heuristic class is worth ~1pp of throughput on this
workload.~~ **Retracted** — the sound rows were measured against a holed
profile (see the banner above), and the re-cut cannot resolve the difference
at all. Do not quote ~1pp.

What survives: **RSS does not move** (0.756× → 0.754× → 0.746×), and the
re-cut reproduces that (0.795× → 0.794× → 0.797×). Post-GC RSS is the
low-variance measurement here; throughput on this host is not.

**Do not over-read it.** Kemal `/json` is the workload where these knobs were
*least* expected to matter. The arguments for them in-tree are fat-app RSS
arguments — fiber scrub was justified at acik 3.00× → 2.65×, the STW lags at
EC4 `phase_roots` ~100 ms/collect, the type_id gate at BSS false hits. A
Kemal-only cut cannot retire any of them. See the acik session for the half
of this question that actually stresses the defaults.

Caveats: one host, one session, WSL2. `sound-cons` spread is 11.7% (one bad
run at 30705) — treat its median as approximate. `tuned` spread of 0.73% vs
`sound` 3.96% is run-order noise, not a stability property of either config.

## Next

- ~~Same cut on acikturkiye~~ — done, and **inconclusive at N=3**: per-trial
  spread swamps the median difference in both directions. See
  `bench/log/linux/2026-08-06-acik-sound-profile/FINDINGS.md`. Needs
  `TRIALS=9`+ on a quiet host.
- **EC4.** `phase_stacks` was 0.02–0.54 ms in every acik trial at EC1, so the
  STW lag knobs are inert at parallelism 1 — they were introduced against EC4
  `phase_roots` ~100 ms/collect. Parallel EC is the configuration most likely
  to show a real sound-profile cost and nothing here has measured it.
- Only after those: the defaults question. A ~1pp/0.00× price for removing a
  documented UAF class would be a trade worth making by default — but one
  workload on one host at EC1 does not license that call.
