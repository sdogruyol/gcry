# Four biases, and what is left of the sound profile's throughput cost

Host: AMD Ryzen 9 9950X (16C/32T), WSL2, Crystal 1.21.0, `--release`, EC1.
Kemal `/json`, `wrk -c100`, 9 rounds × 30 s, configs interleaved round-robin
with the order rotated each round.

This is the cut that closes the handover's defect 5. It is worth reading as a
methodology result first and a number second, because the number only became
meaningful after four separate biases came out of the harness.

## The bias hunt

Every previous cut of this comparison put `sound` *ahead* of `tuned`, which
looked impossible and was treated as proof the run was invalid. Each round of
fixing shrank it:

| Design | sound vs tuned | What was confounded |
|--------|---------------:|---------------------|
| blocked, wrk's own clock | — | rate itself was wrong |
| blocked, monotonic clock (`…-115427/`) | **+2.27%** | config order ↔ time |
| interleaved, fixed order (`…-125526/`) | **+2.11%** (3.9σ) | position within round |
| **interleaved, rotated (this run)** | **+0.82%** (1.7σ) | — |

The four defects, all of them **bias rather than variance** — which is why more
runs never helped, and why this benchmark had been producing confidently wrong
numbers for a long time:

1. **`CLOCK_REALTIME` steps.** WSL2 steps the guest clock backwards ~1.6 s
   every ~32 s; wrk derives its duration from it, so a pass catching a step
   reports ~19% high. Random which config gets hit. Full measurement in
   `…-112252-sound-profile/FINDINGS.md`.
2. **A retry loop that broke the methodology.** The first fix *discarded*
   stepped passes. Steps arrive faster than a 30 s pass completes, so the
   documented 9×30 s cut could never finish — and discarding was unnecessary
   anyway: recomputed against monotonic, stepped passes land inside the clean
   spread.
3. **Blocked execution.** Running each config as a consecutive ~5-minute block
   confounds config with time. The three gcry blocks came out monotonically
   faster in execution order (+0%, +2.11%, +2.80%).
4. **Fixed order within a round.** Interleaving shrinks that to within-round
   scale, it does not remove it. With a fixed order, whichever config ran first
   in each round came out ~2% slower — and it was the *same* ~2% for three
   different knob configurations (+2.34%, +1.91%, +1.91%, `…-132232/`), which
   is the signature of position, not of any knob.

The tell throughout was an impossible-looking result. It was worth chasing four
times.

## Result

| Config | req/s | vs tuned | rounds won | σ |
|--------|------:|---------:|-----------:|--:|
| tuned | 32976 | — | — | — |
| `GCRY_DISABLE_SCRUB_FIBERS=1` | 33322 | **+1.29%** | 8/9 | **3.2** |
| `GCRY_SOUND=1` | 33359 | +0.82% | 8/9 | 1.7 |
| `GCRY_DISABLE_BLACKLIST=1` | 33198 | +0.73% | 7/9 | 1.2 |

**The sound profile is throughput-neutral here.** +0.82% at 1.7σ is not
distinguishable from zero. The honest statement is that the whole class costs
less than ~1% of throughput on this workload, in either direction — which is a
much better answer than the "unmeasured" this document carried before, and it
is the first time the comparison has been made with the confounds removed.

**`scrub_fibers` is the one knob with a real signal**, and it points the wrong
way for a default: turning it *off* gains 1.29% (8/9 rounds, 3.2σ). That agrees
with an independent instrument — the per-collection trace has it saving 1.7% of
root work when disabled (`…-081512-root-phase/`), because the zeroed words it
writes cost more than the root-scan rejections they save.

So `scrub_fibers_enabled` loses on **every** axis measured: throughput, pause,
and root completeness. It is the one member of the class that can be turned off
today on its own merits, without settling the defaults question.

## Limits

- One workload, one host, EC1, one session. The 0.82% and 0.73% figures are
  consistent with zero and should not be quoted as effects.
- `no-scrub` at 3.2σ over 9 paired rounds is suggestive, not conclusive; a
  second session would settle it. The agreement with the pause instrument is
  what makes it worth acting on.
- Rotation equalises position across configs; it does not remove the underlying
  effect (the first config in a round really is slower). If that mechanism were
  understood — likely cold page cache or CPU idle state after the previous
  server exits — a settling delay might reduce the residual spread further.
- The residual per-round spread (1.2–1.8%) is still unattributed. The 9950X's
  two CCDs, boost behaviour, and Windows-side activity are all unruled-out.
- This says nothing about EC4 or the fat app, where the profile's cost is a
  pause regression of 19× and 14.5× respectively and is not subtle.
