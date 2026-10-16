"""Per-arm tables for one perf-ab artifact's runs.json (placement probes).

usage: tables.py runs.json [REF_ARM]

For each bench: every arm's median timed section, wall, user and kernel CPU
time and page faults, with the interquartile range of the timed section, and
the per-rep paired ratio of the timed section and wall against REF_ARM
(default `base`). Then the spread of the `var` + `pad*` arms (same source,
different code placement): max/min of their median timed sections.
"""
import json, statistics, sys


def quart(xs):
    q = statistics.quantiles(xs, n=4, method="inclusive") if len(xs) > 1 else [xs[0]] * 3
    return q[0], statistics.median(xs), q[2]


d = json.load(open(sys.argv[1]))
ref = sys.argv[2] if len(sys.argv) > 2 else "base"
arms = list(d["arms"])
by = {}
for r in d["runs"]:
    by.setdefault((r["bench"], r["arm"]), {})[r["rep"]] = r
for b in d["benches"]:
    print(f"\n### {b} ({d['reps']} reps)\n")
    print(f"| arm | time [IQR] | wall | user | kernel | faults | collections | time vs {ref} | wall vs {ref} |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    rr = by.get((b, ref), {})
    meds = {}
    for a in arms:
        ar = by.get((b, a), {})
        if not ar:
            continue
        t = quart([r["time"] for r in ar.values() if r["time"]])
        meds[a] = t[1]

        def m(k):
            xs = [r[k] for r in ar.values() if r.get(k) is not None]
            return statistics.median(xs) if xs else float("nan")

        cells = []
        for k in ("time", "wall"):
            reps = sorted(set(ar) & set(rr))
            xs = [ar[i][k] / rr[i][k] - 1 for i in reps if ar[i][k] and rr[i][k]]
            cells.append("—" if a == ref or not xs else "{1:+.1%} [{0:+.1%}, {2:+.1%}]".format(*quart(xs)))
        print(f"| {a} | {t[1]:.3f} [{t[0]:.3f}, {t[2]:.3f}] | {m('wall'):.3f} | {m('utime'):.3f} | "
              f"{m('stime'):.3f} | {m('faults'):.0f} | {m('collections'):.0f} | {cells[0]} | {cells[1]} |")
    same = {a: v for a, v in meds.items() if a == "var" or a.startswith("pad")}
    if len(same) > 1:
        lo, hi = min(same, key=same.get), max(same, key=same.get)
        print(f"\nSame-source spread (var + pads), timed section: {same[lo]:.3f} s ({lo}) .. "
              f"{same[hi]:.3f} s ({hi}) = {same[hi] / same[lo] - 1:+.1%}")
