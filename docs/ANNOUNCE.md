# Announcing gcry v0.20.0 (draft)

Crystal-native conservative mark–sweep GC as a **shard** — `require "gcry"` + `-Dgc_none`, no compiler fork. Stock Crystal ≥ 1.21 is enough.

## One-liner

Boehm-class collector you can read and change in Crystal; **Linux + macOS**; fibers OK; default parallelism 1. Stack maps ship **dormant** (research only).

## v0.20.0 highlight

**A fiber's stack was scanned by nothing while the fiber was ending — and that is where a use-after-free lived.**

Crystal cannot release a terminating fiber's stack until the thread swaps off it, so `Thread#dying_fiber` parks the stack on the thread. In that window two things are true at once: the owning `Fiber` is already gone from the fiber list, so no fiber scan reaches the stack; and the thread may still be **executing on it**, which gcry's other-thread scan also cannot see, because that scan works from *pthread* stack bounds a fiber stack is nowhere near. Anything reachable only from those frames had no root, and a collection landing in the window freed it. The program then ran on freed memory — `Fiber#initialize` → `makecontext`, where the crash had been dying all along.

`bench/nested_spawn_uaf.cr` reproduces it in about two seconds. Interleaved against control, poison on: **10/24 crashes → 0/24**.

**Why that number is worth something.** Every rooting arm in this hunt was measured against a twin that walks the *identical* memory and offers nothing to the mark. The twin stays at **12/24** — so the effect is the rooting, not the walking and not the timing. It is also not retention: same `heap_size`, same 160 collections, and *fewer* live objects than control. That discipline exists because an earlier candidate fix in this same hunt went to zero for reasons that had nothing to do with the pointer.

**Four readings were wrong before this one was right, and they are in the log.** The buffer being freed was blamed on a missed heap edge (the mark was complete: 0 missed edges in 15 runs), on a `Fiber` under construction (the saved objects were finished fibers), on a pooled stack (rooting those is *worse* than control), and on a stack in flight between `checkout` and publication (a `Fiber::StackPool#checkout` hook covering exactly that moved 13/24 to 8/24 — nothing — and was deleted rather than shipped). Each correction is written up in `bench/log/linux/`, including the two times the instrument was reporting **itself**.

**Also in this release:**

- **The thread-birth window.** gcry now records a thread from the moment `pthread_create` returns, and `GCRY_STAGED_WAIT` (on by default) makes the collector wait briefly for a thread that exists but has not published itself. Thread-family crashes **6/60 → 0/60**, census gaps **3/30 → 0/30**, ~1.4% of collections waiting.
- **`Heap#realloc(ptr, 0)` freed the caller's block** — the same defect the grow path documents at length, reachable through a second door.
- **The live-object invariant was stated of heaps that cannot keep it**, and flaked for it: 6 runs in 25 → 0 in 100. Underneath it sits a real one that is *not* fixed: with non-atomic counters, a second allocating thread makes `live_objects` lose increments permanently.
- **New diagnostics**, all off by default: `GCRY_ADDRESS_SPACE_AUDIT` (at the moment a block dies, search every mapping in `/proc/self/maps` and name the region holding its address — this is what found the window above), `GCRY_POISON_HOLDERS`, `GCRY_POISON_TAG`, `GCRY_SEGV_REPORT`, `GCRY_MARK_AUDIT`, `GCRY_THREAD_CENSUS`, `GCRY_EC_QUEUE_AUDIT`, and `BlockHeader::Flags::SWEPT`.

**Validation:** 5 h soak × 3 arms, all clean — ~52 000 collections, ~526 000 fibers, 0 errors, RSS well inside its ceiling. Plus spec 164/0, process_spec 26/0, and green x86_64, aarch64, Darwin, two musl cross-compiles, asan, valgrind, coverage and perf smoke.

## Discord / forum blurb *(copy-paste)*

```
gcry v0.20.0 is out — Crystal-native GC as a shard (require "gcry" + -Dgc_none).
No compiler fork; stock Crystal >= 1.21.

Correctness release. A fiber's stack was scanned by nothing while the fiber was
ending: Crystal parks a terminating fiber's stack on the thread until it can
swap off it, and in that window the Fiber is already out of the fiber list while
the thread may still be running on that stack. Pointers held only in those
frames had no root and their objects were swept -> use-after-free in fiber
creation. Repro: 10/24 crashes -> 0/24, with a control arm that walks the same
memory and roots nothing staying at 12/24. 5h soak x3 clean.

Also: the thread-birth window (gcry now waits for a thread that exists but has
not published itself, 6/60 -> 0/60), realloc(ptr, 0) no longer frees the
caller's block, and a pile of new diagnostics including an address-space audit
that names the region holding a dying block's address.

Still open, said plainly: a second use-after-free where gcry reads a Thread's
handle out of a freed block and faults in pthread_getattr_np. Seen on CI with
this fix in place; not reproducible locally. This release does not close it.

https://github.com/sdogruyol/gcry/releases/tag/v0.20.0
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

- **A second use-after-free is still open.** gcry reads a `Thread`'s `@system_handle` out of a freed block and faults inside `pthread_getattr_np`. It was seen on aarch64 CI **with this release's fix in place**, and it does not reproduce locally (`ec_queue_audit` 0/20, 0/25; the 5 h soak did not fire it). This release does not close it, and nobody should read "use-after-free fixed" as "use-after-free class eliminated".
- **The fiber fix is proven on one repro and one soak.** 0/24 on `nested_spawn_uaf` and 15 h of clean soak is the strongest evidence this project has produced for a fix — and it is still one workload on one architecture family.
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
- Release: https://github.com/sdogruyol/gcry/releases/tag/v0.20.0
- Crystal forum / Discord: link PERF methodology + honest limits
- awesome-crystal / shards.info: after posting

## Checklist before posting

- [x] CI green on x86_64 + aarch64 + macOS, and a 5 h × 3 soak clean on the release commit
- [ ] Tag `v0.20.0`
- [ ] CHANGELOG + README + PERF/ACIKTURKIYE reflect tip
- [ ] Lead with **the stack nothing scanned while the fiber was ending**, not with the instrument list
- [ ] Say the twin-arm control out loud — 0/24 against a 12/24 arm that walks the same memory — or the number reads as a guess that worked
- [ ] State the **still-open thread-family use-after-free** in the post itself, not only in the docs
- [ ] Do **not** claim the perf numbers moved; nothing was re-measured this release
- [ ] Do **not** claim stack maps as the product win
- [ ] Do **not** imply any production crash is explained
