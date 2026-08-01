# Announcing gcry (draft)

Crystal-native conservative mark–sweep GC as a **shard** — `require "gcry"` + `-Dgc_none`, no compiler fork.

## One-liner

Boehm-class collector you can read and change in Crystal; **Linux + macOS**; fibers OK; parallelism 1.

## v0.16.0 highlight

EC1 thr recovery after Parallel-era STW / scrub / counter fallout. Linux Kemal `/json` ~**87%** of Boehm @ ~**0.80×** post-GC RSS. Supported path remains EC parallelism **1**, `GCRY_TLAB` **off** (Parallel+TLAB stays experimental — FINDINGS only).

## Linux numbers

Cite [PERF.md](PERF.md) (**Linux** only; do not invent). Prefer **`/json`**.

**v0.16.0** (measured): `/json` ~**87%** of Boehm thr @ ~**0.80×** post-GC RSS; `/` ~**82%** @ ~**0.79×**. Fat-app (acikturkiye): ~**90%** thr / ~**2.54×** RSS *(carry v0.15)* — [ACIKTURKIYE.md](ACIKTURKIYE.md).

## macOS numbers

Cite [PERF-macos.md](PERF-macos.md). Last Darwin Kemal cut is **v0.13.0** (not re-cut for 0.16): `/` ~**93%**, `/json` ~**84%**, post-GC RSS ~**0.93–1.06×**.

## When to try gcry

- Want a Crystal-readable GC / dogfood alternative
- Linux **or macOS**, Crystal ≥ 1.21, default ExecutionContext (parallelism 1)
- Can accept STW pauses and conservative retention

## When to stay on Boehm

- Windows process GC; Darwin soft-dirty / nursery parity
- Parallel ExecutionContexts in production
- Need `Process.fork` under ExecutionContext (Crystal forbids it; gcry atfork helps `-Dwithout_mt` / `LibC.fork` only)

## Channels

- GitHub: https://github.com/sdogruyol/gcry
- Crystal forum / Discord: link PERF methodology + honest limits
- awesome-crystal / shards.info: after a tagged release

## Checklist before posting

- [x] Tag `v0.16.0`; PERF.md + README refreshed same day
- [ ] CI green on x86_64 + aarch64 + macOS
- [ ] Link COMPARISON.md + POLICY.md + TEST_PLAN.md
- [ ] Lead with **EC1 thr recovery + measured Linux numbers**, not a Parallel miracle
