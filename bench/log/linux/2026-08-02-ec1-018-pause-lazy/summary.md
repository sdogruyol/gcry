# EC1 post-STW sweep (pause) — ship candidate

## Lever

1. **EC1 lazy sweep** — `sweep_after_world?` true for sole mutator; munmap
   empties still via pending list + flush; `@chunks` rebuilt under
   `@block_other_heap` (SYSMON cooperative spin).
2. **Fuse fully-dead dead-count** into defer_reclaim discover pass (drop
   second O(blocks) walk).

Parallel munmap+lazy stays **rejected** (unchanged gate).

## Under-load TRACE (`collect.ndjson`, `/json` d=30)

| | prior in-STW (`phase-trace/collect-v2`) | this cut |
|--|---------------------------------------:|---------:|
| pause med | **4.07 ms** | **0.59 ms** |
| sweep med | 3.51 ms (inside pause) | 3.47 ms (**after** pause) |
| flush med | 1.35 ms | 1.50 ms |
| wrk abs | 34519 | 34200 |

## Quiet median-of-3 (`2026-08-02-170840/` / `median-run-01/`)

| Path | % Boehm | RSS × | pause_p50 (gcstats med) |
|------|--------:|------:|------------------------:|
| `/json` | **84.6%** | **0.82×** | **~0.58 ms** |
| `/` | **81.2%** | **0.81×** | — |

Thr soft vs parked ~88% baseline (Boehm louder ~41k); absolute gcry ~34.6k
holds. RSS holds ≤1.0× band.

## Soft

`make soak-smoke` **PASS**.

## Verdict

**Ship** as Unreleased pause win. Does not reopen ≥95%@≤1.0× thr gate.
Note: on EC1 the collecting fiber still runs sweep before `collect` returns;
`pause_p50` / STW window shrink; request tail still includes sweep+flush.
