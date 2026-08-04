# Announcing gcry (draft)

Crystal-native conservative mark–sweep GC as a **shard** — `require "gcry"` + `-Dgc_none`, no compiler fork.

## One-liner

Boehm-class collector you can read and change in Crystal; **Linux + macOS**; fibers OK; parallelism 1.

## v0.17.0 highlight

Darwin Kemal re-cut (first since v0.13): `/json` ~**84%** @ ~**0.93×** RSS. Parallel TLAB-off + lazy sweep is a **supported opt-in** (~79% `/json`); EC1 remains the default. Linux Kemal PERF headline carries **v0.16** (~87% @ ~0.80×).

## Linux numbers

Cite [PERF.md](PERF.md) (**Linux** only; do not invent). Prefer **`/json`**.

**v0.17.0** Kemal: carry v0.16 — `/json` ~**87%** of Boehm thr @ ~**0.80×** post-GC RSS; `/` ~**82%** @ ~**0.79×**. Fat-app (acikturkiye): ~**90%** thr / ~**3.43×** RSS — [ACIKTURKIYE.md](ACIKTURKIYE.md). Parallel opt-in (EC>1 + TLAB off + lazy): ~**79%** `/json`.

## macOS numbers

Cite [PERF-macos.md](PERF-macos.md). **v0.17.0** Darwin re-cut: `/` ~**90%**, `/json` ~**84%**, post-GC RSS ~**0.93–0.97×**. Fat-app ~**71%** thr @ ~**18×** RSS.

## When to try gcry

- Want a Crystal-readable GC / dogfood alternative
- Linux **or macOS**, Crystal ≥ 1.21, default ExecutionContext (parallelism 1)
- Can accept STW pauses and conservative retention

## When to stay on Boehm

- Windows process GC; Darwin soft-dirty / nursery parity
- Parallel EC **with TLAB** or empty munmap (unsupported); or zero-tuning Parallel defaults
- Need `Process.fork` under ExecutionContext (Crystal forbids it; gcry atfork helps `-Dwithout_mt` / `LibC.fork` only)

## Channels

- GitHub: https://github.com/sdogruyol/gcry
- Crystal forum / Discord: link PERF methodology + honest limits
- awesome-crystal / shards.info: after a tagged release

## Checklist before posting

- [ ] Tag `v0.17.0`; PERF-macos.md + README refreshed same day
- [ ] CI green on x86_64 + aarch64 + macOS
- [ ] Link COMPARISON.md + POLICY.md + TEST_PLAN.md
- [ ] Lead with **Darwin re-cut + Parallel supported opt-in**; Linux Kemal carries v0.16; Parallel not the default
