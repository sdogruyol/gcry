# Default-path control: master vs branch, no measurable regression

Host: AMD Ryzen 9 9950X (16C/32T), WSL2, Crystal 1.21.0, `--release`, EC1.
Kemal `/json`, `wrk -c100`, 9 rounds × 30 s, both builds interleaved in one job
with the order rotated each round. **Default configuration on both sides — no
`GCRY_*` set.**

This closes the control the handover asked for alongside defect 5. The branch
adds an ivar load and a branch to the hot mark path
(`return if !@scan_unaligned_candidates && (addr & …) != 0`, and the
`!@allow_interior_pointers` term in `scan_object`), and until now that cost was
asserted rather than measured.

## Setup

`master` is `f027c06` built from its own `git worktree` — its own
`shard.lock`, its own `src/gcry` — as `bin/kemal-gcry-master`. `branch` is the
current build. Both run under the same harness in the same job, so the four
biases found earlier in this session (clock stepping, blocked execution, fixed
within-round order, and the discarded-pass retry loop) do not apply.

The two builds are visibly distinct in the log: `master` reports no `soundness`
field on `/gc-stats`, because that API only exists on this branch.

## Result

| round | master | branch | branch vs master |
|------:|-------:|-------:|-----------------:|
| 1 | 34115 | 33978 | −0.40% |
| 2 | 33729 | 33513 | −0.64% |
| 3 | 33713 | 33188 | −1.56% |
| 4 | 34016 | 33793 | −0.65% |
| 5 | 33300 | 34551 | +3.76% |
| 6 | 32511 | 33273 | +2.34% |
| 7 | 32421 | 33378 | +2.95% |
| 8 | 33250 | 32767 | −1.45% |
| 9 | 33048 | 31974 | −3.25% |

**mean +0.12%, median −0.64%, σ 0.2, 95% CI −1.42% … +1.66%.**

No measurable regression on the default path. The measurement bounds the cost
to roughly ±1.5%, and it **excludes the −2.13% figure** carried in the handover
(that number came from a cut with 8–10.5% spreads, i.e. it was never resolved).

## Limits

This is an upper bound, not a zero. The per-round scatter here (stdev 2.35%)
was worse than the neighbouring cut (1.46%), which is what keeps the interval
at ±1.5% rather than tighter. A sharper bound is available from the
per-collection trace, where the added branch lives directly in `roots_ns`
(4–6% IQR over ~370 samples, SEM ~0.3%); that would need the same
`key@binary` support added to `bench/root_phase_ab.sh`.

Theory agrees with the measurement: the added work is one predictably-taken
branch on an ivar that is already hot in the mark loop, so a sub-1% effect is
what should be expected.
