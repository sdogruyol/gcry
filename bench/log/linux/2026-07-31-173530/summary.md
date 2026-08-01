# EC1 thr recovery after Parallel STW scan fallout

Parent: quiet regress `../2026-07-31-164302/` (~80% Boehm).

## Cause

Parallel full fiber/pthread STW scans ran on EC1. SYSMON's root fiber is named
`"main"` → full pthread map every major (`phase_stacks` ~3ms).

## Fix

- `!multi_mutator_threads?`: SP / `stack_top` other-thread scan (no full map).
- Parallel path unchanged (full fiber + pthread + SP-containing).
- Foreign-SP scrub skip only when `multi_mutator_threads?`.

## Kemal med-of-3 (`wrk -c100 -d30`)

| Path | % Boehm | RSS × |
|------|--------:|------:|
| `/json` | **82.5%** | 0.79× |
| `/` | **75.1%** | 0.78× |

`phase_stacks` ~0.02ms again. Still below v0.15.0 ~86% — **no 0.16 tag yet**.
EC4 smoke after fix: soft 0, ~53k `/json` (d=8).
