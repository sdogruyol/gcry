# EC4 Parallel fiber scrub 1024 B — REJECT default

Tip: lazy Parallel, parked-fiber scrub default **512** B. Goal: cut false
stack roots via larger wipe → thr toward stretch ~80%.
Parent FINDINGS: `../2026-07-29-parallel-tlab-FINDINGS.md`.

## Lever

`GCRY_FIBER_SCRUB_BYTES` / `Heap#fiber_scrub_bytes` (Parallel wipe below
saved SP). A/B **1024** vs default **512**. Scrub stays on (disable historically
soak-worse). Alloc-path `CLEAR_STACK` untouched.

## Soft soak (1024 B, `wrk -c100 -d8` ×40)

| OK | soft | thr med | pause p50 |
|---:|-----:|--------:|----------:|
| **40/40** | **0** | **~55.3k** | **~9.0 ms** |

## Quiet thr (`wrk -c100 -d30` med-of-3, `/json`, same-host)

| Config | % Boehm | gcry | Boehm | RSS × |
|--------|--------:|-----:|------:|------:|
| **512 (control)** | **83.9%** | 47,189 | 56,265 | **5.45×** |
| **1024** | **83.7%** | 60,052 | 71,759 | **5.74×** |

Sessions: `../2026-08-02-061257/` (512), `../2026-08-02-060626/` (1024).
`phase_scrub` stays sub-ms; % flat (−0.2 pp). Abs↑ tracks louder Boehm.

## Verdict

**REJECT** as Parallel default (stays **512**). Soft green; no clear %/RSS
win. Knob remains opt-in (`GCRY_FIBER_SCRUB_BYTES`).
