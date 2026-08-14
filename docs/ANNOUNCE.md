# Announcing gcry v0.19.0 (draft)

Crystal-native conservative mark–sweep GC as a **shard** — `require "gcry"` + `-Dgc_none`, no compiler fork. Stock Crystal ≥ 1.21 is enough.

## One-liner

Boehm-class collector you can read and change in Crystal; **Linux + macOS**; fibers OK; default parallelism 1. Stack maps ship **dormant** (research only).

## v0.19.0 highlight

**A dropped-root class, closed on the two platforms that had it — and the second one was found by the test written for the first.**

`collect_scan` asks the platform for a suspended thread's GP registers, because a reference can live only in a register: the compiler is free to keep an object pointer in a callee-saved register and never spill it, and a conservative scan of that thread's stack then sees nothing. Two platforms were not answering.

- **Darwin:** `each_thread_greg` was an **empty stub**, next to a `thread_get_state` that already read SP and discarded the rest. Observed on a real app as a live `String`'s tail overwritten in place — same 25 bytes, same allocation, four sessions. It needed a collection to appear (`GCRY_DISABLE_AUTO=1` is 0/5 against 8/10), which is what makes it a dropped root and not a write bug. A/B at one commit: **4/10 corrupt → 0/10**; control re-established later on a newer compiler at **7/10 → 0/10**.
- **Linux aarch64:** `UCONTEXT_NGREGS = 0`, under the comment *"skip full mcontext register dump on aarch64 for now (SP clamp only)"*. Same defect, different route. x86_64 (`NGREGS = 23`) was never affected.

**Who was actually hitting it — say this plainly, it is not "everyone".** The corruption above never reproduced under **stock Crystal 1.21.0**: 0/5 on the system-compiler arm and 0/18 across the `run_all.sh` runs, 0/23 combined. Every observation came from a **1.22.0-dev probe compiler** (2/5 without execution contexts, 5/6 with). That is not a coincidence to wave away — whether a pointer lives in a register or gets spilled is a codegen choice, which is exactly why Linux x86_64 never saw it and why the base rate moved between two builds of the same compiler.

So the honest shape of the claim is: **the defect is real by construction on any compiler** — the mark phase asked for a root source the platform did not provide, and a reference held only in a register had no root — but whether a given toolchain *produces* that shape is unmeasured outside the compiler that produced it here. Stock 1.21 users have no reproduction, and no evidence of safety either. Upgrade because the hole is closed, not because your app was demonstrably losing objects.

The fix is now **gated** — `thread_greg_candidates` on `/gc-stats`, asserted in `process_spec` and `make greg-roots`, running on Darwin + Linux x86_64 + Linux aarch64. The gate is verified red: stubbing the method out fails the spec and drops the count to 0. **The aarch64 bug was found by that gate on its first CI run**, which is the part worth telling: it had been open as "does Linux have the same gap?" and answered itself within minutes of being wired up.

**Also:** the Darwin fat-app RSS headline is re-cut and the old ~**0.63×** does not reproduce — it is ~**98%** thr @ ~**0.97×** at n=9. gcry is not what moved: its post-GC RSS is within **0.6%** of the old cut, while Boehm's fell **35%**. The v0.17-era ~18× gate stays closed; gcry is at parity here rather than a third below.

## Discord / forum blurb *(copy-paste)*

```
gcry v0.19.0 is out — Crystal-native GC as a shard (require "gcry" + -Dgc_none).
No compiler fork; stock Crystal >= 1.21.

Correctness release. A suspended thread's registers were never scanned on Darwin
(empty stub) or Linux aarch64 (NGREGS = 0, "for now"), so a reference the compiler
kept in a register and never spilled had no root and its object was swept.
Both fixed and gated. The aarch64 one was found by the test written for the
Darwin one, on its first CI run.

Scope, honestly: every observed corruption came from a 1.22.0-dev compiler
(0/23 under stock 1.21). Register-vs-spill is a codegen choice, so the hole is
real on any compiler but stock-1.21 users have no reproduction - and no
evidence of safety either.

Also: Darwin fat-app re-cut, ~98% thr @ ~0.97x RSS (n=9). The old ~0.63x does not
reproduce - gcry's RSS is within 0.6% of that cut, Boehm's arm is what fell 35%.

https://github.com/sdogruyol/gcry/releases/tag/v0.19.0
PERF: https://github.com/sdogruyol/gcry/blob/master/docs/PERF.md
```

## Linux numbers

Cite [PERF.md](PERF.md) (**Linux** only; do not invent). Prefer **`/json`**. Nothing here was re-measured this release.

**Kemal (headline):** carry v0.16 — `/json` ~**87%** @ ~**0.80×**; `/` ~**82%** @ ~**0.79×**. Quiet tip smokes ~**80–85%** `/json` @ ~**0.75–0.79×** (host noise). Post-tag 9950X confirm: `/json` ~**80%** @ **0.74×**, `/` ~**94–96%** @ ~**0.70–0.75×** (`bench/log/linux/2026-08-05-091154/`).

**Fat-app (acikturkiye):** tip ~**90–96%** thr @ ~**1–1.6×** RSS — i3 headline ~**96%** @ **~1.63×**; 9950X band ~**90–102%** @ ~**1.0–1.8×** — [ACIKTURKIYE.md](ACIKTURKIYE.md).

**Opt-in:** `GCRY_TIGHT_GROW=1` → acik ~**103%** @ ~**0.92×** (Kemal thr soft — not default). Parallel EC>1 + TLAB off + lazy: ~**79%** `/json` (supported opt-in, not default).

## macOS numbers

Cite [PERF-macos.md](PERF-macos.md). **Kemal:** `/` ~**89%**, `/json` ~**88%**, RSS ~**0.96×** (`bench/log/macos/2026-08-10-053800/`, n=9). **Fat-app:** ~**98%** thr @ ~**0.97×** RSS, n=9 per arm, 0 Non-2xx in 18 trials (`bench/log/macos/2026-08-14-acik-recut/`) — [ACIKTURKIYE-macos.md](ACIKTURKIYE-macos.md).

## What this release does not claim

- **No link to any production crash.** The 2026-08-08 SIGSEGV remains an unproven bet; nothing here connects them.
- **No claim that stock-Crystal users were losing objects.** 0/23 under 1.21.0; every reproduction needed the 1.22.0-dev probe compiler. The hole was real; the exposure is unmeasured.
- **The 15-minute Darwin soak is worth less than it looks.** 900 s, 887 collections, 72,437/72,437 finalized, `errors=0`, no crash — real coverage of the changed path. But `bench/soak.cr` reads `/proc/self/status` unguarded, so its **RSS-leak gate is inert on Darwin** (`rss=0kB` throughout) and checked nothing. Linux aarch64 was not soaked at all.
- **The end-to-end half of `greg-roots` does not discriminate.** With the fix reverted the victim still survives, because keeping a pointer out of memory is a codegen outcome no source-level test can compel. The candidate count is the gate; the harness says so itself.
- **Throughput 89.9% → 98.0% on the fat app is not attributable** to anything in particular — a commit range, the scrub flip and this fix all sit between the two cuts.
- **Two gates are still not gates.** CI's Ameba step lints `lib/ameba` rather than gcry (346 files inspected, not 109), and `make invariants` has never passed on Darwin — it fails at `v0.18.0` and `v0.17.0` too. Both are tracked in `ROADMAP.md`.

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
- Release: https://github.com/sdogruyol/gcry/releases/tag/v0.19.0
- Crystal forum / Discord: link PERF methodology + honest limits
- awesome-crystal / shards.info: after posting

## Checklist before posting

- [x] CI green on x86_64 + aarch64 + macOS — PR #25, 22 checks pass, incl. `greg-roots` on all three
- [ ] Tag `v0.19.0`; CHANGELOG + README + PERF/ACIKTURKIYE reflect tip
- [ ] Link COMPARISON.md + POLICY.md + TEST_PLAN.md in the post
- [ ] Lead with **the dropped root on two platforms, and the gate that found the second**
- [ ] State the compiler scope: **0/23 under stock 1.21**, every reproduction on 1.22.0-dev. Do not let a reader conclude their app was losing objects
- [ ] Say the fat-app re-cut moved because *Boehm* moved, not gcry — do not sell 0.63× → 0.97× as a regression or a win
- [ ] Do **not** claim stack maps as the product win
- [ ] Do **not** imply any production crash is explained
- [ ] Do **not** cite the Darwin soak as leak evidence — its RSS gate is inert there
