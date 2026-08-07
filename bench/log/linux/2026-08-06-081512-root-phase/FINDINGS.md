# Per-knob decomposition of the sound profile (defect 4)

Host: AMD Ryzen 9 9950X (16C/32T), WSL2, Crystal 1.21.0, branch
`feat/sound-defaults`. Workload: Kemal `/json`, `wrk -c100`, EC parallelism 1.
Instrument: `bench/root_phase_ab.sh` — 8 configs × 3 reps × 20 s, first 5
collections of each rep dropped as heap-growth warm-up. **2873 collections**
analysed.

## Why this is not a throughput cut

At the time of this cut the throughput channel would not resolve, and the 9950X
looked no better than the i3/WSL2 box. Evidence gathered then, in increasing
order of how much it rules out — see the correction below the table:

| Test | Spread |
|------|-------:|
| `boehm`, 9 runs × 30 s, sequential (the §5 protocol) | 10.8% |
| configs interleaved round-robin, 6 rounds × 10 s | 15–20% |
| server + `wrk` pinned to disjoint cores | 14–30% |
| **one server process, no restart, 8 × 10 s passes** | **27%** |

The last row looked decisive: same process, same configuration, box at 99–100%
idle between passes. It was attributed here to WSL2 host scheduling.

**That attribution was wrong, and this section is superseded by
`2026-08-06-112252-sound-profile/FINDINGS.md`.** The dominant cause was the
harness: WSL2 steps `CLOCK_REALTIME` backwards ~1.6 s every ~32 s, and wrk
derived its pass duration from that clock, so any pass catching a step reported
~19% high. Timing with `CLOCK_MONOTONIC` and redoing stepped passes brings the
spread to 4–7% and restores `sound` below `tuned`. The residual is real and
still unattributed (the 9950X's two CCDs, boost behaviour, and Windows-side
activity are all unruled-out), and it still exceeds the gap being measured — so
the conclusion below (measure the collector, not the process around it) stands,
but "unusable on this host class" was too strong and the reasoning for it was
partly an instrument bug.

So the sanity gate in the handover's §5 cannot pass here, and it is not
supposed to be forced. Measure the collector instead of the process around it:
`GCRY_TRACE=1` emits one `collect_end` record per collection with a full phase
breakdown, giving ~370 samples per config at **4.7–7.3% IQR** on the root
phase. The load generator's variance changes how *many* collections happen,
not what each one costs.

## The accounting that matters

`last_phase_roots_ns` is computed as `monotonic_ns - t0 - scrub_ns`, so it
**excludes** the scrub phase — and three of the configs move scrub to zero.
Ranking on `roots_ns` alone credits those configs with a cost they do not pay.
The honest basis is `roots + scrub`, the total root-preparation work:

| Config | roots µs | scrub µs | roots+scrub | vs tuned |
|--------|---------:|---------:|------------:|---------:|
| tuned | 116.7 | 14.1 | 130.8 | — |
| `GCRY_UNALIGNED_CANDIDATES=1` | 121.6 | 14.5 | 136.4 | **+4.2%** |
| `GCRY_DISABLE_BLACKLIST=1` | 119.0 | 14.8 | 134.1 | **+2.5%** |
| `GCRY_STW_STACK_LAG=0 GCRY_STW_PTHREAD_LAG=0` | 118.0 | 14.2 | 132.1 | +1.0% |
| `GCRY_DISABLE_TYPE_ID_GATE=1` | 116.6 | 14.2 | 131.1 | +0.2% |
| `GCRY_INTERIOR=1` | 116.7 | 14.0 | 130.8 | +0.0% |
| `GCRY_DISABLE_SCRUB_FIBERS=1` | 127.8 | 0.0 | 127.9 | **−2.3%** |
| `GCRY_SOUND=1` (all together) | 132.7 | 0.0 | 132.7 | **+1.4%** |

Every knob was verified to have applied, each isolated to exactly one heap
field, by reading the live values back off `/gc-stats` (see `*-stats.json`).

## What this overturns

**The prior was that `scan_unaligned_candidates` is "nearly all of the cost"
and the other five heuristics are free.** Half right, and the wrong half
matters:

- It *is* the largest single cost knob — but at +4.2%, not "nearly all".
- `blacklist_enabled` is a real second cost at +2.5%, not free.
- **Turning fiber scrubbing off is a net saving (−2.3%), not a cost.** Scrub
  zeroes the words below a parked fiber's estimated SP; those zeros are then
  cheap to reject during the root scan. Drop it and root scanning gets ~11 µs
  more expensive (116.7 → 127.8) — but the scrub phase it replaces cost 14.1 µs,
  so the collection comes out ahead. This is why ranking on `roots_ns` alone
  would have reported `no-scrub` as the *dominant* cost (+9.6%) when it is
  actually the only knob that pays for itself.

That saving is most of why the whole profile lands at +1.4% rather than the
+7.9% its cost knobs sum to.

## What the profile actually costs

**+1.9 µs per collection, on a 398 µs pause** — 0.5% of the pause, and root
preparation is 33% of the pause to begin with. At ~6 collections/s that is
~11 µs/s, on the order of 0.001% of wall time.

This is the useful form of the answer the throughput cuts could not give. The
sound profile's throughput cost is not *hidden* by the host noise — it is
roughly three orders of magnitude smaller than it. Any future cut that reports
a percent-level sound-vs-tuned throughput gap on this workload is reporting
noise, whatever its spread looks like.

Retention moves as little as RSS did: median `live_objects` 3399 → 3413
(+0.4%), median `heap_size` identical at 17.18 MiB.

## Limits

- **Pause composition, not throughput.** This bounds the cost; it does not
  measure req/s, and it cannot see mutator-side effects that never enter a
  collection.
- **EC1, one workload, one host.** `stacks_ns` is ~13 µs, so the STW lag knobs
  remain inert at parallelism 1 — consistent with the earlier acik cut, and
  still no measurement of the EC4 case they were introduced for.
- `sweep_ns` (~1136 µs) exceeds the pause and so is outside it; nothing here
  speaks to sweep.
- Does not license flipping the defaults on its own. It says the class is cheap
  *in pause terms on this workload*, which is a necessary but not sufficient
  input to that decision.
