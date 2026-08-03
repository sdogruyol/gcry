# exclusivef denser emit — still SEGV (2026-08-03)

Host: WSL2 / Ryzen 9 9950X. `wrk -c100 -d15`, non2xx=0 where noted.

## Emit upgrades (crystal `gcry-stackmap-probe`)

- `CRYSTAL_STACKMAP_PER_FUN=0` → unlimited (was clamped to 256)
- Lives: Proc, MixedUnion, tuple allocas; always pass alloca pointer
- Runtime: multi-word Direct/Indirect via `loc.size`
- acik map section ~**7.5 MiB** (`0x72b808`)

## Acik A/B (1×15s)

| variant | thr | RSS | notes |
|---------|----:|----:|-------|
| base | 255 | 210 MiB | tip+EC, no maps |
| exclusive (`=2`, full parked scan) | 248 | 199 MiB | survives; marked≪ |
| exclusivef + leaf 8 KiB | ~40 | crash | SEGV |
| exclusivef + leaf 256 KiB | ~153 | crash | SEGV |
| exclusivef + leaf 1 MiB | ~206 | crash | SEGV |

Smoke `GCRY_PRECISE_FIBERS=1 GCRY_PRECISE_FIBER_LEAF=0` still **PASS**.

## Verdict

Denser maps + leaf windows do **not** close exclusive fiber correctness on
acik. Missing roots sit outside the first 1 MiB of parked active stacks and/or
in encodings the parked walker cannot resolve (Register GP without gregs).

`=2` with full parked word-scan remains the only acik-safe exclusive mode;
RSS ≈ base (no gate progress).

## Next levers

1. Parked-frame Register lives: synthesize gregs from spill slots more fully
2. Emit / walk coverage of Crystal scheduler park sites (`Fiber.swapcontext` callers)
3. Accept parked conservative scan; pursue RSS via heap/layout paths instead
