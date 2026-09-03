# Kemal end to end: the branch is neutral, and the bitmap allocator is an RSS
# lever, not a throughput one

Date: 2026-09-03 · host: WSL2, AMD Ryzen AI 9 HX 375 (dual-channel) · `simdgc`
`bench/perf_smoke.sh` (repo protocol) plus paired interleaved `wrk -t4 -c100 -d10s`
on `/json`, 9 pairs per comparison.

## 1. Regression guard: branch vs master, default path — FLAT

| metric | branch | master | diff | t |
|---|---|---|---|---|
| `/json` rps | 42641 | 42130 | +0.3% | 0.11 |
| post-GC RSS | 14468 kB | 14560 kB | −0.5% | −0.70 |

Neither is significant. Every phase on this branch is behind a knob and the
default path is untouched, which is what the plan requires of Kemal as
regression guard. This is the PR's licence to merge.

`perf_smoke` default arm on this host: **pct_json 101.4, pct_root 94.2,
rss_x 1.004, pause_p50 0.73 ms**. The pct_json is far above the recorded
CI baseline of 76.0 — a host difference (WSL2 vs ubuntu-latest), not a change;
absolute ratios are explicitly not comparable across hosts.

## 2. The bitmap allocator trades throughput for RSS

`GCRY_BITMAP_ALLOC=1` vs the default header path, paired n=9:

| metric | bitmap | default | diff | t | wins |
|---|---|---|---|---|---|
| `/json` rps | 39262 | 43116 | **−8.3%** | −2.79 | 1/9 |
| post-GC RSS | 12804 kB | 14632 kB | **−12.1%** | −18.78 | 9/9 |

`perf_smoke` bitmap arm: pct_json 94.5, **rss_x 0.893** — which *passes* the
recorded baseline gate that the default arm (1.004) fails.

## 3. The micro-benchmark win did not convert, and that is the headline

Phase 3 measured `ns_per_alloc` **−27.8%** on `bench/micro/gc_phases`, and it was
the one result on this branch touching the mutator hot path rather than the GC
pause — the only credible path to end-to-end throughput. It did not convert.
Kemal `/json` throughput *falls* 8.3%.

By the plan's own Phase 3 gate — "Kemal `/json` ≥ baseline **and** `phase_sweep`
sub-millisecond; sweep winning while thr falls is **the reject, not a trade**" —
the bitmap allocator does not clear the throughput bar. That gate was written
against `2026-08-01-ec4-alloc-bits`, and this is the same shape of result: a
representation that wins every micro axis and loses the mutator.

One hypothesis was tested and **disconfirmed**: that `bitmap_alloc` forcing TLAB
off explains it. TLAB is off by default (`GCRY_TLAB=1` opts in), so forcing it
off changes nothing, and a default-path TLAB A/B came back −2.7% at t=−0.89 —
both arms were in fact identical. The cause of the 8.3% is not yet identified
and should not be guessed at.

## 4. What this means for the plan

The mark- and sweep-side wins are real and large but invisible here by
arithmetic, not by noise: Kemal's GC duty cycle is 0.2–0.5% of wall time, so an
infinitely fast mark is worth ~+0.15pp. That was established in
`2026-09-03-simdgc-chunk-radix-ab` and holds.

What changes is **why `bitmap_alloc` is interesting**. It was pursued as a
throughput lever and is not one. It is an **RSS lever**: −12.1% post-GC RSS,
9/9, t=−18.78, taking rss_x from 1.004 to 0.893. The shipping bar on the board
is EC1 `/json` **≥95% @ ≤1.0× RSS**, and RSS is the half this branch can now
move. That is also the half Phase 7 (headerless, 16 B/object) targets, so the
two compound rather than compete.

Honest standing: `GCRY_BITMAP_ALLOC` stays **off by default**. It is not
promotable on throughput, and the plan's stated fallback — "stop at Phases 0–2 +
4–5, which do not touch the allocator" — is the correct reading of the
throughput axis. It is retained because the RSS result is strong and is the
axis the shipping bar still needs.
