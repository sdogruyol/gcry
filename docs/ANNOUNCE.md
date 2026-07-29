# Announcing gcry (draft)

Crystal-native conservative mark–sweep GC as a **shard** — `require "gcry"` + `-Dgc_none`, no compiler fork.

## One-liner

Boehm-class collector you can read and change in Crystal; **Linux + macOS**; fibers OK; parallelism 1.

## v0.14.0 highlight

Trust and tooling release: invariant checker, property tests, ASan/Valgrind CI, soak/OOM/thread-storm, `GCRY_TRACE` + heap dump — plus a measured Linux Kemal re-cut.

## Linux numbers

Cite [PERF.md](PERF.md) (**Linux** only; do not invent). Prefer **`/json`**.

**v0.14.0** (measured): `/json` ~**89%** of Boehm thr @ ~**0.79×** post-GC RSS; `/` ~**89%** @ ~**0.78×**. Fat-app (acikturkiye) ~**93%** thr / ~**2.65×** RSS *estimated* (not re-cut) — [ACIKTURKIYE.md](ACIKTURKIYE.md).

## macOS numbers

Cite [PERF-macos.md](PERF-macos.md). Last Darwin Kemal cut is **v0.13.0** (not re-cut for 0.14): `/` ~**93%**, `/json` ~**84%**, post-GC RSS ~**0.93–1.06×**.

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

- [ ] Tag `v0.14.0`; PERF.md + README refreshed same day
- [ ] CI green on x86_64 + aarch64 + macOS
- [ ] Link COMPARISON.md + POLICY.md + TEST_PLAN.md
- [ ] Lead with **test/hardening + measured Linux RSS**, not a thr miracle
