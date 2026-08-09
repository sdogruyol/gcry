# Scrub costs 11% of root work and buys no retention — the default-off A/B

Host: 12th Gen Intel i3-12100F (4C/8T), WSL2, Crystal 1.21.0, `--release`, EC1.
Kemal `/json`, `wrk -c100`, **9 paired reps** × 20 s, interleaved with the
config order rotated each round. ~1050 steady-state collections per config.

Taken after `scrub_fibers_enabled` was defaulted **off**, to measure the knob on
the axis that can actually resolve it. `tuned` here is the new default (scrub
off); `scrub` restores the old default at runtime with `GCRY_SCRUB_FIBERS=1`.

## Result

| config | n | roots µs | scrub µs | stacks µs | mark µs | sweep µs | pause µs | Δ root work | Δ pause |
|--------|--:|---------:|---------:|----------:|--------:|---------:|---------:|------------:|--------:|
| tuned (scrub off) | 1082 | 196.6 | 0.0 | 14.0 | 245.0 | 2287.4 | 564.7 | +0.0% | +0.0% |
| scrub on | 1058 | 192.4 | 27.5 | 14.5 | 256.4 | 2339.9 | 597.7 | **+11.2%** | **+5.9%** |

post-GC RSS, median of 9 reps:

```
tuned   12220 KiB   +0.0%   12152,11816,11940,12332,12180,12584,12308,12552,12220
scrub   12488 KiB   +2.2%   12136,12340,12488,12664,12548,12068,11908,12716,12860
```

Root-phase IQR: tuned 16.0%, scrub 16.9% — well inside the harness's 50%
comparability threshold, so unlike the fat-app cuts these medians stand without
stratification.

## Reading

**Scrub costs what it always cost.** +11.2% root work agrees in sign and rough
magnitude with the **−9.1%** recorded for the opposite direction in
`…-195929-root-phase/`. That number was never in dispute.

**It does not buy the retention it was turned on for.** Post-GC RSS is 2.2%
*higher* with scrub on. At 9 reps with overlapping rep bands (11 816–12 584 vs
11 908–12 860) that is a wash, not a reversal — but a wash is already fatal to
the justification, which was that scrub *reduces* retention. The fat-app RSS
that originally put it on default (3.00× → 2.65×) had already failed to
reproduce; this says Kemal does not carry it either.

**Throughput is the wrong instrument and stays that way.** `roots + scrub +
stacks` is ~0.15% of wall time here; 11% of that is ~0.016%. Both of the
published throughput readings for this knob (+1.29%, −1.22%) are ~100× larger
than the largest effect the mechanism can produce, which is why they disagreed
in sign.

## What this does not settle

Whether a live pointer can exist only inside the wiped window
(`[stack_top − 4 KiB, stack_top)` on another fiber's stack). `bench/scrub_audit.cr`
closed the foreign-thread half of that question; this cut is about cost, not
correctness, and does not touch the remaining half.
