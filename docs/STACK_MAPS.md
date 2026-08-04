# Compiler stack maps (spike)

**Status:** spike **GO** — parser + hybrid walker landed (default off).
Not a release feature. Product version stays **v0.17.0**.

**Gate metric:** acikturkiye post-GC RSS × Boehm. Linux tip after finalizer +
retain=0: ~**1–1.6×** RSS, thr ~**90–96%** (i3 headline **~1.63×** /
`…/2026-08-04-acik-i3-retain0-med3/`; 9950X **~1.0–1.6×`). Residual is
mapped freelist (`…/acik-i3-residual/`); opt-in `GCRY_TIGHT_GROW=1` →
~**0.92×** @ ~**103%** thr (`…/acik-tight-grow-v2-med3/`). Post-finalizer with
old caches was ~**1.81×**; v0.17 i3 cut ~**3.43×**. Darwin tip base
~**0.63×** @ ~**90%** (`…/macos/2026-08-04-acik-stackmap/` — was ~**18×** at
v0.17). Kemal thr is **not** the success bar.

Hub parent: [ROADMAP.md](../ROADMAP.md) Phase 2 · [DESIGN.md](../DESIGN.md)
Frontier · thr residual [FINDINGS](../bench/log/linux/2026-08-02-018-FINDINGS.md).

## Problem

gcry (and Boehm) scan stacks **conservatively**: every aligned word that looks
like a heap pointer is treated as a root. Stale / random bit patterns keep
objects alive → false retention.

| Workload | Tip RSS × Boehm | Note |
|----------|----------------:|------|
| Kemal `/json` | ~**0.80×** | scrub + empty-chunk release enough |
| acikturkiye `/api/v1/` (Linux) | ~**1–1.6×** | finalizer + retain=0; was ~3.43× (v0.17 i3) / ~8.5× (pre-fix tip) |
| acikturkiye `/api/v1/` (Darwin) | ~**0.63×** | tip base; was ~18× at v0.17 |

Stack scrub / type_id / layout are **not** substitutes for knowing which
slots are pointers.

## Today’s root path

### Crystal (stdlib)

1. `GC.before_collect` → non-running `Fiber#push_gc_roots`
2. `GC.push_stack(stack_top, bottom)` → Boehm `GC_push_all_eager` (blind range)
3. Running fiber: stack bottom via `GC.set_stackbottom` on schedule

Compiler baseline: **no** LLVM stackmap / statepoint / `gc.root`. Closest
oracle: `Type#has_inner_pointers?` + `CRYSTAL_DUMP_TYPE_INFO`.

### gcry (process GC, `-Dgc_none`)

`Heap#run_collection` (STW) → explicit roots → fiber/thread pins →
`Roots.scan_range` / `scan_mutator` → `mark_root_candidate` → `mark_loop` →
`scan_object` (layout-precise on heap edges).

Plug-in sites: `scan_mutator_stack`, `scan_all_fiber_roots`,
`scan_other_thread_stacks` / `push_stack`.

## Chosen MVP

**Emit `llvm.experimental.stackmap` at Crystal call sites**, then grow live
pointer lists from `has_inner_pointers?`. Runtime: PC → slot table →
`mark_precise_root`. Miss / flag off → conservative fallback.

**Not in MVP:** full LLVM statepoint GC strategy, relocatable/moving GC,
write barriers, concurrent collection.

**First patch point:** Crystal
`src/compiler/crystal/codegen/call.cr` → `codegen_call_or_invoke`.

### gcry API (default off)

```crystal
property precise_stack_roots : Bool = false  # GCRY_PRECISE_STACK=1
def mark_precise_root(pointer : Void*) : Nil # during collect only
# GC.mark_precise_root(pointer) — process GC mirror
# Gcry::StackMaps — parse `.llvm_stackmaps` v3, PC→locations, FP walk
```

| Env | Behavior |
|-----|----------|
| `GCRY_PRECISE_STACK=1` | Hybrid: capped mutator FP walk (`HYBRID_MAX_FP_FRAMES=32`) **+** conservative stack scan |
| `GCRY_PRECISE_STACK=2` | Exclusive **mutator** (16 KiB spill + FP). Other threads under STW still word-scanned. Parked fibers full word-scanned unless `PRECISE_FIBERS`. Research. |
| `GCRY_PRECISE_FIBERS=1` | With `=2`: parked full scan off. Default **LEAF=8 KiB** + FP-frame fill. `LEAF=0` = maps+fill only (fiber smoke SEGV / acik UAF). `GCRY_FIBER_FP_FILL_MISS_ONLY=1` skips map-hit frames (UAF). `GCRY_DISABLE_FIBER_FP_FILL=1` = leaf/maps only. |

Needs `CRYSTAL_EMIT_STACKMAP=1` binaries for real hits. Prefer
`--frame-pointers=always` so the FP walker can climb frames.

Smoke: `make stackmap-smoke` (probe Crystal on `PATH` or `CRYSTAL=`).

## Compiler probe results

| Item | Result |
|------|--------|
| Checkout | `/home/uzumaki/playground/crystal` branch `gcry-stackmap-probe` |
| Gate | `CRYSTAL_EMIT_STACKMAP=1` → stackmap after each Crystal call |
| LLVM IR | **Yes** — empty then **with lives** (`ptr %sm.s`, …); ~7.5k/9.7k sites carry ≥1 live in a small String program |
| Object section | **Yes** — ELF `.llvm_stackmaps`; Darwin `__LLVM_STACKMAPS,__llvm_stackmaps` |
| Final link | **Fixed** — auto **`-no-pie`** when gated (Linux; unused arg on Darwin clang). |
| Process GC | Tip probe: **`-Dgc_none -Dpreview_mt -Dexecution_context`** (no EC flags ⇒ soak livelock). 1.21.0 release has EC by default. |
| Emit density | External + Crystal calls; `call_args` lives; pre-call when `PER_FUN=0` / `CRYSTAL_STACKMAP_BEFORE=1`. Default `PER_FUN=2`. |
| Walker smoke | `make stackmap-smoke` — Linux + Darwin aarch64 OK (Mach-O load + FP/parked walker). |

**Conclusion:** Crystal’s LLVM pipeline **keeps** stackmaps into a real
section and we can link/run. Runtime parse + hybrid walker are in-tree;
exclusive/exclusivef are **correctness-stable** on Linux tip (30s med3 clean;
`…/2026-08-04-acik-exclusivef-stabilize-med3/`) but **not** an RSS win (~2×).
Darwin tip base RSS closed (~0.63× without maps). Exclusive/hybrid not an RSS win.

## Risks

| Risk | Mitigation |
|------|------------|
| Missing live slot → UAF | Conservative fallback until maps proven; fuzz + soak |
| Map density / thr | Call-site filter; measure acik + Kemal |
| Walker cost | Mitigated: `find_near`, pc range reject; hybrid FP cap 32, exclusive 128. |
| Tip without EC | Livelock in soak — always `-Dpreview_mt -Dexecution_context`. |
| Exclusive soak | Hybrid PASS. Exclusive/exclusivef acik 30s med3 **PASS** with LEAF=8 KiB + other-thread scans; RSS ~2× (not a win). |
| acik `--release` + maps | Needs stackmap **nounwind** (else LLVM 18 invoke/statepoint crash). |
| acik hybrid smoke | Invalid ~15× was Non-2xx (missing demo schema). Valid tip≈sys ~**8.5×** on 9950X; hybrid still 0 marks. |
| Fiber parked stacks | Cover `@context.stack_top` frames |
| Non-PIC stackmap relocs | Emit PIC objects or adjust stackmap reloc model |
| Register-only lives | Emit prefers alloca; runtime deref when reg∈stack |

## Success criteria (later phases)

1. Precise path correctness — soak / soft-soak green
2. ~~Darwin acik post-GC RSS down vs ~18×~~ **done** (tip base ~**0.63×**);
   Linux tip ~**1–1.6×** without maps — hold that band; exclusive not RSS
3. thr hold (~90% band)
4. Kemal not regressed beyond noise

## Effort band

| Phase | Scope | Rough |
|-------|--------|-------|
| Spike (done) | emit probe + API stub + go/no-go | days |
| Next | PIC link + live slots (`has_inner_pointers?`) + frame walker | weeks |
| Prove | acik A/B, fiber/EC coverage | weeks–months |
| Upstream | multi-arch, review, defaults | months |

## Go / no-go

**GO** — continue with `llvm.experimental.stackmap` MVP.

Evidence: IR emit + `.llvm_stackmaps` in objects **and** runnable `-no-pie`
binaries under `CRYSTAL_EMIT_STACKMAP=1`. acik RSS hypothesis still the
product reason to invest.

### Next-phase checklist

1. ~~Crystal: link so `CRYSTAL_EMIT_STACKMAP=1` is runnable~~ **done** (`-no-pie` auto)
2. ~~Crystal: pass **live GC pointers** into stackmap~~ **done** (MVP:
   `Pointer` + ref-like `has_inner_pointers?`; prefer **alloca** (slot);
   skip Proc/union-by-value; cap 32)
3. ~~Runtime: parse `.llvm_stackmaps` v3 → PC → locations~~ **done**
   (`src/gcry/stack_maps.cr`, `spec/stack_maps_spec.cr`)
4. ~~gcry walker (hybrid)~~ **done** — STW + mutator FP walk →
   `mark_precise_root`; conservative scan still always on.
5. ~~Exclusive knob~~ **done** (`GCRY_PRECISE_STACK=2`) — research only;
   parked-fiber precise coverage + Proc/union-by-value lives still open.
6. ~~**Walker cost**~~ **done** (near lookup + hybrid leaf-only) — re-check soak/Kemal.
7. ~~tip+EC baseline~~ **done** (`…/acik-tip-baseline2-med3/`) — prior ~15×
   was **Non-2xx**. Valid tip≈sys ~**8.5×**.
8. ~~hybrid walker hits~~ **done** — capped mutator FP walk (`HYBRID_MAX_FP_FRAMES=32`).
9. ~~exclusive runtime safety~~ **partial** — parked-fiber precise walk + spill
   window; invoke-out stackmaps; `=2` survives acik with full parked word-scan.
10. ~~denser emit~~ **done** — `PER_FUN=0`; External+call_args+pre-call;
    acik records ~139k → **~306k** (`…/acik-denser-emit/`).
11. ~~parked sysv gregs~~ **done** — RSP@ret + synthetic gregs; RBP on-stack
    gate (makecontext); Direct/Indirect refuse off-stack loads.
12. ~~**exclusivef stabilize**~~ **done** (correctness; not RSS).
    Root causes: exclusive skipped other-thread STW word scans; exclusivef
    `LEAF=0` + FP-fill missed stack slots outside tiny `[rsp,fp)` (fiber smoke
    SEGV). Fix: restore other-thread scans; mutator spill 16 KiB; default
    LEAF=8 KiB + additive FP-fill; harness no longer forces LEAF=0. Med3
    (`…/2026-08-04-acik-exclusivef-stabilize-med3/`): exclusive **95.7%** @
    **2.07×**, exclusivef **98.9%** @ **1.91×**, 0/3 Non-2xx / hang. Prior
    flake: `…/2026-08-04-acik-exclusivef-defaults/`. Still research-only —
    product path without `PRECISE_STACK`.
13. ~~non-stack knob A/B~~ **done** (`…/acik-nonstack-med3/`) — live ~380 MiB
    dense; AUTO_LAYOUTS / SCAN_CAPS / floor / DISABLE_LAYOUT **no RSS win**.
14. ~~**conservative-scan attribution**~~ **done** (`…/acik-live-attr3/`,
    `…/acik-live-attr-ab/`). ~83 MiB @ 32 KiB = atomic byteish; parked seeds
    atomics (mutator ≈ 0). **C layouts dead.**
15. ~~**idle-drain A/B**~~ **done** (`…/acik-idle-drain/`). ESTAB=0 but
    ~95 MiB @32 KiB + ~1500 `TCPSocket` survive idle dual-GC → **false roots
    pin dead IO buffers** (not live conns / pool sizing).
16. ~~**TCPSocket first-mark watch**~~ **done** (`…/acik-watch-tcp/`,
    `GCRY_LIVE_ATTR_WATCH_TID=441`). ~98% **Heap** first-mark (not parked
    stack seeds). Parent graph retains sockets; parked only seeds ~2 MiB.
17. ~~**parent / pool probe**~~ **done** (`…/acik-parents/`). Hot co-retenants:
    `OpenSSL::Digest` (~1:1 with `TCPSocket`, 100% heap). SSL Client absent.
    `max_pool_size=4` **no RSS win** — not DB idle-pool.
18. ~~**finalizer registry**~~ **done** (`…/acik-finalizer-fix/`). Root cause:
    Crystal `Array` finalizer tables marked `Entry.object` forever. Fix: LibC
    registry + MT quiesce + Boehm resurrect-before-sweep. Gate sample: post-GC
    live **~15.7 MiB** / max atomic **~4.7 MiB** (was ~80–100 MiB atomics),
    wrk -c100 **SURVIVED**. RSS lever is finalizer correctness, not exclusivef.
19. ~~**post-fix Boehm med3**~~ **done** (`…/acik-finalizer-gate-med3/`).
    tip+EC `base` vs Boehm: thr **~91.5%**, RSS **~1.81×** (was ~8.5× on this
    host pre-fix). `acik_stackmap_ab.sh` gains `ACIK_BIN_DIR` + dual collect.
20. ~~**residual 1.81× anatomy**~~ **done** (`…/acik-residual-rss/`). Live_sc
    only ~5–16 MiB; RSS = mapped-free + adaptive **large_cache 32 MiB** +
    empty retain 16 MiB. Smoke: both caches 0 → **~0.87×** Boehm (1 trial).
21. ~~**release0 med3**~~ **done** (`…/acik-release0-med3/`).
    `GCRY_LARGE_CACHE=0` + `GCRY_EMPTY_CHUNK_RETAIN=0`: RSS **~1.00×** Boehm,
    thr **~94%**. Now **Linux process defaults** (escape: same env vars with
    non-zero budgets). Darwin unchanged (1 MiB large / 512 KiB empty retain).
22. ~~**defaults verify**~~ **done** — acik med3 (`…/acik-defaults-verify-med3/`):
    thr **~90%**, RSS **~1.40×** (t1 SEGV after `/gc-collect`; t2/t3 OK).
    Kemal smoke (`…/kemal-release0-smoke/`): `/json` **~84%** @ **0.76×** — no
    cliff vs ~87%/0.80× headline.
23. ~~**SEGV bisect**~~ **done** (`…/acik-segv-bisect/`) — **unreproduced**
    (0/45 under retain=0 + heavy/abrupt collect). One-shot Monitor crash; do
    **not** revert retain=0 on that alone.
24. ~~**i3 tip retain=0**~~ **done** (`…/2026-08-04-acik-i3-retain0-med3/`) —
    thr **~96%**, RSS **~1.63×** (headline host vs v0.17 **~3.43×**).
25. ~~**residual anatomy**~~ **done** (`…/acik-i3-residual/`) — idle live_sc
    ~16→5 MiB, heap ~80 MiB stays; mapped freelist / sparse chunks.
26. ~~**PAGE_DONTNEED / mostly-empty**~~ **done** — HOLED default **REJECT**
    (`…/acik-i3-page-dontneed/`); HOLED-less `GCRY_MOSTLY_EMPTY` MADV_FREE no
    RSS win, `MODE=dontneed` COLLECT_HANG (**REJECT** default;
    `…/2026-08-04-acik-mostly-empty/`). Research opt-in only.
27. ~~**Kemal thr profil (9950X)**~~ **done** (`…/kemal-thr-profil/`) —
    munmap tax real but wall-small; KEEP absolute ~**+4%** rps; soft/hard
    thr gates still MISS (shard-only exhausted).
28. ~~**`GCRY_TIGHT_GROW`**~~ **done** (opt-in) — acik **~103%** @ **~0.92×**
    (`…/acik-tight-grow-v2-med3/`); Kemal thr soft — not default. Docs synced.
29. ~~**Darwin acik RSS proof**~~ **done** (`…/macos/2026-08-04-acik-stackmap/`).
    Tip+EC **base ~90% @ 0.63×** (was ~18× @ v0.17). Mach-O loader + aarch64
    FP/parked walker land; `stackmap-smoke` OK. hybrid/exclusive mark roots
    but **worse RSS** than base (~0.86–1.27×) — research only. Product path:
    tip without `PRECISE_STACK` (same as Linux).
30. **PR stack-maps → master** — exclusive stabilize + TIGHT_GROW opt-in +
    Darwin loader/walker + docs. No v0.18 tag.

**Do not:** tag `v0.18.0` for this spike; enable precise stacks by default;
open write-barrier work yet; ship PAGE_DONTNEED / mostly-empty as defaults.
