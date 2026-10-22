#!/usr/bin/env python3
"""paired.py runs.json BASE VAR: per bench, paired per-rep deltas VAR over BASE,
median [IQR] for wall and peak RSS, plus each arm's median."""
import json, statistics as st, sys

rows = json.load(open(sys.argv[1]))
base, var = sys.argv[2], sys.argv[3]


def q(xs):
    xs = sorted(xs)
    qs = st.quantiles(xs, n=4) if len(xs) > 1 else [xs[0]] * 3
    return qs[0], st.median(xs), qs[2]


print(f"| bench | {base} | {var} | wall Δ median [IQR] | peak Δ median [IQR] |")
print("|---|---:|---:|---:|---:|")
for b in dict.fromkeys(r["bench"] for r in rows):
    by = {}
    for r in rows:
        if r["bench"] == b:
            by.setdefault(r["rep"], {})[r["arm"]] = r
    dw, dr = [], []
    for rep, arms in by.items():
        if base in arms and var in arms:
            dw.append(100 * (arms[var]["wall"] / arms[base]["wall"] - 1))
            dr.append(100 * (arms[var]["rss_kb"] / arms[base]["rss_kb"] - 1))
    bw = st.median(r["wall"] for r in rows if r["bench"] == b and r["arm"] == base)
    br = st.median(r["rss_kb"] for r in rows if r["bench"] == b and r["arm"] == base) / 1024
    vw = st.median(r["wall"] for r in rows if r["bench"] == b and r["arm"] == var)
    vr = st.median(r["rss_kb"] for r in rows if r["bench"] == b and r["arm"] == var) / 1024
    w = q(dw)
    p = q(dr)
    print(f"| {b} | {bw:.3f} s, {br:.0f} MB | {vw:.3f} s, {vr:.0f} MB | {w[1]:+.1f}% [{w[0]:+.1f}, {w[2]:+.1f}] | {p[1]:+.1f}% [{p[0]:+.1f}, {p[2]:+.1f}] |")
