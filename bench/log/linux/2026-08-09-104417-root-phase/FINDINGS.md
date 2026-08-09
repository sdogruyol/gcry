# The low-water skip on the default path halves Kemal EC4 pause

Host: 12th Gen Intel i3-12100F (4C/8T), WSL2, Crystal 1.21.0, `--release`,
**EC parallelism 4** (`-Dpreview_mt -Dexecution_context`, 5 server threads).
Kemal `/json`, `wrk -c100`, 9 paired reps × 20 s, ~2300 steady-state
collections per config.

This is the control the ROADMAP required before ungating the skip: EC4 is the
shape where `lag = 0` still costs (+83% at the time), so it is where a skip on
the `lag > 0` default path could plausibly cost rather than save.

## Configs

| key | what |
|-----|------|
| `tuned` | the change — `lag = 256 KiB` **with** the low-water skip |
| `tuned-nolw` | `GCRY_STACK_LOW_WATER=0` — the previous default, the control |
| `sound` | `GCRY_SOUND=1` — `lag = 0` with the skip |

## Result

Single heap regime (~93 MiB across all three, 9 reps each), so these medians
stand without stratification — unlike the fat app.

| config | roots µs | stacks µs | pause ms | Δ root work | Δ pause | IQR |
|--------|---------:|----------:|---------:|------------:|--------:|----:|
| `tuned` | 2787.4 | 240.2 | **3.60** | +0.0% | +0.0% | 24% |
| `tuned-nolw` | 7063.3 | 372.8 | 8.06 | **+147.3%** | **+124.1%** | 12% |
| `sound` | 14179.5 | 1658.3 | 16.39 | +425.6% | +355.8% | 63% |

**Pause 8.06 → 3.60 ms**, root work 7424 → 3002 µs. Post-GC RSS is flat across
all three — 90 960 / 91 184 / 91 100 KiB, inside 0.2% — so nothing was traded.

`mark` and `sweep` are unchanged (321/343/368 µs and ~16.8 ms), which is what a
root-scan change should look like: the saving is entirely in `roots + stacks`.

## Reading

The default was paying for a fixed 256 KiB window per parked fiber without
asking whether those pages had ever been written. Most had not. Starting at
`max(stack_top − lag, low_water)` keeps the lag bound *and* skips the untouched
head, so it is never wider than the old window and never narrower than what the
words can hold.

`sound` stays far behind (16.4 ms) and that is the point of running EC4: **lag 0
is still the wrong default here**, with or without the skip. The skip does not
make the complete scan affordable at EC4; it makes the *bounded* scan cheap.
Only `tuned` gets both protections.

`sound`'s 63% IQR marks its magnitude as soft. The `tuned` vs `tuned-nolw`
comparison — the one this run exists to settle — is 24% and 12%, both inside
the harness's 50% comparability threshold.

## What this does not say

- **Nothing about EC1.** `fiber_stack_scan_top` returns before the lag branch
  unless `multi_mutator_threads?` holds, which is `Thread` count > 2. Kemal at
  EC1 runs 2 threads, so this code cannot execute there — a property of the
  code, not a gap in the measurement. The Kemal EC1 headline needs no re-cut.
- **Nothing about throughput.** This measures pause composition per collection.
