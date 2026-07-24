# Announcing gcry (draft)

Crystal-native conservative mark–sweep GC as a **shard** — `require "gcry"` + `-Dgc_none`, no compiler fork.

## One-liner

Boehm-class collector you can read and change in Crystal; Linux x86_64 + aarch64; fibers OK; parallelism 1.

## Numbers (re-record before publishing)

Same-host Kemal `wrk -c 100 -d 30` vs Boehm — cite [docs/PERF.md](PERF.md) only (do not invent). Prefer **`/json`**.

As of v0.7.0 cut: `/` ~**92%**, `/json` ~**90%**, post-GC RSS ~**0.93×** Boehm.

## When to try gcry

- Want a Crystal-readable GC / dogfood alternative
- Linux, Crystal ≥ 1.21, default ExecutionContext (parallelism 1)
- Can accept STW pauses and conservative retention

## When to stay on Boehm

- macOS / Windows process GC
- Parallel ExecutionContexts in production
- Need `Process.fork` under ExecutionContext (Crystal forbids it; gcry atfork helps `-Dwithout_mt` / `LibC.fork` only)

## Channels

- GitHub: https://github.com/sdogruyol/gcry
- Crystal forum / Discord: link PERF methodology + honest limits
- awesome-crystal / shards.info: after a tagged release

## Checklist before posting

- [ ] Tag release; PERF.md + README table refreshed same day
- [ ] CI green on x86_64 + aarch64 native
- [ ] Link COMPARISON.md + POLICY.md
