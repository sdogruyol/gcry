# Kemal on 0.38.0 against 0.37.0 and Boehm (Linux)

`release-0.38.0` at `8b9e7eab` against `v0.37.0` (`16b7e67c`) and Boehm, all
three built `--release` from the same `bench/kemal` with Crystal 1.21.0. QEMU
x86-64 guest, 12 vCPUs. `../2026-10-18-0.37-kemal/kemal_ab.sh`: server on CPUs
0–2, `wrk -t4 -c50` on CPUs 3–11, 3 s warm-up then 10 s measured, 9 trials
per session with the arms in random order per trial and path, each run under
the host-wide lock. req/s and the server's `VmHWM`; ratios are per trial,
median [IQR]. Two sessions the same night (`session1*`, `session2*`), the
same binaries as `../2026-10-21-0.38-crystal-metric/` (that file says why
`8b9e7eab` stands for the release).

| | session 1 | session 2 |
|---|---:|---:|
| `/json`, 0.38.0 % of Boehm | 105.4% [102.2, 106.4] | 104.3% [101.3, 108.2] |
| `/json`, 0.37.0 % of Boehm | 107.0% [104.7, 108.2] | 106.4% [99.0, 108.6] |
| `/json`, 0.38.0 vs 0.37.0 | −1.5% [−5.0, +0.9] | +0.2% [−4.6, +5.9] |
| `/`, 0.38.0 % of Boehm | 107.3% [98.3, 109.5] | 99.4% [95.2, 102.5] |
| `/`, 0.38.0 vs 0.37.0 | +3.5% [−3.0, +5.5] | −1.3% [−4.0, +3.9] |
| `/json` peak, Boehm / 0.37.0 / 0.38.0 | 16.0 / 19.7 / 19.7 MB | 16.1 / 19.8 / 19.7 MB |
| `/json` peak × Boehm, 0.38.0 (0.37.0) | 1.23× (1.23×) | 1.23× (1.23×) |

0.38.0 is level with 0.37.0 on both paths in both sessions, every paired
ratio inside its spread, at the same peak. Nothing here is GC-bound enough
for the claim to show: the collector is well under 1% of a request
(`../2026-10-19-kemal-placement/`).
