# Announcing gcry (draft)

Crystal-native conservative mark–sweep GC as a **shard** — `require "gcry"` + `-Dgc_none`, no compiler fork.

## One-liner

Boehm-class collector you can read and change in Crystal; **Linux + macOS**; fibers OK; parallelism 1.

## macOS (v0.10.0)

Process GC on Darwin is real: Mach STW, dyld roots, host-page reclaim. Crystal **≥ 1.21**.

Same-host Kemal on Apple Silicon (`wrk -c 100 -d 30`, median of 3): `/` ~**97%**, `/json` ~**90%**, post-GC RSS ~**0.97×** — [PERF-macos.md](PERF-macos.md).

## Linux numbers

Cite [PERF.md](PERF.md) (**Linux** only; do not invent). Prefer **`/json`**.

As of last Linux cut (**v0.9.0**): `/` ~**89%**, `/json` ~**92%**, post-GC RSS ~**0.97×** Boehm. (v0.10.0 did not re-cut Linux on the Darwin release host.)

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

- [ ] Tag `v0.10.0`; PERF-macos.md + README refreshed same day
- [ ] CI green on x86_64 + aarch64 + macOS
- [ ] Link COMPARISON.md + POLICY.md
- [ ] Call out **macOS process GC** in the title / first paragraph
