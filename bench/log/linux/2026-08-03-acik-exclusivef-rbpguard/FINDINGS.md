# exclusivef stabilize attempt — RBP gate (2026-08-03)

## Changes

1. **makecontext guard** — skip near/FP walk when saved RBP is not on-stack
   (never-started fibers have uninitialized spill slots; garbage RBP caused
   Direct loads off-stack during collect).
2. **Direct/Indirect** — require address in `[stack_lo, stack_hi]` when bounds known.
3. Tried adaptive full-scan fallback and SP→RBP current-frame leaf — **both
   still UAF** on acik (stackmaps hit some frames but miss live slots in older
   frames). Reverted those policies; LEAF=0 stays pure precise.

## Result

| Check | Outcome |
|-------|---------|
| `make stackmap-smoke` / LEAF=0 fiber smoke | PASS |
| `spec/stack_maps_spec` makecontext case | PASS |
| acik exclusivef LEAF=0 ×3 (15s) | **SEGV** all |

exclusivef is not cut-ready. Stable path remains `GCRY_PRECISE_STACK=2` with
parked full word-scan (~7.8× Boehm on med-of-3).
