#!/usr/bin/env python3
"""gcp.py REPS OUT.json: base against the kept commit on a wide graph that is
not crystal-metric, `gc_phases --seconds=2 --survival=0.5 --fanout=6
--shuffle` (the 2026-10-01 local-first log's workload), 64 B and 512 B
objects, with `GCRY_PARALLEL_MARK` 2 and 4 and the live floor off
(`GCRY_PARALLEL_MARK_MIN_LIVE=0`). Every run pinned to CPUs 0-3, arm order
shuffled per (rep, size, workers). Prints the median (min-max) of the mean
pause per collection (`pause_per_gc_us`), the last collection's mark
(`phase_mark_us`, all `gc_phases` reports of the mark) and allocations per
run. `bin/gcp-<arm>` is `crystal build --release -Dgc_none
bench/micro/gc_phases.cr` inside `arms/<arm>` (base, kept), under
`taskset -c 0-3` and the heavy lock."""
import sys, json, random, subprocess, statistics as st, os

reps, out = int(sys.argv[1]), sys.argv[2]
S = "/home/naruto/playground/.scratch/ParallelMarkBatch"
arms = {"base": f"{S}/bin/gcp-base", "kept": f"{S}/bin/gcp-kept"}
res = {}
for r in range(reps):
    for size in (8, 64):
        for w in (2, 4):
            order = list(arms)
            random.shuffle(order)
            for a in order:
                env = dict(os.environ, GCRY_PARALLEL_MARK=str(w), GCRY_PARALLEL_MARK_MIN_LIVE="0")
                p = subprocess.run(["taskset", "-c", "0-3", arms[a], "--seconds=2", "--survival=0.5",
                                    "--fanout=6", "--shuffle", f"--size={size}"],
                                   capture_output=True, text=True, env=env)
                row = json.loads([ln for ln in p.stdout.splitlines() if '"survival"' in ln][-1])
                res.setdefault(f"{size * 8}B w{w}", {}).setdefault(a, []).append(row)
    print(f"rep {r + 1}/{reps}", file=sys.stderr, flush=True)
json.dump(res, open(out, "w"), indent=1)


def f(xs):
    return f"{st.median(xs):9.1f} ({min(xs):.1f}-{max(xs):.1f})"


for cell, by in res.items():
    for a, rows in by.items():
        print(f"{cell:10} {a:5} pause/gc us {f([x['pause_per_gc_us'] for x in rows])}  "
              f"last mark us {f([x['phase_mark_us'] for x in rows])}  "
              f"allocs M {f([x['allocs'] / 1e6 for x in rows])}  gcs {f([x['collections'] for x in rows])}")
