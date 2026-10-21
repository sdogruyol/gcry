#!/usr/bin/env python3
"""Pool the interleaved ab.py sessions in raw/ab-*.json (same binaries in
every session) and print, per arm: runs, peak RSS median [IQR] and × the
pooled Boehm median, wall median [IQR], and the sessions it ran in.

    python3 pool.py [raw-dir]
"""
import glob, json, math, os, sys

d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "raw")


def q(xs):
    xs = sorted(xs)
    n = len(xs)

    def p(f):
        k = (n - 1) * f
        lo, hi = math.floor(k), math.ceil(k)
        return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)

    return p(0.25), p(0.5), p(0.75)


rows = []
for path in sorted(glob.glob(os.path.join(d, "ab-*.json"))):
    for r in json.load(open(path)):
        r["session"] = os.path.basename(path)[3:-5]
        rows.append(r)
arms = []
for r in rows:
    if r["arm"] not in arms:
        arms.append(r["arm"])
boehm = q([r["rss_kb"] / 1024 for r in rows if r["arm"] == "boehm"])[1]
print("| arm | runs | peak MB, median [IQR] | × Boehm | wall s, median [IQR] | sessions |")
print("|---|---:|---:|---:|---:|---|")
for a in arms:
    rs = [r for r in rows if r["arm"] == a]
    m = q([r["rss_kb"] / 1024 for r in rs])
    w = q([r["wall"] for r in rs])
    sess = ", ".join(sorted(set(r["session"] for r in rs)))
    print(f"| {a} | {len(rs)} | {m[1]:.1f} [{m[0]:.1f}, {m[2]:.1f}] | {m[1] / boehm:.2f}× | "
          f"{w[1]:.3f} [{w[0]:.3f}, {w[2]:.3f}] | {sess} |")
print()
print("Per-session Boehm medians: " + ", ".join(
    f"{s} {q([r['rss_kb'] / 1024 for r in rows if r['session'] == s and r['arm'] == 'boehm'])[1]:.1f} MB"
    for s in sorted(set(r["session"] for r in rows))))
