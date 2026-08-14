# The fixed arm — 0/10, and why this directory was renamed

**Status: tip with the register fix, `tipnoec`, 10 trials, 0 Non-2xx.**

Apple M2 Pro, Darwin 25.5.0 / macOS 26.5.1 arm64, gcry at `ff0b030`+ (Crystal
1.21.0), acikturkiye built by probe compiler 1.22.0-dev `656fc4620`.
`acik_stackmap_ab.sh`, `wrk -c 100 -d 30`, dual `/gc-collect`.

This ran first as an attempted *control* at `75a9d25` and was named for that. It
was not one. `acikturkiye/lib/gcry` is a symlink to the main gcry checkout, so
putting the harness in a worktree at `75a9d25` changed which script ran and not
which collector the app linked. It compiled against the fixed tree.

So the run is sound; only its label was wrong. Renamed for what it measured.
It is the fixed arm of the pair completed in
`../2026-08-14-greg-control-75a9d25/`, whose plain arm is **7/10**.

| | corrupt |
|--|--------:|
| `75a9d25`, no fix (`../2026-08-14-greg-control-75a9d25/`) | **7/10** |
| tip, with the fix (here) | **0/10** |

Throughput across the ten trials: 789–1044 req/s, median ~896.
