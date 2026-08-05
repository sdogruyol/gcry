# Announcing gcry v0.18.0 (draft)

Crystal-native conservative mark–sweep GC as a **shard** — `require "gcry"` + `-Dgc_none`, no compiler fork. Stock Crystal ≥ 1.21 is enough.

## One-liner

Boehm-class collector you can read and change in Crystal; **Linux + macOS**; fibers OK; default parallelism 1. Stack maps ship **dormant** (research only — not the v0.18 win).

## v0.18.0 highlight

**Fat-app RSS closed without a compiler fork.** Finalizer registry fix + Linux retain=0 → acikturkiye tip ~**90–96%** thr @ ~**1–1.6×** RSS (was ~**3.43×** at v0.17 on i3; Darwin tip ~**0.63×**, was ~**18×**). Linux Kemal PERF headline still carries **v0.16** (~**87%** `/json` @ ~**0.80×**). Soft ≥90%@≤0.85× / hard ≥95%@≤1.0× remain **MISS** on defaults — shard-only thr is exhausted.

## Discord / forum blurb *(copy-paste)*

```
gcry v0.18.0 is out — Crystal-native GC as a shard (require "gcry" + -Dgc_none).
No compiler fork; stock Crystal ≥ 1.21.

Win: fat-app RSS. Finalizer fix + Linux retain=0 → acik ~90–96% thr @ ~1–1.6× RSS
(was ~3.43× Linux / ~18× Darwin at v0.17). Darwin tip acik ~0.63×.

Kemal Linux headline still v0.16 carry (~87% /json @ ~0.80×). Stack maps exist but
stay off — they are not why 0.18 is fast.

https://github.com/sdogruyol/gcry/releases/tag/v0.18.0
PERF: https://github.com/sdogruyol/gcry/blob/master/docs/PERF.md
```

## Linux numbers

Cite [PERF.md](PERF.md) (**Linux** only; do not invent). Prefer **`/json`**.

**Kemal (headline):** carry v0.16 — `/json` ~**87%** @ ~**0.80×**; `/` ~**82%** @ ~**0.79×**. Quiet tip smokes ~**80–85%** `/json` @ ~**0.75–0.79×** (host noise). Post-tag 9950X confirm: `/json` ~**80%** @ **0.74×**, `/` ~**94–96%** @ ~**0.70–0.75×** (`bench/log/linux/2026-08-05-091154/`).

**Fat-app (acikturkiye):** tip ~**90–96%** thr @ ~**1–1.6×** RSS — i3 headline ~**96%** @ **~1.63×**; 9950X band ~**90–102%** @ ~**1.0–1.8×** (post-tag confirm **~102%** @ **~1.76×**, `…/2026-08-05-091820/`) — [ACIKTURKIYE.md](ACIKTURKIYE.md).

**Opt-in:** `GCRY_TIGHT_GROW=1` → acik ~**103%** @ ~**0.92×** (Kemal thr soft — not default). Parallel EC>1 + TLAB off + lazy: ~**79%** `/json` (supported opt-in, not default).

## macOS numbers

Cite [PERF-macos.md](PERF-macos.md). **Tip:** Kemal `/` ~**91%**, `/json` ~**84%**, RSS ~**0.95–1.01×**. Fat-app tip base ~**90%** thr @ ~**0.63×** RSS (was ~**18×** at v0.17) — [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).

## When to try gcry

- Want a Crystal-readable GC / dogfood alternative
- Linux **or macOS**, Crystal ≥ 1.21, default ExecutionContext (parallelism 1)
- Can accept STW pauses and conservative retention

## When to stay on Boehm

- Windows process GC; Darwin soft-dirty / nursery parity
- Parallel EC **with TLAB** or empty munmap (unsupported); or zero-tuning Parallel defaults
- Need `Process.fork` under ExecutionContext (Crystal forbids it; gcry atfork helps `-Dwithout_mt` / `LibC.fork` only)
- Need Kemal `/json` ≥90% @ ≤0.85× on defaults (shard-only path exhausted)

## Channels

- GitHub: https://github.com/sdogruyol/gcry
- Release: https://github.com/sdogruyol/gcry/releases/tag/v0.18.0
- Crystal forum / Discord: link PERF methodology + honest limits (stack maps ≠ this release’s win)
- awesome-crystal / shards.info: after posting

## Checklist before posting

- [x] Tag `v0.18.0`; CHANGELOG + README + PERF/ACIKTURKIYE reflect tip
- [x] CI green on x86_64 + aarch64 + macOS (musl smoke post-tag)
- [ ] Link COMPARISON.md + POLICY.md + TEST_PLAN.md in the post
- [ ] Lead with **fat-app RSS + no compiler fork**; Kemal Linux carries v0.16; maps dormant; Parallel not the default
- [ ] Do **not** claim stack maps as the product win
