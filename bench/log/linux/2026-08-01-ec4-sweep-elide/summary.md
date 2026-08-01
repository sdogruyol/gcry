# EC4 lazy-sweep freelist lock elision (REJECT)

Tip: lazy-sweep **78.8%** `/json`. Goal: stretch ~80%.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever (reverted)

Unlocked classify on post-STW major; take freelist lock only when dead
USED must be reclaimed. All-FREE / all-live chunks skip the lock
(mark-gen makes survivor `clear_mark` optional).

## Soft soak

| OK | soft | thr med |
|---:|-----:|--------:|
| **40/40** | **0** | **~71.6k** |

`phase_sweep` rose (~19 ms) — dead chunks pay classify + locked walk.

## Quiet thr

Session `2026-08-01-134944/`: `/json` **76.3%** Boehm @ ~72k (Boehm
~94k). Below hold **78.8%**.

## Verdict

**Reject** (reverted). Extra classify pass taxes dead-heavy heaps more than
lock elision returns under same-host Boehm.
