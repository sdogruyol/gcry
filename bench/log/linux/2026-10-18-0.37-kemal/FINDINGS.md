# Kemal on 0.37.0 against 0.36.0 and Boehm (Linux)

`release-0.37.0` at `4b625c87` (tip) against `v0.36.0` (`233b3ad6`) and
Boehm, all three built `--release` from the same `bench/kemal` with Crystal
1.21.0. QEMU x86-64 guest, 12 vCPUs. `kemal_ab.sh`: server on CPUs 0–2,
`wrk -t4 -c50` on CPUs 3–11, 3 s warm-up then 10 s measured, 9 trials per
session with the arms in random order per trial and path, each run under the
host-wide lock. req/s and the server's `VmHWM`, medians. Two sessions, the
same evening (`session1*`, `session2*`).

| | Boehm | 0.36.0 | 0.37.0 |
|---|---:|---:|---:|
| `/json` req/s, session 1 | 38 286 | 44 571 (116.4%) | 44 262 (115.6%) |
| `/json` req/s, session 2 | 38 556 | 44 960 (116.6%) | 45 129 (117.0%) |
| `/` req/s, session 1 | 77 714 | 82 371 (106.0%) | 82 606 (106.3%) |
| `/` req/s, session 2 | 76 894 | 84 015 (109.3%) | 81 694 (106.2%) |
| peak RSS, both sessions | 16.2–16.3 MB | 21.2 MB (1.30–1.31×) | 19.6–19.7 MB (1.20–1.21×) |

- **Peak RSS is 0.37.0's change:** −1.5 MB (−7.5%), 1.31× → 1.21× of
  Boehm's, in both sessions. The atomic quarter in the threshold sizing and
  the 472 KiB smaller `Heap` object (`../2026-10-17-kemal-rss/`).
- **Throughput is unchanged:** 0.37.0 against 0.36.0 is −0.7% and +0.4% on
  `/json`, +0.3% and −2.8% on `/`, inside each session's min–max.
- **Boehm read slower here than on 2026-10-14**
  (`../2026-10-14-0.36-integration-ab/`: 42 860 req/s, gcry 0.36.0 at
  105.4%), so the ~116% of these sessions is the host on this day, not a
  gcry gain: 0.36.0 reads the same in the same sessions. The 2026-10-14
  figure stays the headline for throughput.
