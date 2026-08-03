# Compiler stack maps (spike)

**Status:** spike **closed — GO** (next phase: live slots + PIC link + walker).
Not a release feature. Product version stays **v0.17.0**.

**Gate metric:** acikturkiye post-GC RSS × Boehm (Linux tip ~**3.43×**, thr
~**90%**). Kemal thr is **not** the success bar.

Hub parent: [ROADMAP.md](../ROADMAP.md) Phase 2 · [DESIGN.md](../DESIGN.md)
Frontier · thr residual [FINDINGS](../bench/log/linux/2026-08-02-018-FINDINGS.md).

## Problem

gcry (and Boehm) scan stacks **conservatively**: every aligned word that looks
like a heap pointer is treated as a root. Stale / random bit patterns keep
objects alive → false retention.

| Workload | Tip RSS × Boehm | Note |
|----------|----------------:|------|
| Kemal `/json` | ~**0.80×** | scrub + empty-chunk release enough |
| acikturkiye `/api/v1/` | ~**3.43×** | dense conservative-live; scrub/layout do not close |

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

### gcry API (stub shipped, default off)

```crystal
property precise_stack_roots : Bool = false  # GCRY_PRECISE_STACK=1
def mark_precise_root(pointer : Void*) : Nil # during collect only
# GC.mark_precise_root(pointer) — process GC mirror
```

Flag alone does **not** change collect (no walker yet). Spec covers
`mark_precise_root` via `before_collect`.

## Compiler probe results

| Item | Result |
|------|--------|
| Checkout | `/home/uzumaki/playground/crystal` branch `gcry-stackmap-probe` (`2720853d2` base) |
| Gate | `CRYSTAL_EMIT_STACKMAP=1` → empty stackmap after each Crystal call |
| LLVM IR | **Yes** — `call void (i64, i32, ...) @llvm.experimental.stackmap(...)` (~9.6k sites in hello) |
| Object section | **Yes** — `.llvm_stackmaps` in `_main.o0.o` (`readelf -S`) |
| Final link | **Fails** today — `ld.lld`: `R_X86_64_64` in `.llvm_stackmaps` needs **-fPIC** (Crystal default objects are not PIC) |

**Conclusion:** Crystal’s LLVM pipeline **keeps** stackmaps into a real
section. Next engineering is **PIC (or equivalent) codegen/link** + live
value lists — not a pivot away from `llvm.experimental.stackmap`.

Custom `.gcry_stackmap` sidetable remains a fallback only if PIC proves
intractable.

## Risks

| Risk | Mitigation |
|------|------------|
| Missing live slot → UAF | Conservative fallback until maps proven; fuzz + soak |
| Map density / thr | Call-site filter; measure acik + Kemal |
| Fiber parked stacks | Cover `@context.stack_top` frames |
| Non-PIC stackmap relocs | Emit PIC objects or adjust stackmap reloc model |
| Register-only lives | Spill or encode regs in map (later) |

## Success criteria (later phases)

1. Precise path correctness — soak / soft-soak green
2. acikturkiye post-GC RSS **materially down** vs ~3.43× (soft hypothesis ~**1.2×** — unproven)
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

Evidence: IR emit + `.llvm_stackmaps` in objects. Blocker for runnable
binaries is PIC/link, not intrinsic support. acik RSS hypothesis still the
product reason to invest.

### Next-phase checklist

1. Crystal: compile with **PIC** (or fix stackmap relocations) so
   `CRYSTAL_EMIT_STACKMAP=1` links a runnable binary; dump section at runtime.
2. Crystal: pass **live GC pointers** into stackmap (filter
   `context.vars` / temps with `has_inner_pointers?`) — not empty lives.
3. Runtime: parse `.llvm_stackmaps` (LLVM stackmap format) → PC → locations.
4. gcry: when `precise_stack_roots`, walk frames at STW and call
   `mark_precise_root`; keep conservative fallback behind a knob.
5. Measure acikturkiye RSS A/B; only then discuss defaults / upstream PR.

**Do not:** tag `v0.18.0` for this spike; enable precise stacks by default;
open write-barrier work yet.
