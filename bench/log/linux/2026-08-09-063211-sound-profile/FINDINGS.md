# Third unresolved throughput reading; RSS flat for the third time

Host: 12th Gen Intel i3-12100F (4C/8T), WSL2, Crystal 1.21.0, `--release`, EC1.
Kemal `/json`, `wrk -c100`, **9 rounds × 30 s**, interleaved with the config
order rotated each round — the methodology `…-140037-sound-profile/` established.

First sound-profile cut taken on the tip default (parked-fiber scrub off).

| Config | req/s | % of Boehm | RSS × | pause p50 | run spread |
|--------|------:|-----------:|------:|----------:|-----------:|
| Boehm (baseline) | 42 140 | — | — | — | 5.08% |
| gcry tuned (defaults) | 34 491 | **81.8%** | **0.75×** | 0.59 ms | 6.14% |
| gcry sound roots | 34 970 | **83.0%** | **0.76×** | 0.59 ms | 5.98% |
| gcry sound + conservative bodies | 35 226 | **83.6%** | **0.74×** | 0.59 ms | 8.77% |

Every `sound` row is confirmed applied from its own `/gc-stats`
`root_soundness`, not assumed from the env var.

## Reading

**Throughput: unresolved, for the third session running.** Sound comes out
+1.39% ahead of tuned against a ~6% run spread. That is the same non-answer
session 2 gave, not a confirmation of it.

One thing has changed about *why* it is a non-answer. The previous write-up
argued that "sound ahead of tuned" was evidence of harness bias, because sound
does strictly more work. **That argument no longer holds in general:** since the
low-water skip, `lag = 0` starts the parked-fiber scan at the stack's low-water
mark while the 256 KiB default window does not, so sound can genuinely scan
*fewer pages* than tuned. On the fat app that effect is measured and large
(`…-071144-root-phase/`: −25.4% pause at the large-heap stratum).

It does not apply here. Kemal at EC1 never presents STW with more than two
mutator threads, so `stw_multi` is false and the lag knobs are inert — the
mechanism cannot be what produced +1.39%. On this workload the honest reading
is still "under ~1% either way, not distinguishable from zero".

**RSS: flat, third session.** 0.75 / 0.76 / 0.74× across tuned, sound and
sound+conservative. Prior sessions: 0.756/0.754/0.746× and 0.795/0.794/0.797×.
Post-GC RSS remains a far lower-variance channel than wrk throughput on this
host, and it is the claim the data supports.

**Pause p50 is identical to two digits** across all three gcry configs
(0.588 / 0.588 / 0.594 ms), consistent with the lag knobs being inert here.
