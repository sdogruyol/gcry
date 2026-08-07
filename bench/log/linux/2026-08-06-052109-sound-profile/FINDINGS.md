# Sound-roots profile — Kemal `/json`, re-cut after the raw-buffer interior fix

**Supersedes the `sound` / `sound-cons` rows in
`bench/log/linux/2026-08-06-042555-sound-profile/`.** Those were measured
against a profile that still dropped interior edges out of raw buffers, so
they under-priced sound. The `tuned` row there is unaffected.

Same harness (`make bench-sound-profile`), same host (WSL2 i3-12100F), but
**7 runs** instead of 5 and a visibly busier machine.

## Result

| Config | req/s | % of Boehm | RSS × | pause p50 | run spread |
|--------|------:|-----------:|------:|----------:|-----------:|
| Boehm | 41050 | — | — | — | 6.40% |
| gcry tuned | 32139 | 78.3% | 0.795× | 0.63 ms | 5.06% |
| gcry sound roots | 33255 | 81.0% | 0.794× | 0.58 ms | 6.54% |
| gcry sound + conservative bodies | 34636 | 84.4% | 0.797× | 0.55 ms | 10.47% |

## Reading: the differences are below this session's noise floor

Sound came out **faster** than tuned (81.0% vs 78.3%). Sound does strictly more
work than tuned — it follows more candidates and skips no scans — so a genuine
+2.7pp is not physically plausible. With per-config spreads of 5–10.5% against
a 2.7pp gap, the correct reading is that **this session cannot resolve the
difference at all**, in either direction.

Session 1 (5 runs, spreads 0.73–3.96%) put sound ~1pp *behind* tuned, but its
sound row is invalid post-fix. So as of now there is **no valid cut that
resolves the cost of the sound profile on Kemal `/json`.** The earlier "~1pp"
figure should not be quoted.

## What is robust

**RSS does not move.** 0.795× / 0.794× / 0.797× here; 0.756× / 0.754× / 0.746×
in session 1. Two sessions, three configs each, and post-GC RSS is flat to
three digits within a session. RSS is a far lower-variance measurement than
wrk throughput on this host, so this is the one claim both cuts support.

That is a genuinely interesting negative result: the fix made sound retain
strictly *more* (interior edges out of raw buffers are now followed) and
post-GC RSS still did not move. On this workload those edges are either rare
or they resolve to objects that were already reachable another way.

## Caveats

- One host, and a noisy one. `sound-cons` at 10.47% spread is the worst row.
- EC parallelism 1 only. The STW lag knobs are inert there (see the acik
  FINDINGS), so this cut still says nothing about the configuration where the
  sound profile is most likely to actually cost something.

## Next

- Re-cut on a quiet machine before quoting any throughput delta. Target
  per-config spread ≤1%, which session 1 achieved and this one did not.
- Per-knob decomposition rather than the whole class at once — with the class
  cost unresolvable, attributing it is the only way to learn anything.
- EC4.
