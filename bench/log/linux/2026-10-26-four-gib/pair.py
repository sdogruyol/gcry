#!/usr/bin/env python3
"""pair.py DIR [KEY...]: per runner and bench, every arm but `base` and
`boehm` against `base`, medians of per-rep paired ratios with [interquartile
range], as perf-ab's summary prints `var` against `base`. KEY is a runs.json
field (default: wall peak). `var_env` is the `var` binary with
GCRY_FOUR_GIB_FENCE=0, so a row where both move alike moved with the binary,
not with the fence; the `prepad`/`baseprepad` arms are what code placement
alone moves a row by on that runner."""
import json
import os
import statistics
import sys


def q(xs):
    xs = sorted(xs)
    qs = statistics.quantiles(xs, n=4, method="inclusive")
    return f"{100 * (statistics.median(xs) - 1):+.1f}% [{100 * (qs[0] - 1):+.1f}, {100 * (qs[2] - 1):+.1f}]"


top = sys.argv[1]
keys = sys.argv[2:] or ["wall", "peak"]
for runner in sorted(os.listdir(top)):
    path = os.path.join(top, runner, "runs.json")
    if not os.path.exists(path):
        continue
    d = json.load(open(path))
    by = {}
    for r in d["runs"]:
        by[(r["bench"], r["arm"], r["rep"])] = r
    arms = sorted({r["arm"] for r in d["runs"]} - {"base", "boehm"})
    arms.sort(key=lambda a: (a != "var", a != "var_env", a))
    print(f"## {runner}")
    for key in keys:
        print(f"\n{key}, against `base`:\n")
        print("| bench | " + " | ".join(arms) + " |")
        print("|---|" + "---:|" * len(arms))
        for bench in d["benches"]:
            cells = []
            for arm in arms:
                xs = [by[(bench, arm, i)][key] / by[(bench, "base", i)][key]
                      for i in range(d["reps"])
                      if (bench, arm, i) in by and (bench, "base", i) in by and by[(bench, "base", i)].get(key)]
                cells.append(q(xs) if len(xs) > 1 else "—")
            print(f"| {bench} | " + " | ".join(cells) + " |")
    print()
