# Prefetch-for-write off on the allocation hit path (`GCRY_ALLOC_PFW=0`), five runners (2026-10-24)

Perf A/B 40346166781: `release-0.39.0` at `02a16bf2` against itself, with an
extra arm running the same binary under `GCRY_ALLOC_PFW=0`; 20 reps, nine
benches, all five runners. `var_env` against `var`, paired, median [IQR]:

| runner | Binarytrees | slower beyond spread |
|---|---:|---|
| ubuntu-24.04-arm | **−2.6% [−3.5, −1.0]** | none |
| macos-latest (M1) | **+2.0% [+0.2, +5.5]** | Binarytrees |
| ubuntu-latest | +0.1% [−1.5, +0.7] | none |
| macos-15-intel | −0.1% [−7.1, +5.1] | none (spreads ±5–10%) |
| windows-latest | −0.7% [−2.8, +0.6] | Primes +2.6% [+0.4, +6.1] |

The 3.2–3.6% gain on Linux arm64's Binarytrees
(`../../macos/2026-10-23-m1-binarytrees/`) holds at 2.6%, and nothing else on
that runner moves. The M1, the other aarch64 target, loses 2.0% on the same
row. An aarch64 default would trade the one for the other; a Linux-aarch64-only
default would be a per-OS hit-path variant for one row on one runner. Not
taken: prefetch-for-write stays on, `GCRY_ALLOC_PFW=0` stays a knob.
