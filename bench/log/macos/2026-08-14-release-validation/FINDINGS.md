# The 0.19.0 suite on a Darwin host — and the three things it found

**Status: 21 of 25 targets green. Three of the four reds are pre-existing and
predate this branch; one of them predates `v0.17.0`. None is caused by the
register fix this release is cut for.**

Apple M2 Pro, Darwin 25.5.0 / macOS 26.5.1 arm64, Crystal 1.21.0, at `ff0b030`.

## Why this was run at all

`test-macos` runs `crystal spec`, `crystal spec -Dgc_none process_spec` and
seven samples. That is the whole macOS gate. The ~20 fuzz / property / STW /
soak targets in the Makefile run on Linux only — so a release whose headline
change is *Darwin STW code* has no CI coverage for the things most likely to
break. Everything below was run by hand for that reason.

| target | | |
|---|---|---|
| `format-check` | PASS | 0s |
| `spec` | PASS | 3s |
| `spec-process` | PASS | 3s |
| **`invariants`** | **FAIL** | 5s |
| `greg-roots` | PASS | 1s |
| `fuzz-short` | PASS | 7s |
| `property-test-short` | PASS | 2s |
| `layout-property-test-short` | PASS | 3s |
| `mt-property-test-short` | PASS | 2s |
| `stw-mt-property-test` | PASS | 5s |
| `pattern-fuzz` | PASS | 530s |
| `thread-storm` | PASS | 4s |
| `oom-test` | PASS | 3s |
| `fork-test` | PASS | 2s |
| `finalizer-complex` | PASS | 2s |
| `nursery-headers` | PASS | 3s |
| `parallel-mark-process` | PASS | 1s |
| `sound-profile-smoke` | PASS | 2s |
| `soak-smoke` | PASS | 12s |
| `stw-watchdog` | PASS | 4s |
| **`stw-monitor-gate`** | **FAIL** | 45s |
| `stw-startup-hang` | PASS | 19s |
| **`stw-lag-pause`** | **FAIL → fixed, now PASS** | 0s |
| `scrub-midswap` | PASS | 3s |
| **`lint`** | **FAIL** | 40s |

## 1. `make invariants` has never passed on Darwin

```
gcry invariant: live_objects mismatch: actual=6364 reported=1
  from src/gcry/invariant.cr:185 in 'check_live_objects'
  from spec/collect_spec.cr:215 in '->'
```

`spec/collect_spec.cr:202`, "keeps empty chunks dormant within
empty_chunk_retain". Reproduced at `master`, at **`v0.18.0`** and at
**`v0.17.0`** — it shipped in two releases. Linux CI runs the same target
("Debug invariants") and is green; `test-macos` does not run it, which is the
whole reason nobody saw it.

Debug-only: the shipping path never calls the checker, and the same spec passes
under `make spec`. So what disagrees is the walker, not the collector's own
accounting.

**Hypothesis, not a finding.** `Invariant.count_live_blocks` walks every chunk
and counts any block whose header does not read free. The spec deliberately
leaves 8,000 dead objects in chunks it then makes *dormant*, and Darwin's
reclaim does not touch those headers (`MADV_FREE_REUSABLE` does not zero them —
`collect_sweep.cr:439`), where Linux's `MADV_DONTNEED` behaves differently.
6364 is close to, but not equal to, the 8,000 allocated, which is the sort of
detail a real diagnosis has to account for and this one does not.

What would settle it: count what the walker sees on a chunk the sweep has just
made dormant, on both platforms. Until then this is "the checker and Darwin
disagree", worth exactly that much. Carried in `ROADMAP.md`.

## 2. `make stw-monitor-gate` cannot validate itself on Darwin

```
  gate on   collect_stacks inside the stop: 0   held off 1x   stw_waits=0
  gate off  collect_stacks inside the stop: 0   (control)

FAIL control (gate off) showed 0 collect_stacks inside a 20000 ms stop
```

The harness fails on its **control** arm, and it is right to: with the gate
disabled it saw none of the behaviour the gate exists to prevent, so the
passing arm would have proved nothing. This is the harness's own rule (a green
reachable without observing anything says nothing) working as designed.

Pre-existing — reproduced at `e0707b6`, where it fails *twice* (the gate-on arm
reported `blocks=0` as well). Not a collector result: it says the `-Dtracing`
probe does not see the EC Monitor's `collect_stacks` on Darwin. Whether that is
the Monitor behaving differently here or the probe not observing it is open, and
this run cannot tell them apart.

## 3. `make stw-lag-pause` did not compile on Darwin — fixed here

`bench/stw_lag_pause.cr:263` called `Gcry::Platform.pagemap_available?`
unguarded. That method exists only in `platform/linux_pagemap.cr`, so the bench
failed to *build* on Darwin — the 0s runtime above is a compile error, not a
fast test. The same file already guards the identical call at what is now
line 339; this one was missed.

Fixed by applying that guard. It now passes on Darwin at the relaxed bound, and
in passing supplies a number the "Low-water skip on Darwin" roadmap item wanted:

```
  tuned       pause median=   16.33 ms   roots median=  10.97
  stack_lag0  pause median=  348.02 ms   roots median= 342.72
  sound       pause median=  349.88 ms   roots median= 344.69
  PASS stack_lag0 ratio: 21.32× <= 30.0×
  PASS sound ratio: 21.43× <= 30.0×
```

**21.3× is what Darwin pays for having no low-water skip**, measured rather than
inferred from the Linux 8.06 → 3.60 ms delta. The bound is the relaxed
`--max-ratio-nolw=30`, not CI's `4`, and it has to be: the tight bound assumes
the skip, and Darwin does not have it.

## 4. `make lint` — floating dependency, not this branch

10 findings across `src/gcry/heap.cr`, `stack_maps.cr`, `tlab.cr` and five spec
files. **None in any file this branch touches**, and `.ameba.yml` excludes
`bench/` entirely, so the new harness was never inspected.

`shard.yml` pins ameba to `branch: master`; this run resolved `1.7.0-dev at
b50c1ff` and the rules that fire (`Style/WhileTrue`, `Lint/ElseNil`) are recent.
CI was green on `master` on 2026-08-13 with whatever ameba master was then. So
CI can go red here without a code change, and probably will on the next run.
That is a release risk worth naming even though it is not a defect.

## What the passes are and are not worth

- **`soak-smoke`'s RSS half is inert on Darwin.** `bench/soak.cr:53-65` reads
  `/proc/self/status` with no platform guard and `rescue 0`, and `:288` gates
  the check on `start_rss > 0`. It passes without ever checking RSS; only the
  heap / live_objects half is real here.
- **`stw-lag-pause` passes at the loose bound** (30×, not CI's 4×) — see above.
- **`scrub-midswap` kills one child on purpose**, so a SEGV backtrace on stderr
  is the expected output, and it hangs on ~12% of starts and retries.
- **`greg-roots`' survival arm does not discriminate.** The candidate count is
  the gate; see the header of `bench/greg_roots.cr`.
